import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EMFParse
@testable import EMFRender

/// Unit tests for `EMFPlusImageDecoder` ([MS-EMFPLUS] §2.2.2.2): the supported
/// pixel formats, the §8 validation guards (lying stride, truncated payload,
/// oversized dimensions), the compressed PNG/JPEG paths, and the top-down
/// orientation that DrawImage/DrawImagePoints crop and placement rely on.
@Suite("EMF+ image decoder")
struct EMFPlusImageDecoderTests {

    // MARK: - Pixel formats (§2.1.1.24)

    @Test("32bpp ARGB (0x0026200A) decodes top-down with correct channels")
    func decode32bppARGB() throws {
        let image = bitmap(width: 8, height: 8, stride: 32, format: 0x0026_200A, data: quadrantARGB())
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(skip == nil)
        let cgImage = try #require(cg)
        #expect(cgImage.width == 8 && cgImage.height == 8)
        let raster = try #require(RasterizedImage(cgImage))
        #expect(isRed(raster[1, 1]), "top-left should be red, got \(raster[1, 1])")
        #expect(isGreen(raster[6, 1]), "top-right should be green, got \(raster[6, 1])")
        #expect(isBlue(raster[1, 6]), "bottom-left should be blue, got \(raster[1, 6])")
        #expect(isWhite(raster[6, 6]), "bottom-right should be white, got \(raster[6, 6])")
    }

    @Test("32bpp ARGB straight alpha is premultiplied (half-alpha red darkens)")
    func decode32bppARGBAlpha() throws {
        // One pixel, 50% alpha red (0x80,0,0,255 in B,G,R,A order → straight).
        let data = Data([0x00, 0x00, 0xFF, 0x80])
        let image = bitmap(width: 1, height: 1, stride: 4, format: 0x0026_200A, data: data)
        let (cg, _) = EMFPlusImageDecoder.decode(image)
        let cgImage = try #require(cg)
        let raster = try #require(RasterizedImage(cgImage))
        let p = raster[0, 0]
        // Premultiplied then re-composited over the RasterizedImage's black
        // clear: red is roughly halved, alpha is 0x80.
        #expect(p.r > 100 && p.r < 160, "premultiplied red ≈ 128, got \(p.r)")
        #expect(p.a > 100 && p.a < 160, "alpha ≈ 128, got \(p.a)")
    }

    @Test("24bpp RGB (0x00021808) decodes with correct channels")
    func decode24bppRGB() throws {
        let image = bitmap(width: 8, height: 8, stride: 24, format: 0x0002_1808, data: quadrant24())
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(skip == nil)
        let cgImage = try #require(cg)
        let raster = try #require(RasterizedImage(cgImage))
        #expect(isRed(raster[1, 1]) && isGreen(raster[6, 1]))
        #expect(isBlue(raster[1, 6]) && isWhite(raster[6, 6]))
    }

    @Test("32bpp RGB (0x00022009) ignores the X byte and forces opaque")
    func decode32bppRGB() throws {
        // Same layout as ARGB but the 4th byte is unused; set it to 0.
        var bytes = [UInt8](quadrantARGB())
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 0 }
        let image = bitmap(width: 8, height: 8, stride: 32, format: 0x0002_2009, data: Data(bytes))
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(skip == nil)
        let cgImage = try #require(cg)
        let raster = try #require(RasterizedImage(cgImage))
        #expect(isRed(raster[1, 1]) && raster[1, 1].a == 255, "X byte should force opaque")
    }

    @Test("an unsupported pixel format is skipped with its raw value")
    func unsupportedPixelFormat() {
        // 32bpp PARGB (0x000E200B) is premultiplied — deliberately unsupported.
        let image = bitmap(width: 2, height: 2, stride: 8, format: 0x000E_200B, data: Data(count: 16))
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(cg == nil)
        #expect(skip == .pixelFormat(0x000E_200B))
    }

    // MARK: - §8 validation

    @Test(arguments: [
        (Int32(0), Int32(8), Int32(32)),      // zero width
        (Int32(8), Int32(0), Int32(32)),      // zero height
        (Int32(-4), Int32(8), Int32(32)),     // negative width
        (Int32(8), Int32(8), Int32(0)),       // zero stride
        (Int32(8), Int32(8), Int32(8)),       // stride too small for 8×32bpp (needs 32)
    ])
    func invalidGeometrySkips(width: Int32, height: Int32, stride: Int32) {
        let image = bitmap(width: width, height: height, stride: stride, format: 0x0026_200A, data: Data(count: 256))
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(cg == nil)
        #expect(skip == .invalid)
    }

    @Test("a payload shorter than stride × height is rejected before allocation")
    func truncatedPayloadSkips() {
        // 8×8×4 needs 256 bytes; give 100 (a lying/truncated payload).
        let image = bitmap(width: 8, height: 8, stride: 32, format: 0x0026_200A, data: Data(count: 100))
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(cg == nil)
        #expect(skip == .invalid)
    }

    @Test("dimensions beyond the shared canvas caps are rejected (no allocation)")
    func oversizedDimensionsSkip() {
        // Per-side cap 16384: width 20000 is rejected before any payload check.
        let wide = bitmap(width: 20_000, height: 8, stride: 80_000, format: 0x0026_200A, data: Data())
        #expect(EMFPlusImageDecoder.decode(wide).skip == .invalid)
        // Area cap 32 Mpx: 8000×8000 = 64 Mpx is rejected.
        let big = bitmap(width: 8_000, height: 8_000, stride: 32_000, format: 0x0026_200A, data: Data())
        #expect(EMFPlusImageDecoder.decode(big).skip == .invalid)
    }

    @Test("a metafile-content image is skipped as .metafile")
    func metafileSkips() {
        let header = EMFPlusImageMetafileHeader(metafileType: 1, metafileDataSize: 4)
        let image = EMFPlusImage(version: 0xDBC0_1002, content: .metafile(header, data: Data([1, 2, 3, 4])))
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(cg == nil)
        #expect(skip == .metafile)
    }

    // MARK: - Compressed path (§2.2.2.10)

    @Test("a compressed PNG stream decodes through CoreGraphics")
    func compressedPNG() throws {
        let png = encodedImage(width: 5, height: 3, utType: .png, r: 200, g: 40, b: 40)
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: png)
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(skip == nil)
        let cgImage = try #require(cg)
        #expect(cgImage.width == 5 && cgImage.height == 3)
    }

    @Test("a compressed JPEG stream decodes through CoreGraphics")
    func compressedJPEG() throws {
        let jpeg = encodedImage(width: 6, height: 4, utType: .jpeg, r: 40, g: 180, b: 40)
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: jpeg)
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(skip == nil)
        let cgImage = try #require(cg)
        #expect(cgImage.width == 6 && cgImage.height == 4)
    }

    @Test("an unknown compressed magic (not PNG/JPEG) is skipped")
    func compressedUnknownSkips() {
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: Data([0x47, 0x49, 0x46, 0x38]))  // "GIF8"
        let (cg, skip) = EMFPlusImageDecoder.decode(image)
        #expect(cg == nil)
        #expect(skip == .compressed)
    }

    @Test("a corrupt PNG (valid magic, garbage body) is skipped, not trapped")
    func corruptPNGSkips() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  // PNG signature
        bytes += [UInt8](repeating: 0x00, count: 16)                            // then garbage
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: Data(bytes))
        #expect(EMFPlusImageDecoder.decode(image).skip == .compressed)
    }

    // MARK: - Orientation / crop (top-down CGImage.cropping)

    @Test("cropping the decoded image to a quadrant selects the expected colour")
    func cropOrientation() throws {
        let image = bitmap(width: 8, height: 8, stride: 32, format: 0x0026_200A, data: quadrantARGB())
        let cgImage = try #require(EMFPlusImageDecoder.decode(image).image)
        // Top-right quadrant (pixels 4..7, rows 0..3) is green; crop selects it.
        let cropped = try #require(cgImage.cropping(to: CGRect(x: 4, y: 0, width: 4, height: 4)))
        let raster = try #require(RasterizedImage(cropped))
        #expect(isGreen(raster[1, 1]) && isGreen(raster[2, 2]), "cropped quadrant not green")
        // Bottom-left quadrant (rows 4..7) is blue.
        let blue = try #require(cgImage.cropping(to: CGRect(x: 0, y: 4, width: 4, height: 4)))
        #expect(isBlue(try #require(RasterizedImage(blue))[2, 2]))
    }

    // MARK: - Destination decode budget (audit H1 / A2)

    @Test("a footprint at or above native clamps the budget to native (no upsampling)")
    func budgetClampsToNative() {
        let budget = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: 9000, height: 9000), nativeW: 5000, nativeH: 5000)
        #expect(budget.w == 5000 && budget.h == 5000)
    }

    @Test("a footprint above the floor drives a below-native budget")
    func budgetFollowsFootprintAboveFloor() {
        // 2500×2500 = 6.25 Mpx > the 4 Mpx floor; native 5000×5000 → follows.
        let budget = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: 2500, height: 2500), nativeW: 5000, nativeH: 5000)
        #expect(budget.w == 2500 && budget.h == 2500)
    }

    @Test("a tiny footprint is floored to ~minPixelBudgetArea, capped at native")
    func budgetFloorsSmallDestinations() {
        // Native 3000×3000 = 9 Mpx, a 20×20 dest → floored up to ≥ 4 Mpx, < native.
        let budget = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: 20, height: 20), nativeW: 3000, nativeH: 3000)
        #expect(budget.w * budget.h >= EMFPlusImageDecoder.minPixelBudgetArea, "floored to the min area, got \(budget)")
        #expect(budget.w < 3000 && budget.h < 3000, "still below native, got \(budget)")
        #expect(budget.w == budget.h, "a square native stays square")
    }

    @Test("an image at or below the floor always budgets to native (small images untouched)")
    func budgetNeverShrinksSmallImages() {
        // Native 100×100 (10k px) ≤ the floor → a 5×5 dest still budgets to
        // native, so small images decode byte-identically (snapshot safety).
        let budget = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: 5, height: 5), nativeW: 100, nativeH: 100)
        #expect(budget.w == 100 && budget.h == 100)
    }

    @Test("a non-finite footprint falls back to native")
    func budgetNonFiniteFallsBackToNative() {
        let nan = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100), nativeW: 640, nativeH: 480)
        #expect(nan.w == 640 && nan.h == 480)
        let unbounded = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: EMFPlusImageDecoder.unbounded, nativeW: 640, nativeH: 480)
        #expect(unbounded.w == 640 && unbounded.h == 480)
    }

    @Test("the shared area cap bounds an at-cap native, aspect preserved")
    func budgetHonoursAreaCap() {
        let budget = EMFPlusImageDecoder.decodeBudget(
            destTargetRect: CGRect(x: 0, y: 0, width: 1e9, height: 1e9), nativeW: 16_384, nativeH: 16_384)
        #expect(budget.w == budget.h)
        #expect(budget.w * budget.h <= EMFRenderer.canvasAreaCap)
        #expect(budget.w <= EMFRenderer.canvasDimensionCap)
    }

    // MARK: - Pixel decode budget / downsampling (audit H1 / A2)

    @Test("decodePixels honours a below-native budget: reduced dims, downsample flag, quadrants")
    func decodePixelsDownsamples() throws {
        let header = EMFPlusImageBitmapHeader(width: 8, height: 8, stride: 32, pixelFormat: 0x0026_200A, bitmapDataType: 0)
        let (cg, skip, downsampled) = EMFPlusImageDecoder.decodePixels(header, quadrantARGB(), budget: (w: 4, h: 4))
        #expect(skip == nil)
        #expect(downsampled, "a 4×4 budget over an 8×8 image must downsample")
        let cgImage = try #require(cg)
        #expect(cgImage.width == 4 && cgImage.height == 4, "output sized to the budget, got \(cgImage.width)×\(cgImage.height)")
        let raster = try #require(RasterizedImage(cgImage))
        #expect(isRed(raster[0, 0]), "top-left quadrant, got \(raster[0, 0])")
        #expect(isGreen(raster[3, 0]), "top-right quadrant, got \(raster[3, 0])")
        #expect(isBlue(raster[0, 3]), "bottom-left quadrant, got \(raster[0, 3])")
        #expect(isWhite(raster[3, 3]), "bottom-right quadrant, got \(raster[3, 3])")
    }

    @Test("decodePixels at a budget ≥ native does not downsample")
    func decodePixelsIdentityWhenBudgetAboveNative() throws {
        let header = EMFPlusImageBitmapHeader(width: 8, height: 8, stride: 32, pixelFormat: 0x0026_200A, bitmapDataType: 0)
        let (cg, skip, downsampled) = EMFPlusImageDecoder.decodePixels(header, quadrantARGB(), budget: (w: 100, h: 100))
        #expect(skip == nil)
        #expect(!downsampled, "budget ≥ native must not downsample")
        let cgImage = try #require(cg)
        #expect(cgImage.width == 8 && cgImage.height == 8)
        let raster = try #require(RasterizedImage(cgImage))
        #expect(isRed(raster[1, 1]) && isGreen(raster[6, 1]) && isBlue(raster[1, 6]) && isWhite(raster[6, 6]))
    }

    // MARK: - Compressed destination gate (audit H1 / A3)
    //
    // PNG synthesis is already available here via `encodedImage` (test-only
    // ImageIO), so the oversized-skip path is exercised against a REAL
    // CoreGraphics decode with no new import. The playback mapping
    // (`.oversized` → `.imageOversized`, re-noted per draw) is compiler-forced by
    // the exhaustive `note(imageSkip:)` switch and mirrors the four sibling skip
    // mappings already driven through playback in the image-playback suite.

    @Test("an oversized compressed image drawn into a small dest is skipped as .oversized")
    func compressedOversizedSkips() {
        // A solid 2100×2100 PNG (4.41 Mpx > the 4 Mpx floor) compresses tiny but
        // decodes large; a ~40px destination footprint gates it out (A3).
        let png = encodedImage(width: 2100, height: 2100, utType: .png, r: 30, g: 120, b: 210)
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: png)
        let (cg, skip, _) = EMFPlusImageDecoder.decode(image, destTargetRect: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(cg == nil)
        #expect(skip == .oversized, "expected .oversized, got \(String(describing: skip))")
    }

    @Test("the same compressed image drawn into a large dest still renders")
    func compressedInBudgetRenders() throws {
        let png = encodedImage(width: 2100, height: 2100, utType: .png, r: 30, g: 120, b: 210)
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: png)
        // A destination as large as the image → budget == native → not gated.
        let (cg, skip, _) = EMFPlusImageDecoder.decode(image, destTargetRect: CGRect(x: 0, y: 0, width: 2100, height: 2100))
        #expect(skip == nil, "a full-size destination must not gate, got \(String(describing: skip))")
        let cgImage = try #require(cg)
        #expect(cgImage.width == 2100 && cgImage.height == 2100)
    }

    @Test("a small compressed image always renders regardless of dest (the floor protects it)")
    func compressedBelowFloorAlwaysRenders() throws {
        let png = encodedImage(width: 100, height: 100, utType: .png, r: 200, g: 40, b: 40)
        let image = bitmap(width: 0, height: 0, stride: 0, format: 0, type: 1, data: png)
        let (cg, skip, _) = EMFPlusImageDecoder.decode(image, destTargetRect: CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(skip == nil, "an image at/below the floor must render at any dest, got \(String(describing: skip))")
        #expect(try #require(cg).width == 100)
    }

    // MARK: - Fixtures

    private func bitmap(width: Int32, height: Int32, stride: Int32, format: UInt32, type: UInt32 = 0, data: Data) -> EMFPlusImage {
        let header = EMFPlusImageBitmapHeader(
            width: width, height: height, stride: stride, pixelFormat: format, bitmapDataType: type)
        return EMFPlusImage(version: 0xDBC0_1002, content: .bitmap(header, data: data))
    }

    /// An 8×8 four-quadrant 32bpp-ARGB pixel buffer (B,G,R,A per pixel), top-down:
    /// red (top-left), green (top-right), blue (bottom-left), white (bottom-right).
    private func quadrantARGB() -> Data {
        Data(quadrantBytes(bytesPerPixel: 4))
    }

    /// The same four quadrants as 24bpp (B,G,R per pixel); stride 24 is 4-aligned.
    private func quadrant24() -> Data {
        Data(quadrantBytes(bytesPerPixel: 3))
    }

    private func quadrantBytes(bytesPerPixel: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for row in 0 ..< 8 {
            for col in 0 ..< 8 {
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch (row < 4, col < 4) {
                case (true, true):   (r, g, b) = (255, 0, 0)
                case (true, false):  (r, g, b) = (0, 255, 0)
                case (false, true):  (r, g, b) = (0, 0, 255)
                case (false, false): (r, g, b) = (255, 255, 255)
                }
                bytes += bytesPerPixel == 4 ? [b, g, r, 255] : [b, g, r]
            }
        }
        return bytes
    }

    /// Encodes a solid-colour image to PNG/JPEG bytes via ImageIO (test-only —
    /// the decoder itself imports only CoreGraphics).
    private func encodedImage(width: Int, height: Int, utType: UTType, r: UInt8, g: UInt8, b: UInt8) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, utType.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        _ = CGImageDestinationFinalize(destination)
        return out as Data
    }

    // MARK: - Colour predicates

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 70 && p.b < 70 }
    private func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 130 && p.r < 90 && p.b < 90 }
    private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 70 && p.g < 70 }
    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 }
}
