import CoreGraphics
import EMFParse
import Foundation

/// DIB (`.pixels`) → CGImage. Repacks the device-independent bitmap the parser
/// validated into a straight top-down RGBA8 CGImage the renderer can blit.
///
/// The parser guarantees (primer §8): `bytes.count >= stride × |height|`, the
/// stride is the padded row length, dimensions are within the caps, and for
/// palettised DIBs the palette is present (possibly SHORT — clamping
/// out-of-range indices to the last entry is this renderer's documented duty).
///
/// EMF/DIB row order: BOTTOM-UP when the header height is positive (source row
/// 0 is the image's bottom row), TOP-DOWN when negative. The output CGImage is
/// always top-down (row 0 = top), so a bottom-up source is read in reverse.
enum BitmapDecoder {

    /// Builds a CGImage from a decoded DIB, or `nil` (with the reason for the
    /// caller to log) when the content is unsupported or an image cannot be
    /// constructed. 24-bit rows are B,G,R; 32-bit are B,G,R,X; 8-bit are
    /// palette indices expanded through the (BGRX) color table.
    static func image(from dib: DIB) -> (CGImage?, DIBUnsupportedReason?) {
        guard case .pixels(let bytes, let stride, let palette) = dib.content else {
            if case .unsupported(let reason) = dib.content {
                return (nil, reason)
            }
            return (nil, nil)
        }

        let width = Int(dib.width)
        let height = abs(Int(dib.height))
        guard width > 0, height > 0, stride > 0 else { return (nil, nil) }

        // Straight RGBA8 output, top-down.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let source = [UInt8](bytes)
        let topDown = dib.isTopDown

        let filled: Bool
        switch dib.bitCount {
        case 24:
            filled = fill24(into: &rgba, source: source, width: width, height: height, stride: stride, topDown: topDown)
        case 32:
            filled = fill32(into: &rgba, source: source, width: width, height: height, stride: stride, topDown: topDown)
        case 8:
            filled = fill8(into: &rgba, source: source, palette: palette, width: width, height: height, stride: stride, topDown: topDown)
        default:
            return (nil, .bitCount(dib.bitCount))
        }
        guard filled else { return (nil, nil) }

        return (makeImage(rgba: &rgba, width: width, height: height), nil)
    }

    // MARK: - Per-format row fills

    /// The source-buffer offset of the image row that lands at output row
    /// `outputRow` (0 = top), honouring the bottom-up/top-down flag. Returns
    /// `nil` when that row would fall outside the source bytes.
    private static func rowOffset(
        outputRow: Int, height: Int, stride: Int, sourceCount: Int, topDown: Bool
    ) -> Int? {
        let sourceRow = topDown ? outputRow : (height - 1 - outputRow)
        let offset = sourceRow * stride
        guard offset >= 0, offset + stride <= sourceCount else { return nil }
        return offset
    }

    /// 24-bit BI_RGB: each pixel is Blue, Green, Red (3 bytes); rows padded to
    /// `stride`. A red pixel on disk is (B=0, G=0, R=255) — the classic swap
    /// bug is writing those straight through; we read R from byte 2.
    private static func fill24(
        into rgba: inout [UInt8], source: [UInt8],
        width: Int, height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        for outputRow in 0 ..< height {
            guard let rowStart = rowOffset(outputRow: outputRow, height: height, stride: stride, sourceCount: source.count, topDown: topDown) else {
                return false
            }
            var out = outputRow * width * 4
            for column in 0 ..< width {
                let pixel = rowStart + column * 3
                // Column guard: stride padding may leave the tail short.
                guard pixel + 2 < rowStart + stride, pixel + 2 < source.count else { break }
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
    private static func fill32(
        into rgba: inout [UInt8], source: [UInt8],
        width: Int, height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        for outputRow in 0 ..< height {
            guard let rowStart = rowOffset(outputRow: outputRow, height: height, stride: stride, sourceCount: source.count, topDown: topDown) else {
                return false
            }
            var out = outputRow * width * 4
            for column in 0 ..< width {
                let pixel = rowStart + column * 4
                guard pixel + 3 < rowStart + stride, pixel + 3 < source.count else { break }
                rgba[out] = source[pixel + 2]       // R
                rgba[out + 1] = source[pixel + 1]   // G
                rgba[out + 2] = source[pixel]       // B
                rgba[out + 3] = 255                 // X ignored; opaque
                out += 4
            }
        }
        return true
    }

    /// 8-bit palettised: each pixel is a color-table index. Out-of-range
    /// indices CLAMP to the last palette entry — the parser deliberately allows
    /// a short color table, so this is the renderer's documented safety net.
    private static func fill8(
        into rgba: inout [UInt8], source: [UInt8], palette: [RGBQuad],
        width: Int, height: Int, stride: Int, topDown: Bool
    ) -> Bool {
        guard let lastEntry = palette.last else { return false }   // no palette → cannot expand
        for outputRow in 0 ..< height {
            guard let rowStart = rowOffset(outputRow: outputRow, height: height, stride: stride, sourceCount: source.count, topDown: topDown) else {
                return false
            }
            var out = outputRow * width * 4
            for column in 0 ..< width {
                let pixel = rowStart + column
                guard pixel < rowStart + stride, pixel < source.count else { break }
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
