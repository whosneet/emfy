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
    }

    // MARK: - Entry point

    /// Decodes an EmfPlusImage into a TOP-DOWN CGImage (row 0 = top), or a
    /// `Skip` reason when it cannot. Never traps.
    static func decode(_ image: EMFPlusImage) -> (image: CGImage?, skip: Skip?) {
        switch image.content {
        case .metafile:
            return (nil, .metafile)
        case .bitmap(let header, let data):
            switch header.bitmapDataType {
            case 0x0000_0000:   // BitmapDataTypePixel
                return decodePixels(header, data)
            case 0x0000_0001:   // BitmapDataTypeCompressed
                return decodeCompressed(data)
            default:
                return (nil, .compressed)
            }
        }
    }

    // MARK: - Pixel path ([MS-EMFPLUS] §2.2.2.2 / §2.2.2.3)

    private static func decodePixels(_ header: EMFPlusImageBitmapHeader, _ data: Data) -> (CGImage?, Skip?) {
        // Bytes per pixel + alpha handling from the (supported) PixelFormat.
        let bytesPerPixel: Int
        let hasAlpha: Bool
        switch header.pixelFormat {
        case pixelFormat24bppRGB:  bytesPerPixel = 3; hasAlpha = false
        case pixelFormat32bppRGB:  bytesPerPixel = 4; hasAlpha = false
        case pixelFormat32bppARGB: bytesPerPixel = 4; hasAlpha = true
        default:                   return (nil, .pixelFormat(header.pixelFormat))
        }

        // Positive dimensions and stride only (§2.2.2.2: Stride is positive and
        // rows are top-down; a bottom-up/degenerate bitmap is an honest skip).
        let width = Int(header.width)
        let height = Int(header.height)
        let stride = Int(header.stride)
        guard width > 0, height > 0, stride > 0 else { return (nil, .invalid) }

        // Cap the decoded pixel count with the shared canvas caps BEFORE sizing
        // anything (§8). width/height ≤ 16384 keeps width*height ≤ Int range.
        guard width <= maxDimension, height <= maxDimension, width * height <= maxArea else {
            return (nil, .invalid)
        }
        // The stride must hold a whole row, and the payload must hold every row —
        // both validated against the actual byte count before allocating.
        guard stride >= width * bytesPerPixel else { return (nil, .invalid) }
        guard Int64(stride) * Int64(height) <= Int64(data.count) else { return (nil, .invalid) }

        // Straight RGBA8 output, TOP-DOWN, premultiplied for the CG bitmap
        // context (opaque formats leave alpha = 255, a no-op premultiply).
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let filled: Bool = data.withUnsafeBytes { raw -> Bool in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            for row in 0 ..< height {
                let rowStart = row * stride
                var out = row * width * 4
                for column in 0 ..< width {
                    // GDI+ 24/32bpp pixels are stored Blue, Green, Red[, Alpha]
                    // in memory (a little-endian 0xAARRGGBB DWORD).
                    let pixel = rowStart + column * bytesPerPixel
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
        guard filled else { return (nil, .invalid) }
        return (makeImage(rgba: &rgba, width: width, height: height), nil)
    }

    // MARK: - Compressed path ([MS-EMFPLUS] §2.2.2.10 EmfPlusCompressedImage)

    private static func decodeCompressed(_ data: Data) -> (CGImage?, Skip?) {
        guard let provider = CGDataProvider(data: data as CFData) else { return (nil, .compressed) }

        let decoded: CGImage?
        if hasPNGMagic(data) {
            decoded = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else if hasJPEGMagic(data) {
            decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else {
            // GIF/TIFF/unknown magic: CoreGraphics has no framework-native
            // data-provider init for these (that path is ImageIO, which the
            // import rules forbid here). Honest skip.
            return (nil, .compressed)
        }

        guard let image = decoded else { return (nil, .compressed) }
        // A CGImage from a data provider is lazy, so its dimensions are cheap to
        // read; bound them by the shared caps before the image is ever drawn.
        guard image.width > 0, image.height > 0,
              image.width <= maxDimension, image.height <= maxDimension,
              image.width * image.height <= maxArea
        else { return (nil, .invalid) }
        return (image, nil)
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
