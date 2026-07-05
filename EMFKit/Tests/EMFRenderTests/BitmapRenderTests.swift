import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// DIB → CGImage branch probes and blit playback (primer §6 phase 4).
/// Fixtures use MM_TEXT (default), so logical == device == image pixels and a
/// pixel probe reads exactly the DIB pixel that landed there.
@Suite("Bitmap rendering")
struct BitmapRenderTests {

    // MARK: - DIB row builders (on-disk byte order)

    /// A 24-bit BI_RGB row: pixels as B,G,R, padded to a 4-byte stride.
    private static func row24(_ pixels: [(b: UInt8, g: UInt8, r: UInt8)]) -> [UInt8] {
        var bytes: [UInt8] = []
        for p in pixels { bytes.append(contentsOf: [p.b, p.g, p.r]) }
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    /// A 32-bit BI_RGB row: pixels as B,G,R,X (already 4-aligned).
    private static func row32(_ pixels: [(b: UInt8, g: UInt8, r: UInt8)]) -> [UInt8] {
        var bytes: [UInt8] = []
        for p in pixels { bytes.append(contentsOf: [p.b, p.g, p.r, 0]) }
        return bytes
    }

    /// An 8-bit row of palette indices, padded to a 4-byte stride.
    private static func row8(_ indices: [UInt8]) -> [UInt8] {
        var bytes = indices
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    /// Renders a 1:1 STRETCHDIBITS at device origin (5,5) and returns the image.
    private static func renderDIB(
        width: Int32, height: Int32, bitCount: UInt16,
        colorUsed: UInt32 = 0, palette: [UInt8] = [], bits: [UInt8],
        destSize: (cx: Int32, cy: Int32)? = nil,
        src: (x: Int32, y: Int32) = (0, 0),
        srcSize: (cx: Int32, cy: Int32)? = nil
    ) throws -> (RasterizedImage, EMFRenderLog) {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        let absHeight = abs(height)
        let ds = destSize ?? (cx: width, cy: absHeight)
        let ss = srcSize ?? (cx: width, cy: absHeight)
        fixture.stretchDIBits(
            bounds: (0, 0, width, absHeight),
            dest: (x: 5, y: 5),
            destSize: ds,
            src: src,
            srcSize: ss,
            bmi: RenderFixture.bitmapInfoHeader(width: width, height: height, bitCount: bitCount, colorUsed: colorUsed) + palette,
            bits: bits
        )
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        return (try #require(RasterizedImage(image)), log)
    }

    // MARK: - 24-bit BGR order (the classic swap bug)

    @Test("24-bit BGR: a red source pixel comes out RED, not blue")
    func bgr24RedStaysRed() throws {
        // One pure-red pixel on disk: B=0, G=0, R=255. Bottom-up 1×1.
        let bits = Self.row24([(b: 0, g: 0, r: 255)])
        let (pixels, _) = try Self.renderDIB(width: 1, height: 1, bitCount: 24, bits: bits)
        let p = pixels[5, 5]
        #expect(p.r > 200 && p.g < 60 && p.b < 60, "24-bit red pixel came out \(p) — BGR/RGB swap bug")
    }

    @Test("24-bit BGR: blue and green channels are not confused")
    func bgr24BlueGreen() throws {
        // A blue pixel (B=255) and a green pixel (G=255) in a 2×1 bottom-up DIB.
        let bits = Self.row24([(b: 255, g: 0, r: 0), (b: 0, g: 255, r: 0)])
        let (pixels, _) = try Self.renderDIB(width: 2, height: 1, bitCount: 24, bits: bits)
        let blue = pixels[5, 5]
        let green = pixels[6, 5]
        #expect(blue.b > 200 && blue.r < 60 && blue.g < 60, "expected blue, got \(blue)")
        #expect(green.g > 200 && green.r < 60 && green.b < 60, "expected green, got \(green)")
    }

    // MARK: - 32-bit

    @Test("32-bit BGRX: red pixel comes out red, X ignored")
    func bgrx32() throws {
        // B=0,G=0,R=255,X=0x7F — the X byte must not become alpha or colour.
        var bits = Self.row32([(b: 0, g: 0, r: 255)])
        bits[3] = 0x7F   // set the unused X byte
        let (pixels, _) = try Self.renderDIB(width: 1, height: 1, bitCount: 32, bits: bits)
        let p = pixels[5, 5]
        #expect(p.r > 200 && p.g < 60 && p.b < 60 && p.a == 255, "32-bit pixel \(p)")
    }

    // MARK: - 8-bit palette + out-of-range clamp

    @Test("8-bit palettised: indices expand through the (BGRX) palette")
    func palette8() throws {
        // Palette quads on disk are B,G,R,X. Entry 0 red, entry 1 blue.
        let palette: [UInt8] = [
            0x00, 0x00, 0xFF, 0x00,   // 0: B0 G0 R255 → red
            0xFF, 0x00, 0x00, 0x00,   // 1: B255 G0 R0 → blue
        ]
        // 2×1 bottom-up: index 0 then index 1.
        let bits = Self.row8([0, 1])
        let (pixels, _) = try Self.renderDIB(width: 2, height: 1, bitCount: 8, colorUsed: 2, palette: palette, bits: bits)
        let red = pixels[5, 5]
        let blue = pixels[6, 5]
        #expect(red.r > 200 && red.b < 60, "palette entry 0 should be red, got \(red)")
        #expect(blue.b > 200 && blue.r < 60, "palette entry 1 should be blue, got \(blue)")
    }

    @Test("8-bit out-of-range index clamps to the last palette entry")
    func palette8Clamp() throws {
        // A 2-entry palette but a pixel index of 5 (out of range). The parser
        // allows a short table; the renderer clamps to the last entry (blue).
        let palette: [UInt8] = [
            0x00, 0x00, 0xFF, 0x00,   // 0: red
            0xFF, 0x00, 0x00, 0x00,   // 1: blue (last entry)
        ]
        // Build the DIB with ColorUsed=2 but a pixel index of 5.
        let bits = Self.row8([5])
        let (pixels, _) = try Self.renderDIB(width: 1, height: 1, bitCount: 8, colorUsed: 2, palette: palette, bits: bits)
        let p = pixels[5, 5]
        #expect(p.b > 200 && p.r < 60, "out-of-range index should clamp to the last (blue) entry, got \(p)")
    }

    // MARK: - Row order (bottom-up vs top-down)

    @Test("bottom-up DIB: source row 0 is the image's BOTTOM row")
    func bottomUpCorners() throws {
        // 1-wide, 2-tall bottom-up: row 0 (first in bytes) = bottom = red,
        // row 1 = top = blue. On screen the TOP pixel must be blue.
        let bottomRow = Self.row24([(b: 0, g: 0, r: 255)])   // red — stored first
        let topRow = Self.row24([(b: 255, g: 0, r: 0)])      // blue — stored second
        let bits = bottomRow + topRow
        let (pixels, _) = try Self.renderDIB(width: 1, height: 2, bitCount: 24, bits: bits)
        // Dest at device (5,5), 1×2. Image row 0 (top of the drawn block) is y=5.
        let top = pixels[5, 5]
        let bottom = pixels[5, 6]
        #expect(top.b > 200 && top.r < 60, "top pixel should be blue (bottom-up row 1), got \(top)")
        #expect(bottom.r > 200 && bottom.b < 60, "bottom pixel should be red (bottom-up row 0), got \(bottom)")
    }

    @Test("top-down DIB (negative height): source row 0 is the image's TOP row")
    func topDownCorners() throws {
        // Negative height → top-down: row 0 (first in bytes) = top = red.
        let firstRow = Self.row24([(b: 0, g: 0, r: 255)])    // red — top
        let secondRow = Self.row24([(b: 255, g: 0, r: 0)])   // blue — bottom
        let bits = firstRow + secondRow
        let (pixels, _) = try Self.renderDIB(width: 1, height: -2, bitCount: 24, bits: bits)
        let top = pixels[5, 5]
        let bottom = pixels[5, 6]
        #expect(top.r > 200 && top.b < 60, "top pixel should be red (top-down row 0), got \(top)")
        #expect(bottom.b > 200 && bottom.r < 60, "bottom pixel should be blue (top-down row 1), got \(bottom)")
    }

    // MARK: - STRETCHDIBITS mirror via negative dest

    @Test("negative cxDest mirrors the image horizontally")
    func negativeDestMirror() throws {
        // 2×1 bottom-up: left pixel red (index-0), right pixel blue. With a
        // NEGATIVE cxDest the image mirrors: the red pixel lands on the RIGHT.
        let bits = Self.row24([(b: 0, g: 0, r: 255), (b: 255, g: 0, r: 0)])   // red, blue
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // dest origin (20,5), cxDest -2 → the image spans x 18..20 mirrored,
        // so it draws leftward from x=20. Use a wide stretch to make it clear.
        fixture.stretchDIBits(
            bounds: (0, 0, 2, 1),
            dest: (x: 40, y: 5),
            destSize: (cx: -20, cy: 4),      // negative width → mirror, 20px wide
            srcSize: (cx: 2, cy: 1),
            bmi: RenderFixture.bitmapInfoHeader(width: 2, height: 1, bitCount: 24),
            bits: bits
        )
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        // The mirrored image occupies x 20..40. Non-mirrored: red on the left
        // (x~22), blue on the right (x~38). Mirrored: red on the RIGHT (x~38),
        // blue on the LEFT (x~22).
        let leftPixel = pixels[24, 6]
        let rightPixel = pixels[36, 6]
        #expect(leftPixel.b > 150 && leftPixel.r < 100, "left should be blue after mirror, got \(leftPixel)")
        #expect(rightPixel.r > 150 && rightPixel.b < 100, "right should be red after mirror, got \(rightPixel)")
    }

    // MARK: - Source sub-rect crop

    @Test("source sub-rect selects part of the DIB")
    func sourceCrop() throws {
        // 2×1 bottom-up: left red, right blue. Crop to xSrc=1,cxSrc=1 → only the
        // blue right pixel, stretched over the dest.
        let bits = Self.row24([(b: 0, g: 0, r: 255), (b: 255, g: 0, r: 0)])
        let (pixels, _) = try Self.renderDIB(
            width: 2, height: 1, bitCount: 24, bits: bits,
            destSize: (cx: 10, cy: 10),
            src: (x: 1, y: 0), srcSize: (cx: 1, cy: 1)
        )
        // The whole 10×10 dest block (device 5,5..15,15) should be blue.
        let p = pixels[9, 9]
        #expect(p.b > 200 && p.r < 60, "cropped-to-blue source came out \(p)")
    }

    // MARK: - Sourceless BITBLT fills

    @Test("sourceless BLACKNESS fills the dest black")
    func blackness() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.bitBltSourceless(dest: (x: 10, y: 10), destSize: (cx: 30, cy: 30), rasterOperation: 0x0000_0042)
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels[25, 25] == (0, 0, 0, 255))
        // A sourceless recognised fill logs nothing.
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
    }

    @Test("sourceless WHITENESS fills the dest white")
    func whiteness() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // First blacken a region, then whiten a smaller region inside it, so the
        // white fill is provable against a non-white ground.
        fixture.bitBltSourceless(dest: (x: 10, y: 10), destSize: (cx: 40, cy: 40), rasterOperation: 0x0000_0042)
        fixture.bitBltSourceless(dest: (x: 20, y: 20), destSize: (cx: 10, cy: 10), rasterOperation: 0x00FF_0062)
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels[25, 25] == (255, 255, 255, 255))
        // The surrounding black remains.
        #expect(pixels[15, 15] == (0, 0, 0, 255))
    }

    @Test("sourceless PATCOPY fills the dest with the current brush")
    func patCopy() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.createSolidBrush(index: 1, r: 0, g: 200, b: 0)   // green brush
        fixture.selectObject(1)
        fixture.bitBltSourceless(dest: (x: 10, y: 10), destSize: (cx: 30, cy: 30), rasterOperation: 0x00F0_0021)
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        let p = pixels[25, 25]
        #expect(p.g > 150 && p.r < 60 && p.b < 60, "PATCOPY should fill with the green brush, got \(p)")
    }

    @Test("sourceless STRETCHDIBITS (cbBmiSrc == 0) BLACKNESS fills the dest black")
    func stretchDIBitsSourcelessBlackness() throws {
        // A rop-only STRETCHDIBITS with no DIB now reuses BITBLT's sourceless
        // fill: BLACKNESS paints the dest black. Mirrors `blackness()`.
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.stretchDIBitsSourceless(dest: (x: 10, y: 10), destSize: (cx: 30, cy: 30), rasterOperation: 0x0000_0042)
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels[25, 25] == (0, 0, 0, 255))
        // A recognised sourceless fill logs nothing beyond the trailing EOF.
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
    }

    @Test("sourceless SETDIBITSTODEVICE (cbBmiSrc == 0) draws nothing, no crash")
    func setDIBitsToDeviceSourcelessSkipped() throws {
        // SETDIBITSTODEVICE has no raster op, so a nil-DIB record has nothing to
        // draw: the renderer skips it gracefully and the canvas stays white.
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setDIBitsToDeviceSourceless(dest: (x: 10, y: 10), srcSize: (cx: 30, cy: 30))
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        #expect(!pixels.containsDarkPixel(in: (x: 5, y: 5, width: 40, height: 40)))
        // Nothing to log beyond the trailing EOF.
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
    }

    @Test("sourceless unsupported rop is skipped with a coalesced log")
    func sourcelessUnsupportedRop() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // DSTINVERT (0x00550009) is not one of the recognised sourceless fills.
        fixture.bitBltSourceless(dest: (x: 10, y: 10), destSize: (cx: 30, cy: 30), rasterOperation: 0x0055_0009)
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .unsupportedRasterOp(rasterOperation: 0x0055_0009, count: 1),
            .unimplementedRecord(type: 14, count: 1),
        ])
        // Nothing painted.
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels[25, 25] == (255, 255, 255, 255))
    }

    // MARK: - Unsupported DIB skip

    @Test("an unsupported-compression DIB is skipped with a coalesced log")
    func unsupportedDIBSkipped() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // BI_RLE8 (compression 1) → the parser yields .unsupported(.compression).
        fixture.stretchDIBits(
            bounds: (0, 0, 2, 2),
            dest: (x: 5, y: 5),
            destSize: (cx: 20, cy: 20),
            srcSize: (cx: 2, cy: 2),
            bmi: RenderFixture.bitmapInfoHeader(width: 2, height: 2, bitCount: 8, compression: 1),
            bits: [0, 0, 0, 0]
        )
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .unsupportedDIB(reason: .compression(.rle8), count: 1),
            .unimplementedRecord(type: 14, count: 1),
        ])
        // Nothing drawn — the canvas stays white.
        let pixels = try #require(RasterizedImage(image))
        #expect(!pixels.containsDarkPixel(in: (x: 5, y: 5, width: 20, height: 20)))
    }

    @Test("interpolation is off — a stretched checker stays crisp, not blurred")
    func crispStretch() throws {
        // 2×1 bottom-up: red | blue, stretched 20× so the boundary is a hard
        // edge. With interpolation off there is no purple blend at the seam.
        let bits = Self.row24([(b: 0, g: 0, r: 255), (b: 255, g: 0, r: 0)])
        let (pixels, _) = try Self.renderDIB(
            width: 2, height: 1, bitCount: 24, bits: bits,
            destSize: (cx: 40, cy: 20)
        )
        // Dest device x 5..45; the seam is at x=25. Just left of the seam is
        // solidly red, just right solidly blue — no blended midtone.
        let leftOfSeam = pixels[23, 10]
        let rightOfSeam = pixels[27, 10]
        #expect(leftOfSeam.r > 200 && leftOfSeam.b < 60, "left of seam not crisp red: \(leftOfSeam)")
        #expect(rightOfSeam.b > 200 && rightOfSeam.r < 60, "right of seam not crisp blue: \(rightOfSeam)")
    }
}
