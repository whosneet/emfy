import CoreGraphics
import EMFParse
import Foundation

/// EmfPlusImage (bitmap content) → CGImage ([MS-EMFPLUS] §2.2.2.2 EmfPlusBitmap).
///
/// Two content forms are handled (§2.1.1.2 BitmapDataType):
///
/// - **Pixel** (BitmapDataTypePixel, 0): raw scan-lines whose layout is the
///   PixelFormat (§2.1.1.24). The three GDI-common non-indexed formats are
///   supported — 24bpp RGB, 32bpp RGB, 32bpp ARGB — each unpacked into a
///   top-down premultiplied RGBA8 CGImage the same way the GDI DIB path builds
///   its output (`BitmapDecoder.makeImage`). Every other format (16bpp,
///   indexed, PARGB, 48/64bpp) is an honest skip.
/// - **Compressed** (BitmapDataTypeCompressed, 1): an embedded PNG/JPEG/… file
///   stream (§2.2.2.10 EmfPlusCompressedImage). PNG and JPEG are decoded through
///   CoreGraphics' native data-provider inits (no ImageIO import); GIF/TIFF and
///   anything CoreGraphics declines are skipped.
///
/// Security (primer §8): every dimension/stride is validated against the actual
/// payload size BEFORE any allocation, and the decoded pixel count is bounded by
/// the SAME shared canvas caps the GDI DIB path uses (16384/side, 32 Mpx). A
/// violation returns `nil` plus a typed `Skip`; nothing here force-unwraps,
/// overflows, or over-allocates.
enum EMFPlusImageDecoder {

    /// Reuse the renderer's canvas caps so an EMF+ image decode and the canvas
    /// share ONE clamp rule (per-side 16384, total area 32 Mpx).
    private static let maxDimension = EMFRenderer.canvasDimensionCap
    private static let maxArea = EMFRenderer.canvasAreaCap

    // MARK: - Supported pixel formats ([MS-EMFPLUS] §2.1.1.24)

    /// The PixelFormat values this decoder unpacks. The value encodes bits-per-
    /// pixel in bits 8-15 and alpha/premultiplied/indexed flags in bits 16-20
    /// (§2.1.1.24 / §2.2.2.2): 24bpp RGB and 32bpp RGB are opaque (A bit clear);
    /// 32bpp ARGB carries a STRAIGHT alpha (A bit set, P bit clear). The
    /// premultiplied (PARGB), indexed, 16bpp, and 48/64bpp formats are skipped.
    private static let pixelFormat24bppRGB: UInt32  = 0x0002_1808
    private static let pixelFormat32bppRGB: UInt32  = 0x0002_2009
    private static let pixelFormat32bppARGB: UInt32 = 0x0026_200A

    /// Why an EmfPlusImage could not be turned into a CGImage — each maps to a
    /// distinct render-log note so a viewer can tell precisely what was skipped.
    enum Skip: Equatable {
        /// A pixel format outside the supported set (16bpp, indexed, PARGB,
        /// 48/64bpp). Carries the raw PixelFormat value.
        case pixelFormat(UInt32)
        /// Non-positive dimensions/stride, a stride/payload too small for the
        /// declared pixels, or a size beyond the shared canvas caps.
        case invalid
        /// A compressed stream CoreGraphics could not decode: GIF/TIFF, an
        /// unknown magic, or a corrupt PNG/JPEG.
        case compressed
        /// A metafile-content image — nested-metafile playback is out of phase-4
        /// scope (§2.2.2.27), so the image is not drawn.
        case metafile
        /// A compressed image (§2.2.2.10) far larger than the destination-derived
        /// budget: CoreGraphics would decode the whole stream at draw time (no
        /// cheap band-decode without ImageIO), so it is SKIPPED rather than
        /// materialised (audit H1 / A3). Distinct from `.invalid` (a broken
        /// image): the image is fine, just too large for this render.
        case oversized
    }

    // MARK: - Entry point

    /// Decodes an EmfPlusImage into a TOP-DOWN CGImage (row 0 = top), or a
    /// `Skip` reason when it cannot. Never traps.
    ///
    /// `destTargetRect` is the image's device-space footprint (the placement
    /// parallelogram, bounding-boxed). It bounds the decode to no more than the
    /// destination can show (audit H1 / A2), exactly as the GDI DIB path does —
    /// the pixel path samples DOWNSAMPLED into a budgeted buffer instead of
    /// materialising the full native bitmap. `downsampled` reports when the
    /// pixel decode fell below native resolution.
    static func decode(
        _ image: EMFPlusImage, destTargetRect: CGRect
    ) -> (image: CGImage?, skip: Skip?, downsampled: Bool) {
        switch image.content {
        case .metafile:
            return (nil, .metafile, false)
        case .bitmap(let header, let data):
            switch header.bitmapDataType {
            case 0x0000_0000:   // BitmapDataTypePixel
                let budget = decodeBudget(
                    destTargetRect: destTargetRect,
                    nativeW: Int(header.width), nativeH: Int(header.height))
                return decodePixels(header, data, budget: budget)
            case 0x0000_0001:   // BitmapDataTypeCompressed
                return decodeCompressed(data, destTargetRect: destTargetRect)
            default:
                return (nil, .compressed, false)
            }
        }
    }

    /// Convenience decode with NO destination bound — decodes at native
    /// resolution, bounded only by the shared canvas caps (the outer bound).
    /// Used by callers with no destination footprint; production drawing passes
    /// the real footprint via `decode(_:destTargetRect:)`.
    static func decode(_ image: EMFPlusImage) -> (image: CGImage?, skip: Skip?) {
        let (cg, skip, _) = decode(image, destTargetRect: unbounded)
        return (cg, skip)
    }

    // MARK: - Destination decode budget (audit H1 / A2)

    /// A footprint standing for "no destination bound": non-finite, so
    /// `decodeBudget` falls back to a native-resolution decode.
    static let unbounded = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity)

    /// The minimum decode AREA for an EMF+ pixel bitmap, in pixels. Even a small
    /// destination decodes at least this much, so a decode cached once per object
    /// (A1) and later redrawn larger keeps reasonable fidelity — and so an image
    /// AT OR BELOW this size always decodes at native resolution (the floor is
    /// capped at the native area), leaving every small image byte-identical to a
    /// straight full-resolution repack.
    static let minPixelBudgetArea = 4_000_000

    /// The decode budget (per-side pixel counts) for an EMF+ image whose
    /// device-space footprint is `destTargetRect`. Mirrors
    /// `BitmapDecoder.decodeBudget` — ceil each side, clamp to native so the
    /// decode never upsamples, clamp to the shared caps — with one addition: a
    /// `minPixelBudgetArea` FLOOR (capped at native) so a tiny destination still
    /// decodes a reasonable number of pixels. A non-finite footprint (a hostile
    /// world transform) falls back to the whole native size (§8: never trap).
    static func decodeBudget(destTargetRect: CGRect, nativeW: Int, nativeH: Int) -> (w: Int, h: Int) {
        let nativeW = max(1, nativeW)
        let nativeH = max(1, nativeH)
        var w: Int
        var h: Int
        if destTargetRect.width.isFinite, destTargetRect.height.isFinite {
            w = min(ceilToDimension(destTargetRect.width), nativeW)
            h = min(ceilToDimension(destTargetRect.height), nativeH)
        } else {
            w = nativeW
            h = nativeH
        }
        w = max(1, w)
        h = max(1, h)
        // Floor a below-floor budget up to a native-aspect box (capped at
        // native), so at least `minPixelBudgetArea` pixels decode — unless the
        // image itself is smaller, in which case native is the ceiling.
        if w * h < min(minPixelBudgetArea, nativeW * nativeH) {
            (w, h) = raiseToFloor(nativeW: nativeW, nativeH: nativeH)
        }
        return clampToCaps(w: w, h: h)
    }

    /// A native-aspect box of `minPixelBudgetArea` pixels, capped at native.
    /// Native sides are each ≤ `maxDimension`, so the products fit Int.
    private static func raiseToFloor(nativeW: Int, nativeH: Int) -> (w: Int, h: Int) {
        let nativeArea = nativeW * nativeH
        guard nativeArea > minPixelBudgetArea else { return (nativeW, nativeH) }
        let scale = (Double(minPixelBudgetArea) / Double(nativeArea)).squareRoot()
        let w = min(nativeW, max(1, Int((Double(nativeW) * scale).rounded(.up))))
        let h = min(nativeH, max(1, Int((Double(nativeH) * scale).rounded(.up))))
        return (w, h)
    }

    /// Ceils a finite footprint side to an Int in [0, maxDimension]. Clamping at
    /// the cap makes the Int conversion overflow-proof for any finite input.
    private static func ceilToDimension(_ value: CGFloat) -> Int {
        let ceiled = value.rounded(.up)
        if ceiled <= 0 { return 0 }
        if ceiled >= CGFloat(maxDimension) { return maxDimension }
        return Int(ceiled)
    }

    /// Clamps a budget to the shared per-side and total-area caps, preserving
    /// aspect on the area clamp. Both inputs are floored at 1 and capped per side
    /// first, so `cw * ch` cannot overflow.
    private static func clampToCaps(w: Int, h: Int) -> (w: Int, h: Int) {
        let cw = max(1, min(w, maxDimension))
        let ch = max(1, min(h, maxDimension))
        let area = cw * ch
        guard area > maxArea else { return (cw, ch) }
        let scale = (Double(maxArea) / Double(area)).squareRoot()
        let scaledWidth = max(1, Int((Double(cw) * scale).rounded(.down)))
        let scaledHeight = max(1, Int((Double(ch) * scale).rounded(.down)))
        return (scaledWidth, scaledHeight)
    }

    /// The nearest-neighbor source index for output index `o` of `out` samples
    /// spanning `extent` source pixels (center sampling, all-Int). At `out ==
    /// extent` this is the identity `o`, so a full-resolution decode selects each
    /// source pixel exactly (byte-identical to a straight repack). Same sampler
    /// as `BitmapDecoder`.
    private static func nearest(_ o: Int, out: Int, extent: Int) -> Int {
        ((2 * o + 1) * extent) / (2 * out)
    }

    // MARK: - Pixel path ([MS-EMFPLUS] §2.2.2.2 / §2.2.2.3)

    /// Unpacks a pixel bitmap into a TOP-DOWN premultiplied-RGBA8 CGImage sized
    /// to `budget` (never above native — no upsampling), sampling nearest-
    /// neighbor straight from the source bytes so no full-native buffer is ever
    /// allocated (audit H1 / A2). `downsampled` is true when the output fell
    /// below native. Internal so the sampler can be unit-tested with an explicit
    /// budget. At `budget ≥ native` the sampling is the identity, so the output
    /// is byte-identical to a straight full-resolution repack.
    static func decodePixels(
        _ header: EMFPlusImageBitmapHeader, _ data: Data, budget: (w: Int, h: Int)
    ) -> (image: CGImage?, skip: Skip?, downsampled: Bool) {
        // Bytes per pixel + alpha handling from the (supported) PixelFormat.
        let bytesPerPixel: Int
        let hasAlpha: Bool
        switch header.pixelFormat {
        case pixelFormat24bppRGB:  bytesPerPixel = 3; hasAlpha = false
        case pixelFormat32bppRGB:  bytesPerPixel = 4; hasAlpha = false
        case pixelFormat32bppARGB: bytesPerPixel = 4; hasAlpha = true
        default:                   return (nil, .pixelFormat(header.pixelFormat), false)
        }

        // Positive dimensions and stride only (§2.2.2.2: Stride is positive and
        // rows are top-down; a bottom-up/degenerate bitmap is an honest skip).
        let width = Int(header.width)
        let height = Int(header.height)
        let stride = Int(header.stride)
        guard width > 0, height > 0, stride > 0 else { return (nil, .invalid, false) }

        // Cap the NATIVE pixel count with the shared canvas caps BEFORE sizing
        // anything (§8). width/height ≤ 16384 keeps width*height ≤ Int range.
        guard width <= maxDimension, height <= maxDimension, width * height <= maxArea else {
            return (nil, .invalid, false)
        }
        // The stride must hold a whole row, and the payload must hold every row —
        // both validated against the actual byte count before allocating.
        guard stride >= width * bytesPerPixel else { return (nil, .invalid, false) }
        guard Int64(stride) * Int64(height) <= Int64(data.count) else { return (nil, .invalid, false) }

        // Budget the OUTPUT: never more than native (no upsample), never less
        // than 1. downsampled when either axis fell below native.
        let outWidth = min(width, max(1, budget.w))
        let outHeight = min(height, max(1, budget.h))
        let downsampled = outWidth < width || outHeight < height

        // Straight RGBA8 output, TOP-DOWN, premultiplied for the CG bitmap
        // context (opaque formats leave alpha = 255, a no-op premultiply). Sized
        // to the BUDGET, not the native — the memory bound (audit H1 / A2).
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let filled: Bool = data.withUnsafeBytes { raw -> Bool in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let sourceCount = raw.count
            for outputRow in 0 ..< outHeight {
                let sourceY = nearest(outputRow, out: outHeight, extent: height)
                let rowStart = sourceY * stride
                // Defence in depth: the payload guard above already fits every
                // native row, but never read past the buffer regardless (§8).
                guard rowStart >= 0, rowStart + stride <= sourceCount else { return false }
                var out = outputRow * outWidth * 4
                for outputColumn in 0 ..< outWidth {
                    // GDI+ 24/32bpp pixels are stored Blue, Green, Red[, Alpha]
                    // in memory (a little-endian 0xAARRGGBB DWORD).
                    let sourceX = nearest(outputColumn, out: outWidth, extent: width)
                    let pixel = rowStart + sourceX * bytesPerPixel
                    guard pixel + bytesPerPixel <= rowStart + stride,
                          pixel + bytesPerPixel <= sourceCount else { break }
                    let blue = source[pixel]
                    let green = source[pixel + 1]
                    let red = source[pixel + 2]
                    let alpha: UInt8 = hasAlpha ? source[pixel + 3] : 255
                    if hasAlpha && alpha != 255 {
                        rgba[out]     = UInt8(UInt16(red) * UInt16(alpha) / 255)
                        rgba[out + 1] = UInt8(UInt16(green) * UInt16(alpha) / 255)
                        rgba[out + 2] = UInt8(UInt16(blue) * UInt16(alpha) / 255)
                    } else {
                        rgba[out] = red
                        rgba[out + 1] = green
                        rgba[out + 2] = blue
                    }
                    rgba[out + 3] = alpha
                    out += 4
                }
            }
            return true
        }
        guard filled else { return (nil, .invalid, false) }
        return (makeImage(rgba: &rgba, width: outWidth, height: outHeight), nil, downsampled)
    }

    // MARK: - Compressed path ([MS-EMFPLUS] §2.2.2.10 EmfPlusCompressedImage)

    private static func decodeCompressed(_ data: Data, destTargetRect: CGRect) -> (CGImage?, Skip?, Bool) {
        guard let provider = CGDataProvider(data: data as CFData) else { return (nil, .compressed, false) }

        let decoded: CGImage?
        if hasPNGMagic(data) {
            decoded = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else if hasJPEGMagic(data) {
            decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else {
            // GIF/TIFF/unknown magic: CoreGraphics has no framework-native
            // data-provider init for these (that path is ImageIO, which the
            // import rules forbid here). Honest skip.
            return (nil, .compressed, false)
        }

        guard let image = decoded else { return (nil, .compressed, false) }
        // A CGImage from a data provider is lazy, so its dimensions are cheap to
        // read; bound them by the shared caps (the outer bound) before the image
        // is ever drawn.
        guard image.width > 0, image.height > 0,
              image.width <= maxDimension, image.height <= maxDimension,
              image.width * image.height <= maxArea
        else { return (nil, .invalid, false) }

        // Destination-derived gate (audit H1 / A3): unlike the pixel path we
        // cannot band-decode a compressed stream cheaply (that is ImageIO), so an
        // image whose native size exceeds what the destination can show is
        // SKIPPED rather than fully materialised at draw time. `decodeBudget`
        // clamps to native and floors at `minPixelBudgetArea`, so: images up to
        // ~4 Mpx always pass; a large destination (the full-size app canvas)
        // yields budget == native and big photos still render; a Quick Look-
        // sized destination (its context is capped for a tight memory budget —
        // see EmfyQuickLook/PreviewProvider) yields a small budget, so an
        // oversized photo is skipped there automatically.
        let budget = decodeBudget(destTargetRect: destTargetRect, nativeW: image.width, nativeH: image.height)
        if budget.w < image.width || budget.h < image.height {
            return (nil, .oversized, false)
        }
        return (image, nil, false)
    }

    /// The 8-byte PNG signature ([RFC 2083]: 89 50 4E 47 0D 0A 1A 0A); the first
    /// four bytes are the discriminating part.
    private static func hasPNGMagic(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4))
        return head.count == 4 && head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47
    }

    /// The JPEG start-of-image marker (FF D8, followed by another FF).
    private static func hasJPEGMagic(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(3))
        return head.count >= 2 && head[0] == 0xFF && head[1] == 0xD8
    }

    // MARK: - CGImage construction

    /// Builds a top-down premultiplied-RGBA8 CGImage — the same construction the
    /// GDI DIB path uses (`BitmapDecoder.makeImage`).
    private static func makeImage(rgba: inout [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgba.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
    }
}
