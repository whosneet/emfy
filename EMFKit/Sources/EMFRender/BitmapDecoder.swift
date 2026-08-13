import CoreGraphics
import EMFParse
import Foundation

/// DIB (`.pixels`) → CGImage, decoded at no more resolution than the render
/// destination can show ("decode-in-bands"). The source sub-rect crop is folded
/// into a nearest-neighbor sampler that reads the device-independent bitmap the
/// parser validated straight out of the source `Data` — the full-native
/// source-byte copy and the full-native RGBA buffer are gone; only the budgeted
/// output (≤ what the target can display) is materialised.
///
/// The parser guarantees (primer §8): `bytes.count == stride × |height|`, the
/// stride is the padded row length, dimensions are within the caps, and for
/// palettised DIBs the palette is present (possibly SHORT — clamping
/// out-of-range indices to the last entry is this renderer's documented duty).
///
/// EMF/DIB row order: BOTTOM-UP when the header height is positive (source row
/// 0 is the image's bottom row), TOP-DOWN when negative. The output CGImage is
/// always top-down (row 0 = top), so a bottom-up source is read in reverse.
enum BitmapDecoder {

    /// A source sub-rectangle in SOURCE pixels (top-down image space): the
    /// STRETCHDIBITS/BITBLT src fields, or the SETDIBITSTODEVICE scan window.
    /// Hostile or out-of-range values are clamped inside `decode`; a degenerate
    /// or fully-out-of-bounds rect selects the whole image (matching the old
    /// crop's pass-through so the common "src == whole DIB" case is untouched).
    struct SourceRect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// Reuse the renderer's canvas caps so a DIB decode and the canvas share ONE
    /// clamp rule (per-side 16384, total area 32 Mpx). In practice the parser
    /// already caps a `.pixels` DIB at 4 Mpx, so these bound only an
    /// aspect-extreme or directly-constructed bitmap; the rule is stated once.
    private static let maxDimension = EMFRenderer.canvasDimensionCap
    private static let maxArea = EMFRenderer.canvasAreaCap

    // MARK: - Budget (pure, unit-testable)

    /// The decode budget for a DIB destination: how many source pixels the
    /// target can actually show. `destTargetRect` is the destination footprint
    /// in TARGET space (the logical dest rect transformed by
    /// `dc.resolvedTransform ∘ base`, standardized — NOT the context's
    /// width/height, which is 0 for a PDF/vector context). Each side is ceil'd
    /// (a fractional pixel still needs a whole source pixel), floored at 1,
    /// capped at the DIB's native size (never upsample the decode) and at the
    /// shared canvas caps. A non-finite footprint (a hostile world transform)
    /// falls back to the whole native size — still bounded by the parser's own
    /// 4 Mpx DIB cap.
    static func decodeBudget(destTargetRect: CGRect, nativeW: Int, nativeH: Int) -> (w: Int, h: Int) {
        let nativeW = max(1, nativeW)
        let nativeH = max(1, nativeH)
        let footprintW = destTargetRect.width
        let footprintH = destTargetRect.height
        guard footprintW.isFinite, footprintH.isFinite else {
            return clampToCaps(w: nativeW, h: nativeH)
        }
        let w = min(ceilToDimension(footprintW), nativeW)
        let h = min(ceilToDimension(footprintH), nativeH)
        return clampToCaps(w: max(1, w), h: max(1, h))
    }

    /// Ceils a finite footprint side to an Int in [0, maxDimension]. Clamping at
    /// the cap makes the Int conversion overflow-proof for any finite input
    /// (§8: no trapping conversions on file-derived values).
    private static func ceilToDimension(_ value: CGFloat) -> Int {
        let ceiled = value.rounded(.up)
        if ceiled <= 0 { return 0 }
        if ceiled >= CGFloat(maxDimension) { return maxDimension }
        return Int(ceiled)
    }

    /// Clamps a budget to the shared per-side and total-area caps, preserving
    /// aspect ratio on the area clamp (mirrors `EMFRenderer.clampArea`). Both
    /// inputs are floored at 1 and capped per side first, so `cw * ch` cannot
    /// overflow.
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

    // MARK: - Decode

    /// Builds a CGImage from a decoded DIB, sampling the `srcRect` sub-rectangle
    /// (source pixels) directly from the source bytes at no more than `budget`
    /// resolution — nearest-neighbor, never upsampling past the crop's native
    /// size. Returns the image (or `nil` + reason when unsupported or
    /// unbuildable) and whether the decode fell below the crop's native
    /// resolution (for the coalesced downsample log). 24-bit rows are B,G,R;
    /// 32-bit are B,G,R,X; 8-bit are palette indices through the (BGRX) table.
    ///
    /// The whole-image, no-downscale case (budget ≥ native, `srcRect` covers the
    /// image) is bit-for-bit identical to a straight full-resolution repack:
    /// nearest sampling at 1:1 selects each source pixel exactly.
    static func decode(
        _ dib: DIB,
        srcRect: SourceRect,
        budget: (w: Int, h: Int)
    ) -> (image: CGImage?, reason: DIBUnsupportedReason?, downsampled: Bool) {
        guard case .pixels(let bytes, let stride, let palette) = dib.content else {
            if case .unsupported(let reason) = dib.content {
                return (nil, reason, false)
            }
            return (nil, nil, false)
        }

        let width = Int(dib.width)
        let height = abs(Int(dib.height))
        guard width > 0, height > 0, stride > 0 else { return (nil, nil, false) }
        guard dib.bitCount == 24 || dib.bitCount == 32 || dib.bitCount == 8 else {
            return (nil, .bitCount(dib.bitCount), false)
        }

        // Fold the crop: clamp `srcRect` to the image; a degenerate or
        // fully-out-of-bounds rect selects the whole image (old crop fallback).
        let crop = cropRegion(srcRect, width: width, height: height)

        // Never sample more pixels than the destination can show (budget) or the
        // crop offers (native, no upsampling).
        let outWidth = min(crop.width, max(1, budget.w))
        let outHeight = min(crop.height, max(1, budget.h))
        guard outWidth > 0, outHeight > 0 else { return (nil, nil, false) }
        let downsampled = outWidth < crop.width || outHeight < crop.height

        // Straight RGBA8 output, top-down — sized to the budget, not the native.
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let topDown = dib.isTopDown

        // ONE borrow of the source bytes: no full-native `[UInt8]` copy.
        let filled: Bool = bytes.withUnsafeBytes { raw -> Bool in
            guard raw.baseAddress != nil else { return false }
            switch dib.bitCount {
            case 24:
                return sample24(into: &rgba, source: raw, crop: crop, outWidth: outWidth, outHeight: outHeight, height: height, stride: stride, topDown: topDown)
            case 32:
                return sample32(into: &rgba, source: raw, crop: crop, outWidth: outWidth, outHeight: outHeight, height: height, stride: stride, topDown: topDown)
            default:   // 8-bit (the bitCount set is guarded above)
                return sample8(into: &rgba, source: raw, palette: palette, crop: crop, outWidth: outWidth, outHeight: outHeight, height: height, stride: stride, topDown: topDown)
            }
        }
        guard filled else { return (nil, nil, false) }

        return (makeImage(rgba: &rgba, width: outWidth, height: outHeight), nil, downsampled)
    }

    // MARK: - Crop selection

    /// The output-image pixel rectangle (top-down source space) after clamping
    /// `src` to the image. Mirrors the old `crop`: origin ≤ 0 and size ≥ image
    /// passes the whole image through, and a non-positive or fully-out-of-bounds
    /// rect also selects the whole image.
    private struct CropRegion { var x: Int; var y: Int; var width: Int; var height: Int }

    private static func cropRegion(_ src: SourceRect, width: Int, height: Int) -> CropRegion {
        if src.x <= 0, src.y <= 0, src.width >= width, src.height >= height {
            return CropRegion(x: 0, y: 0, width: width, height: height)
        }
        let x0 = max(0, min(src.x, width))
        let y0 = max(0, min(src.y, height))
        let w = max(0, min(src.width, width - x0))
        let h = max(0, min(src.height, height - y0))
        guard w > 0, h > 0 else { return CropRegion(x: 0, y: 0, width: width, height: height) }
        return CropRegion(x: x0, y: y0, width: w, height: h)
    }

    /// The nearest-neighbor source index for output index `o` of `out` samples
    /// spanning `extent` source pixels (center sampling, all-Int). At 1:1
    /// (`out == extent`) this is the identity `o`, so the fast path selects each
    /// source pixel exactly. `out ≥ 1` and `o < out ≤ extent`, so the result is
    /// in `[0, extent - 1]` and the product cannot overflow at the DIB caps.
    private static func nearest(_ o: Int, out: Int, extent: Int) -> Int {
        ((2 * o + 1) * extent) / (2 * out)
    }

    // MARK: - Per-format samplers

    /// The source-buffer offset of the image row (top-down space) at `imageRow`,
    /// honouring the bottom-up/top-down flag; `nil` when that row falls outside
    /// the source bytes (defence in depth — the parser sizes bytes to fit).
    private static func rowStart(
        imageRow: Int, height: Int, stride: Int, sourceCount: Int, topDown: Bool
    ) -> Int? {
        let sourceRow = topDown ? imageRow : (height - 1 - imageRow)
        let offset = sourceRow * stride
        guard offset >= 0, offset + stride <= sourceCount else { return nil }
        return offset
    }

    /// 24-bit BI_RGB: each pixel is Blue, Green, Red (3 bytes); rows padded to
    /// `stride`. Read R from byte 2 (the classic swap bug is passing B,G,R
    /// straight through).
    private static func sample24(
        into rgba: inout [UInt8], source: UnsafeRawBufferPointer,
        crop: CropRegion, outWidth: Int, outHeight: Int,
        height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        let sourceCount = source.count
        for outputRow in 0 ..< outHeight {
            let sourceY = crop.y + nearest(outputRow, out: outHeight, extent: crop.height)
            guard let rowStart = rowStart(imageRow: sourceY, height: height, stride: stride, sourceCount: sourceCount, topDown: topDown) else {
                return false
            }
            var out = outputRow * outWidth * 4
            for outputColumn in 0 ..< outWidth {
                let sourceX = crop.x + nearest(outputColumn, out: outWidth, extent: crop.width)
                let pixel = rowStart + sourceX * 3
                // Column guard: stride padding may leave the tail short.
                guard pixel + 2 < rowStart + stride, pixel + 2 < sourceCount else { break }
                rgba[out] = source[pixel + 2]       // R (disk byte 2)
                rgba[out + 1] = source[pixel + 1]   // G
                rgba[out + 2] = source[pixel]       // B (disk byte 0)
                rgba[out + 3] = 255
                out += 4
            }
        }
        return true
    }

    /// 32-bit BI_RGB: each pixel is Blue, Green, Red, Unused (X). The X byte is
    /// NOT alpha under BI_RGB, so it is ignored and alpha forced opaque.
    private static func sample32(
        into rgba: inout [UInt8], source: UnsafeRawBufferPointer,
        crop: CropRegion, outWidth: Int, outHeight: Int,
        height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        let sourceCount = source.count
        for outputRow in 0 ..< outHeight {
            let sourceY = crop.y + nearest(outputRow, out: outHeight, extent: crop.height)
            guard let rowStart = rowStart(imageRow: sourceY, height: height, stride: stride, sourceCount: sourceCount, topDown: topDown) else {
                return false
            }
            var out = outputRow * outWidth * 4
            for outputColumn in 0 ..< outWidth {
                let sourceX = crop.x + nearest(outputColumn, out: outWidth, extent: crop.width)
                let pixel = rowStart + sourceX * 4
                guard pixel + 3 < rowStart + stride, pixel + 3 < sourceCount else { break }
                rgba[out] = source[pixel + 2]       // R
                rgba[out + 1] = source[pixel + 1]   // G
                rgba[out + 2] = source[pixel]       // B
                rgba[out + 3] = 255                 // X ignored; opaque
                out += 4
            }
        }
        return true
    }

    /// 8-bit palettised: each pixel is a color-table index. Out-of-range indices
    /// CLAMP to the last palette entry — the parser deliberately allows a short
    /// color table, so this is the renderer's documented safety net.
    private static func sample8(
        into rgba: inout [UInt8], source: UnsafeRawBufferPointer, palette: [RGBQuad],
        crop: CropRegion, outWidth: Int, outHeight: Int,
        height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        guard let lastEntry = palette.last else { return false }   // no palette → cannot expand
        let sourceCount = source.count
        for outputRow in 0 ..< outHeight {
            let sourceY = crop.y + nearest(outputRow, out: outHeight, extent: crop.height)
            guard let rowStart = rowStart(imageRow: sourceY, height: height, stride: stride, sourceCount: sourceCount, topDown: topDown) else {
                return false
            }
            var out = outputRow * outWidth * 4
            for outputColumn in 0 ..< outWidth {
                let sourceX = crop.x + nearest(outputColumn, out: outWidth, extent: crop.width)
                let pixel = rowStart + sourceX
                guard pixel < rowStart + stride, pixel < sourceCount else { break }
                let index = Int(source[pixel])
                let quad = index < palette.count ? palette[index] : lastEntry
                rgba[out] = quad.red
                rgba[out + 1] = quad.green
                rgba[out + 2] = quad.blue
                rgba[out + 3] = 255
                out += 4
            }
        }
        return true
    }

    // MARK: - CGImage construction

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
