import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import ImageIO

/// Image re-encoding for the EMF+ overlay export (slice E1b2a).
///
/// An edited or inserted EMF+ image is written as a COMPRESSED-PNG EmfPlusBitmap
/// ([MS-EMFPLUS] §2.2.2.2, BitmapDataType compressed = 1): LibreOffice (and other
/// GDI+ readers) ignore raw-pixel EmfPlusBitmaps but draw compressed ones (the E0
/// finding). The source pixels are decoded through EMFRender's existing CoreGraphics
/// decoder and re-encoded as PNG through ImageIO.
///
/// **ImageIO is used ONLY here, ONLY for PNG encoding** (an approved EMFEdit
/// dependency). It never touches a parse path.
enum SceneImageCoding {

    /// `EmfPlusGraphicsVersion` written into synthesised EMF+ objects (GDI+ 1.1,
    /// [MS-EMFPLUS] §2.2.2.19) — the value every handmade fixture carries.
    static let graphicsVersion: UInt32 = 0xDBC0_1002

    /// A native-resolution `CGImage` for a scene image, or nil when the source
    /// cannot be decoded. Both paths go through EMFRender's own decoders so alpha
    /// rules, pixel formats, palettes and the shared canvas caps apply: an EMF+
    /// image through `EMFPlusImageDecoder`, a GDI DIB through `BitmapDecoder`.
    static func cgImage(for image: SceneImage) -> CGImage? {
        if let plus = image.emfPlusImage { return EMFPlusImageDecoder.cgImage(from: plus) }
        if let dib = image.sourceDIB { return BitmapDecoder.cgImage(from: dib) }
        return nil
    }

    /// A compressed-PNG `EMFPlusImage` (bitmap content, `bitmapDataType` = 1) built
    /// from `image`'s source pixels, or nil when the pixels cannot be decoded or
    /// PNG-encoded. The header `Width`/`Height` are the native pixel dimensions;
    /// `Stride` and `PixelFormat` are 0 (unused for a compressed stream).
    ///
    /// A sub-1 `opacity` is baked into the PNG's alpha (slice E1b2c): the element
    /// opacity on an image needs no ImageAttributes support, so every GDI+ reader
    /// (LibreOffice included) shows the blend. The GDI fallback cannot carry it and
    /// reports `opacityDropped` instead.
    static func compressedPNGImage(for image: SceneImage, opacity: Double = 1) -> EMFPlusImage? {
        guard let decoded = cgImage(for: image) else { return nil }
        let cg = opacity < 1 ? (withOpacity(decoded, opacity) ?? decoded) : decoded
        guard let png = pngData(cg) else { return nil }
        let header = EMFPlusImageBitmapHeader(
            width: Int32(clamping: cg.width), height: Int32(clamping: cg.height),
            stride: 0, pixelFormat: 0, bitmapDataType: 1)
        return EMFPlusImage(version: graphicsVersion, content: .bitmap(header, data: png))
    }

    /// A copy of `image` with every pixel's alpha multiplied by `opacity` (0…1),
    /// drawn into a premultiplied sRGB context and read back as straight alpha the
    /// PNG encoder preserves. Nil on a bitmap allocation failure.
    static func withOpacity(_ image: CGImage, _ opacity: Double) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setAlpha(CGFloat(min(max(opacity, 0), 1)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// A 32-bpp BI_RGB TOP-DOWN BGRA DIB from a scene image's source pixels, for a
    /// dual file's STRETCHDIBITS GDI fallback. Nil when the pixels cannot be
    /// decoded. The DIB's header height is NEGATIVE: a CGBitmapContext lays its
    /// first memory row out as the TOP of the drawn image, so the buffer is
    /// top-down and the DIB must declare top-down (a positive/bottom-up height
    /// would render it upside down).
    static func dib(for image: SceneImage) -> DIB? {
        if let dib = image.sourceDIB, case .pixels = dib.content { return dib }
        guard let cg = cgImage(for: image), let bgra = bgraTopDown(cg) else { return nil }
        return DIB(
            width: Int32(clamping: cg.width), height: -Int32(clamping: cg.height),
            bitCount: 32, compression: .rgb,
            content: .pixels(bytes: bgra, stride: cg.width * 4, palette: []))
    }

    // MARK: - PNG encode (ImageIO — PNG only, EMFEdit only)

    /// PNG-encodes a `CGImage`. ImageIO is confined to this function.
    static func pngData(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    // MARK: - Pixel helpers

    /// Renders a CGImage into a TOP-DOWN BI_RGB 32-bpp BGRA buffer: the GDI
    /// STRETCHDIBITS fallback a dual file needs for an image. A CGBitmapContext's
    /// first memory row is the TOP of the drawn image (verified empirically: row 0
    /// after `draw` is the image's top scan-line), so the buffer is top-down —
    /// `dib(for:)` pairs it with a negative header height. The 32Little +
    /// premultipliedFirst combination lays bytes out as B, G, R, A, which BI_RGB
    /// expects (the reserved fourth byte is ignored by the DIB decoder).
    private static func bgraTopDown(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Data(pixels) : nil
    }
}
