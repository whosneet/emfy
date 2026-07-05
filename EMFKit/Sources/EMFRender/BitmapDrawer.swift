import CoreGraphics
import EMFParse
import Foundation

/// Bitmap playback: EMR_STRETCHDIBITS (source and sourceless rop-only),
/// EMR_BITBLT / EMR_STRETCHBLT (source and sourceless), and
/// EMR_SETDIBITSTODEVICE. Draws under the DC clip with
/// `interpolationQuality = .none` — GDI-faithful chunky pixels (the gate file
/// is an 8×8 checker blown up 30×; crispness is the point).
///
/// Coordinate handling: destination geometry is in LOGICAL units, mapped to
/// device by the DC transform then to the canvas by `base`. The decoded image
/// is top-down (row 0 = top); it is drawn into the device-space destination
/// rect with a local y-flip so it comes out upright through `base`'s canvas
/// flip. NEGATIVE destination extents therefore mirror the image for free.
enum BitmapDrawer {

    // TernaryRasterOperation constants ([MS-WMF] §2.1.1.31 — not in the local
    // [MS-EMF] PDF, which references it; values are the canonical GDI ternary
    // rops, matching the supplied task table and cross-checked against the
    // BITBLT sourceless fixture in PayloadBitmapTests).
    static let srcCopy: UInt32 = 0x00CC_0020
    static let blackness: UInt32 = 0x0000_0042
    static let whiteness: UInt32 = 0x00FF_0062
    static let patCopy: UInt32 = 0x00F0_0021

    // MARK: - EMR_STRETCHDIBITS ([MS-EMF] §2.3.1.7)

    static func drawStretchDIBits(
        _ payload: StretchDIBitsPayload,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // Sourceless (rop-only) form: cbBmiSrc == 0 → no DIB, the rop alone
        // paints the dest (§2.3.1.7; rare for STRETCHDIBITS but legal). Shares
        // BITBLT's sourceless fill semantics.
        guard let dib = payload.dib else {
            fillSourcelessRop(
                rasterOperation: payload.rasterOperation,
                dest: payload.dest, destSize: payload.destSize,
                into: context, dc: dc, base: base, log: &log
            )
            return
        }
        // DIB_PAL_COLORS (usageSrc == 1) indexes a DC palette we do not track.
        guard payload.usageSrc != 1 else {
            log.noteUnsupportedDIB(reason: .paletteUsage(payload.usageSrc))
            return
        }
        guard let image = decode(dib, log: &log) else { return }

        // A rop other than SRCCOPY still draws as a copy (best effort, D5), with
        // one coalesced log line.
        if payload.rasterOperation != srcCopy {
            log.noteUnsupportedRasterOp(rasterOperation: payload.rasterOperation)
        }

        let cropped = crop(
            image,
            xSrc: payload.src.x, ySrc: payload.src.y,
            cxSrc: payload.srcSize.cx, cySrc: payload.srcSize.cy
        )
        drawImage(
            cropped,
            destOrigin: payload.dest, destSize: payload.destSize,
            into: context, dc: dc, base: base
        )
    }

    // MARK: - EMR_BITBLT / EMR_STRETCHBLT ([MS-EMF] §2.3.1.2 / §2.3.1.6)

    static func drawBitBlt(
        _ payload: BitBltPayload,
        stretch: Bool,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // Sourceless (rop-only) form: no DIB, the rop alone paints the dest.
        guard payload.hasSource, let dib = payload.dib else {
            fillSourcelessRop(
                rasterOperation: payload.rasterOperation,
                dest: payload.dest, destSize: payload.destSize,
                into: context, dc: dc, base: base, log: &log
            )
            return
        }

        guard payload.usageSrc != 1 else {
            log.noteUnsupportedDIB(reason: .paletteUsage(payload.usageSrc))
            return
        }
        guard let image = decode(dib, log: &log) else { return }

        // Source-space transforms are vanishingly rare; log-and-ignore when
        // non-identity ([MS-EMF] §2.2.28).
        if !isIdentity(payload.xformSrc) {
            log.noteXformSrcIgnored()
        }

        // SRCCOPY draws; any other source rop draws as a plain copy + logs.
        if payload.rasterOperation != srcCopy {
            log.noteUnsupportedRasterOp(rasterOperation: payload.rasterOperation)
        }

        // BITBLT's source size equals its dest size; STRETCHBLT carries its own
        // source size. Source is cropped in SOURCE pixels.
        let srcSize = payload.srcSize ?? payload.destSize
        let cropped = crop(
            image,
            xSrc: payload.src.x, ySrc: payload.src.y,
            cxSrc: srcSize.cx, cySrc: srcSize.cy
        )
        drawImage(
            cropped,
            destOrigin: payload.dest, destSize: payload.destSize,
            into: context, dc: dc, base: base
        )
    }

    /// Sourceless blits (BITBLT/STRETCHBLT rop-only, and STRETCHDIBITS with
    /// cbBmiSrc == 0): BLACKNESS fills black, WHITENESS fills white, PATCOPY
    /// fills with the current brush; any other sourceless rop is skipped with a
    /// coalesced log. Takes only the fields the fill needs so both bitmap
    /// families share one implementation.
    private static func fillSourcelessRop(
        rasterOperation: UInt32,
        dest: PointL,
        destSize: SizeL,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        let color: CGColor?
        switch rasterOperation {
        case blackness:
            color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case whiteness:
            color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case patCopy:
            if case .solid(let brush) = dc.state.brush {
                color = cgColor(brush)
            } else {
                color = nil   // NULL brush: PATCOPY paints nothing.
            }
        default:
            log.noteUnsupportedRasterOp(rasterOperation: rasterOperation)
            return
        }
        guard let fill = color else { return }

        let rect = destRect(origin: dest, size: destSize)
        let full = dc.resolvedTransform.concatenating(base)
        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)
        context.concatenate(full)
        context.setFillColor(fill)
        context.fill(rect)
    }

    // MARK: - EMR_SETDIBITSTODEVICE ([MS-EMF] §2.3.1.5)

    static func drawSetDIBitsToDevice(
        _ payload: SetDIBitsToDevicePayload,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        guard payload.usageSrc != 1 else {
            log.noteUnsupportedDIB(reason: .paletteUsage(payload.usageSrc))
            return
        }
        guard let dib = payload.dib else { return }
        guard let image = decode(dib, log: &log) else { return }

        // Draw the scanline window (iStartScan / cScans) 1:1 at dest. The scan
        // range is validated against the DIB height and clamped — hostile
        // values must not trap the crop. SETDIBITSTODEVICE does NOT stretch:
        // dest size == the drawn scanline block's pixel size.
        let imageHeight = image.height
        let startScan = min(Int(payload.startScan), imageHeight)
        let requested = Int(payload.scanCount)
        let scanCount = max(0, min(requested, imageHeight - startScan))
        guard scanCount > 0 else { return }

        // SETDIBITSTODEVICE scan lines are counted from the DIB's FIRST scan
        // line (bottom for a bottom-up DIB). Our decoded image is top-down, so
        // the window [startScan, startScan+scanCount) counted from the source
        // origin lands at image rows [imageHeight-startScan-scanCount, …) for a
        // bottom-up DIB, or [startScan, …) for a top-down DIB.
        let cropY = dib.isTopDown ? startScan : (imageHeight - startScan - scanCount)
        let window = image.cropping(to: CGRect(x: 0, y: cropY, width: image.width, height: scanCount)) ?? image

        // 1:1 mapping: the destination pixel size equals the window size.
        // `Int32(clamping:)` — the DIB dimension cap keeps these well within
        // Int32, but the narrowing stays saturating so no CGImage size can ever
        // trap the conversion (§8: exceptionless).
        drawImage(
            window,
            destOrigin: payload.dest,
            destSize: SizeL(cx: Int32(clamping: window.width), cy: Int32(clamping: window.height)),
            into: context, dc: dc, base: base
        )
    }

    // MARK: - Shared draw

    /// Decodes a DIB to a CGImage, logging (coalesced) the reason when it is
    /// unsupported and returning `nil`.
    private static func decode(_ dib: DIB, log: inout EMFRenderLog) -> CGImage? {
        let (image, reason) = BitmapDecoder.image(from: dib)
        if image == nil {
            log.noteUnsupportedDIB(reason: reason)
        }
        return image
    }

    /// Crops an image to a source sub-rectangle in SOURCE pixels, clamping the
    /// rectangle to the image bounds so hostile values cannot trap
    /// `CGImage.cropping`. A non-positive or fully-out-of-bounds rect yields the
    /// whole image (the common "src == whole DIB" case passes through cleanly).
    private static func crop(_ image: CGImage, xSrc: Int32, ySrc: Int32, cxSrc: Int32, cySrc: Int32) -> CGImage {
        let imageWidth = image.width
        let imageHeight = image.height
        // Whole-image fast path: (0,0) origin and a size that meets or exceeds
        // the image needs no crop.
        if xSrc <= 0, ySrc <= 0, Int(cxSrc) >= imageWidth, Int(cySrc) >= imageHeight {
            return image
        }
        let x0 = max(0, min(Int(xSrc), imageWidth))
        let y0 = max(0, min(Int(ySrc), imageHeight))
        let w = max(0, min(Int(cxSrc), imageWidth - x0))
        let h = max(0, min(Int(cySrc), imageHeight - y0))
        guard w > 0, h > 0 else { return image }
        // Source y is top-down in our decoded image (matching source-pixel ySrc,
        // which counts from the top of the source bitmap).
        return image.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) ?? image
    }

    /// Draws `image` (top-down) into the destination box. The dest origin/size
    /// are LOGICAL; they map to device via the DC transform, then to the canvas
    /// via `base`. The image's top-left corner lands at the dest origin and its
    /// bottom-right at origin+size; NEGATIVE dest extents therefore mirror the
    /// image (they flip the mapping's sign), and the image renders UPRIGHT
    /// through `base`'s device-y-down→canvas-y-up flip.
    private static func drawImage(
        _ image: CGImage,
        destOrigin: PointL,
        destSize: SizeL,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform
    ) {
        let full = dc.resolvedTransform.concatenating(base)
        let x = CGFloat(destOrigin.x)
        let y = CGFloat(destOrigin.y)
        let w = CGFloat(destSize.cx)
        let h = CGFloat(destSize.cy)
        guard w != 0, h != 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)
        context.interpolationQuality = .none
        // Enter device space (base carries the canvas fit + y-flip).
        context.concatenate(full)
        // Map the top-down unit image square [0,1]×[0,1] (origin = top-left) to
        // the signed device box: `a=w, d=h, tx=x, ty=y` places the box; the
        // signs carry any mirror. CG's draw(in:) puts image row 0 at the box's
        // MAX y, so an extra in-square y-flip (translate 0→1, scale 1→−1) lands
        // row 0 at the box origin — upright against device y-down.
        context.concatenate(CGAffineTransform(a: w, b: 0, c: 0, d: h, tx: x, ty: y))
        context.translateBy(x: 0, y: 1)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Helpers

    /// The device-space destination rectangle for a logical origin+size (used
    /// by the sourceless fills, which paint a plain rect under `full`).
    /// Standardised so negative extents still produce a positive-size rect.
    private static func destRect(origin: PointL, size: SizeL) -> CGRect {
        CGRect(x: CGFloat(origin.x), y: CGFloat(origin.y), width: CGFloat(size.cx), height: CGFloat(size.cy))
            .standardized
    }

    private static func isIdentity(_ xform: XForm) -> Bool {
        xform.m11 == 1 && xform.m12 == 0 && xform.m21 == 0
            && xform.m22 == 1 && xform.dx == 0 && xform.dy == 0
    }

    private static func cgColor(_ color: ColorRef) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
