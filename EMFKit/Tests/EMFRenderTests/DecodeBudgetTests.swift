import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Hand-built DIBs for the sampler tests. `imageRows` is always TOP-DOWN
/// (row 0 = the image's top row); the builder lays the bytes out bottom-up
/// (positive header height) or top-down (negative) so the decoder's row-order
/// handling is exercised from both storage orders.
private enum DIBSample {

    static func make24(imageRows: [[(b: UInt8, g: UInt8, r: UInt8)]], topDown: Bool) -> DIB {
        let height = imageRows.count
        let width = imageRows.first?.count ?? 0
        let stride = ((width * 24 + 31) / 32) * 4
        let physical = topDown ? imageRows : Array(imageRows.reversed())
        var bytes = [UInt8]()
        for row in physical {
            var rowBytes = [UInt8]()
            for p in row { rowBytes.append(contentsOf: [p.b, p.g, p.r]) }
            while rowBytes.count < stride { rowBytes.append(0) }
            bytes.append(contentsOf: rowBytes)
        }
        return DIB(
            width: Int32(width), height: topDown ? -Int32(height) : Int32(height),
            bitCount: 24, compression: .rgb,
            content: .pixels(bytes: Data(bytes), stride: stride, palette: [])
        )
    }

    static func make32(imageRows: [[(b: UInt8, g: UInt8, r: UInt8, x: UInt8)]], topDown: Bool) -> DIB {
        let height = imageRows.count
        let width = imageRows.first?.count ?? 0
        let stride = width * 4   // 32-bit rows are always 4-aligned.
        let physical = topDown ? imageRows : Array(imageRows.reversed())
        var bytes = [UInt8]()
        for row in physical {
            for p in row { bytes.append(contentsOf: [p.b, p.g, p.r, p.x]) }
        }
        return DIB(
            width: Int32(width), height: topDown ? -Int32(height) : Int32(height),
            bitCount: 32, compression: .rgb,
            content: .pixels(bytes: Data(bytes), stride: stride, palette: [])
        )
    }

    static func make8(imageRows: [[UInt8]], palette: [RGBQuad], topDown: Bool) -> DIB {
        let height = imageRows.count
        let width = imageRows.first?.count ?? 0
        let stride = ((width * 8 + 31) / 32) * 4
        let physical = topDown ? imageRows : Array(imageRows.reversed())
        var bytes = [UInt8]()
        for row in physical {
            var rowBytes = row
            while rowBytes.count < stride { rowBytes.append(0) }
            bytes.append(contentsOf: rowBytes)
        }
        return DIB(
            width: Int32(width), height: topDown ? -Int32(height) : Int32(height),
            bitCount: 8, compression: .rgb,
            content: .pixels(bytes: Data(bytes), stride: stride, palette: palette)
        )
    }

    /// The on-disk 24-bit BI_RGB pixel bytes for a solid-red `width × |height|`
    /// bitmap, padded to the parser's stride — used to feed `RenderFixture`.
    static func solidRed24Bits(width: Int, height: Int) -> [UInt8] {
        let stride = ((width * 24 + 31) / 32) * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for row in 0 ..< height {
            var i = row * stride
            for _ in 0 ..< width { bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 255; i += 3 }
        }
        return bytes
    }
}

/// The pure footprint → budget computation (§8: memory bounded against the
/// render target, unit-testable in isolation).
@Suite("DIB decode budget")
struct DIBDecodeBudgetTests {

    @Test("budget ≥ native clamps to native — never upsample the decode")
    func identityClampsToNative() {
        let big = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 1000, height: 1000), nativeW: 8, nativeH: 8)
        #expect(big.w == 8 && big.h == 8)
        // Exactly the native footprint → native.
        let exact = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 8, height: 8), nativeW: 8, nativeH: 8)
        #expect(exact.w == 8 && exact.h == 8)
    }

    @Test("a smaller footprint downscales the budget, ceiling a partial pixel")
    func downscaleCeils() {
        let whole = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 100, height: 50), nativeW: 1000, nativeH: 1000)
        #expect(whole.w == 100 && whole.h == 50)
        // A fractional footprint ceils up — a partial pixel needs a whole source pixel.
        let fractional = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 100.2, height: 50.9), nativeW: 1000, nativeH: 1000)
        #expect(fractional.w == 101 && fractional.h == 51)
    }

    @Test("degenerate footprints clamp to at least 1×1")
    func degenerateClampsToOne() {
        let zero = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 0, height: 0), nativeW: 1000, nativeH: 1000)
        #expect(zero.w == 1 && zero.h == 1)
        // A sub-pixel footprint ceils up to a whole source pixel, never to 0.
        let subPixel = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 0.3, height: 0.3), nativeW: 1000, nativeH: 1000)
        #expect(subPixel.w == 1 && subPixel.h == 1)
    }

    @Test("a negative-size (mirrored) footprint budgets by its absolute extent")
    func negativeSizeUsesAbsoluteExtent() {
        // CGRect reports its ABSOLUTE extent through `.width`/`.height` (and the
        // caller standardizes), so a mirror is sized, never collapsed to 1×1.
        let mirrored = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: -40, height: -30), nativeW: 1000, nativeH: 1000)
        #expect(mirrored.w == 40 && mirrored.h == 30)
    }

    @Test("an absurd but finite footprint clamps to native")
    func absurdFiniteClampsToNative() {
        let budget = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 1e30, height: 1e30), nativeW: 1000, nativeH: 750)
        #expect(budget.w == 1000 && budget.h == 750)
    }

    @Test("the per-side dimension cap bounds an aspect-extreme native")
    func perSideDimensionCap() {
        // Native wider than the 16384 cap but small area: capped per side, no area scale.
        let budget = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 1e9, height: 1e9), nativeW: 20_000, nativeH: 200)
        #expect(budget.w == EMFRenderer.canvasDimensionCap)
        #expect(budget.h == 200)
    }

    @Test("the total-area cap scales both sides down, aspect preserved")
    func areaCap() {
        // Native at the per-side cap on both axes (≈268 Mpx) → area-scaled under 32 Mpx.
        let budget = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 1e9, height: 1e9), nativeW: 16_384, nativeH: 16_384)
        #expect(budget.w == budget.h, "a square native stays square through the area clamp")
        #expect(budget.w * budget.h <= EMFRenderer.canvasAreaCap, "area is within the cap")
        #expect(budget.w <= EMFRenderer.canvasDimensionCap)
        #expect(budget.w > 1, "the scaled side is a meaningful size, not collapsed to 1")
    }

    @Test("a non-finite footprint falls back to the whole native size")
    func nonFiniteFallsBackToNative() {
        let nan = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100), nativeW: 640, nativeH: 480)
        #expect(nan.w == 640 && nan.h == 480)
        let inf = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity), nativeW: 640, nativeH: 480)
        #expect(inf.w == 640 && inf.h == 480)
    }

    @Test("the pathological bound: a 12000×9000 DIB to a 256×192 target budgets to the target")
    func pathologicalBudget() {
        let budget = BitmapDecoder.decodeBudget(destTargetRect: CGRect(x: 0, y: 0, width: 256, height: 192), nativeW: 12_000, nativeH: 9_000)
        #expect(budget.w == 256 && budget.h == 192)
    }
}

/// The budget-aware sampler: nearest-neighbor row/column selection reading the
/// DIB straight out of its bytes at ≤ budget resolution, with the source
/// sub-rect crop folded in.
@Suite("DIB budget sampling")
struct DIBBudgetSamplingTests {

    @Test("whole-image budget ≥ native decodes 1:1 with no downsample flag")
    func fastPathIdentity() throws {
        let dib = DIBSample.make24(imageRows: [
            [(b: 0, g: 0, r: 255), (b: 0, g: 255, r: 0)],
            [(b: 255, g: 0, r: 0), (b: 255, g: 255, r: 255)],
        ], topDown: true)
        let (image, reason, downsampled) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 2, height: 2), budget: (w: 100, h: 100)
        )
        #expect(reason == nil)
        #expect(!downsampled, "budget ≥ native must not downsample")
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels.width == 2 && pixels.height == 2)
        #expect(pixels[0, 0].r > 200 && pixels[0, 0].g < 60, "top-left red")
        #expect(pixels[1, 0].g > 200 && pixels[1, 0].r < 60, "top-right green")
        #expect(pixels[0, 1].b > 200 && pixels[0, 1].r < 60, "bottom-left blue")
        #expect(pixels[1, 1].r > 200 && pixels[1, 1].g > 200 && pixels[1, 1].b > 200, "bottom-right white")
    }

    @Test("24-bit: nearest sampling selects the expected source columns under a reduced width budget")
    func sample24Columns() throws {
        // One row, four columns: red | green | blue | white.
        let dib = DIBSample.make24(imageRows: [[
            (b: 0, g: 0, r: 255), (b: 0, g: 255, r: 0), (b: 255, g: 0, r: 0), (b: 255, g: 255, r: 255),
        ]], topDown: true)
        // Width budget 2: nearest picks source columns 1 (green) and 3 (white).
        let (image, _, downsampled) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 4, height: 1), budget: (w: 2, h: 1)
        )
        #expect(downsampled)
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels.width == 2 && pixels.height == 1)
        #expect(pixels[0, 0].g > 200 && pixels[0, 0].r < 60 && pixels[0, 0].b < 60, "col 0 → source green, got \(pixels[0, 0])")
        #expect(pixels[1, 0].r > 200 && pixels[1, 0].g > 200 && pixels[1, 0].b > 200, "col 1 → source white, got \(pixels[1, 0])")
    }

    @Test("24-bit: nearest sampling selects the expected image rows from either storage order", arguments: [true, false])
    func sample24Rows(topDown: Bool) throws {
        // One column, four image rows (top-down): red, green, blue, white.
        let dib = DIBSample.make24(imageRows: [
            [(b: 0, g: 0, r: 255)], [(b: 0, g: 255, r: 0)], [(b: 255, g: 0, r: 0)], [(b: 255, g: 255, r: 255)],
        ], topDown: topDown)
        // Height budget 2: nearest picks image rows 1 (green) and 3 (white).
        let (image, _, _) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 1, height: 4), budget: (w: 1, h: 2)
        )
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels.height == 2)
        #expect(pixels[0, 0].g > 200 && pixels[0, 0].r < 60, "output row 0 → image row 1 (green), got \(pixels[0, 0])")
        #expect(pixels[0, 1].r > 200 && pixels[0, 1].g > 200 && pixels[0, 1].b > 200, "output row 1 → image row 3 (white), got \(pixels[0, 1])")
    }

    @Test("32-bit: the X byte is ignored and channels stay correct under a reduced budget")
    func sample32() throws {
        // Four columns with nonzero X bytes that must NOT become alpha or colour.
        let dib = DIBSample.make32(imageRows: [[
            (b: 0, g: 0, r: 255, x: 0x7F), (b: 0, g: 255, r: 0, x: 0x33),
            (b: 255, g: 0, r: 0, x: 0x99), (b: 10, g: 10, r: 10, x: 0xFF),
        ]], topDown: true)
        let (image, _, downsampled) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 4, height: 1), budget: (w: 2, h: 1)
        )
        #expect(downsampled)
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels[0, 0].g > 200 && pixels[0, 0].r < 60 && pixels[0, 0].b < 60 && pixels[0, 0].a == 255, "col 0 → green, opaque, got \(pixels[0, 0])")
        #expect(pixels[1, 0].r < 60 && pixels[1, 0].g < 60 && pixels[1, 0].b < 60 && pixels[1, 0].a == 255, "col 1 → dark, opaque (X not alpha), got \(pixels[1, 0])")
    }

    @Test("8-bit: an out-of-range index still clamps to the last palette entry when sampled down")
    func sample8Clamp() throws {
        let palette = [
            RGBQuad(blue: 0, green: 0, red: 255),   // 0 red
            RGBQuad(blue: 0, green: 255, red: 0),   // 1 green
            RGBQuad(blue: 255, green: 0, red: 0),   // 2 blue (last entry)
        ]
        // Four columns of indices; column 3's index 5 is out of range.
        let dib = DIBSample.make8(imageRows: [[0, 1, 2, 5]], palette: palette, topDown: true)
        // Width budget 2: nearest picks columns 1 (index 1) and 3 (index 5 → clamp).
        let (image, _, _) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 4, height: 1), budget: (w: 2, h: 1)
        )
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels[0, 0].g > 200 && pixels[0, 0].r < 60, "col 0 → index 1 green, got \(pixels[0, 0])")
        #expect(pixels[1, 0].b > 200 && pixels[1, 0].r < 60, "col 1 → out-of-range index clamps to last (blue), got \(pixels[1, 0])")
    }

    @Test("stride padding is respected under sampling — no padding bleed")
    func stridePadding() throws {
        // Three 24-bit columns → stride 12 (9 data bytes + 3 pad).
        let dib = DIBSample.make24(imageRows: [[
            (b: 0, g: 0, r: 255), (b: 0, g: 255, r: 0), (b: 255, g: 0, r: 0),
        ]], topDown: true)
        if case .pixels(_, let stride, _) = dib.content { #expect(stride == 12, "3×24-bit stride is padded to 12") }
        // Width budget 2: nearest picks source columns 0 (red) and 2 (blue).
        let (image, _, _) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: 3, height: 1), budget: (w: 2, h: 1)
        )
        let cg = try #require(image)
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels[0, 0].r > 200 && pixels[0, 0].b < 60, "col 0 → source red, got \(pixels[0, 0])")
        #expect(pixels[1, 0].b > 200 && pixels[1, 0].r < 60, "col 1 → source blue, got \(pixels[1, 0])")
    }

    @Test("the pathological bound: a large DIB decodes to the budgeted size, not the native size")
    func pathologicalDecodeCompletes() throws {
        // 1200×900 native (≈1.08 Mpx), solid red, budgeted to 120×90.
        let width = 1200, height = 900
        let stride = ((width * 24 + 31) / 32) * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for row in 0 ..< height {
            var i = row * stride
            for _ in 0 ..< width { bytes[i + 2] = 255; i += 3 }
        }
        let dib = DIB(
            width: Int32(width), height: Int32(-height), bitCount: 24, compression: .rgb,
            content: .pixels(bytes: Data(bytes), stride: stride, palette: [])
        )
        let (image, reason, downsampled) = BitmapDecoder.decode(
            dib, srcRect: BitmapDecoder.SourceRect(x: 0, y: 0, width: width, height: height), budget: (w: 120, h: 90)
        )
        #expect(reason == nil)
        #expect(downsampled)
        let cg = try #require(image)
        #expect(cg.width == 120 && cg.height == 90, "decoded to the budgeted size, not the 1200×900 native")
        let pixels = try #require(RasterizedImage(cg))
        #expect(pixels[60, 45].r > 200 && pixels[60, 45].g < 60 && pixels[60, 45].b < 60, "sampled pixel is red, got \(pixels[60, 45])")
    }
}

/// The `dibDownsampled` log family: a below-native decode is recorded (coalesced)
/// so playback honesty is preserved, and no entry appears when the target can
/// show full resolution.
@Suite("DIB downsample log")
struct DIBDownsampleLogTests {

    @Test("a DIB drawn smaller than native logs one coalesced downsample entry")
    func belowNativeLogsDownsample() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)   // canvas 100×100, ~1:1 mapping.
        // 8×8 native (64 px) red DIB into a 2×2 dest → footprint 2×2 < native.
        fixture.stretchDIBits(
            bounds: (0, 0, 8, 8), dest: (x: 5, y: 5), destSize: (cx: 2, cy: 2), srcSize: (cx: 8, cy: 8),
            bmi: RenderFixture.bitmapInfoHeader(width: 8, height: 8, bitCount: 24),
            bits: DIBSample.solidRed24Bits(width: 8, height: 8)
        )
        let file = try fixture.parsed()
        let (_, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .dibDownsampled(count: 1, worstNativePixels: 64, worstDecodedPixels: 4),
            .unimplementedRecord(type: 14, count: 1),
        ], "unexpected log: \(log.entries)")
    }

    @Test("two below-native DIBs coalesce into one entry keeping the worst reduction")
    func twoDownsamplesCoalesce() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // 8×8 (64 px) → 2×2, then 16×16 (256 px) → 2×2. Worst native = 256.
        fixture.stretchDIBits(
            bounds: (0, 0, 8, 8), dest: (x: 5, y: 5), destSize: (cx: 2, cy: 2), srcSize: (cx: 8, cy: 8),
            bmi: RenderFixture.bitmapInfoHeader(width: 8, height: 8, bitCount: 24),
            bits: DIBSample.solidRed24Bits(width: 8, height: 8)
        )
        fixture.stretchDIBits(
            bounds: (0, 0, 16, 16), dest: (x: 30, y: 30), destSize: (cx: 2, cy: 2), srcSize: (cx: 16, cy: 16),
            bmi: RenderFixture.bitmapInfoHeader(width: 16, height: 16, bitCount: 24),
            bits: DIBSample.solidRed24Bits(width: 16, height: 16)
        )
        let file = try fixture.parsed()
        let (_, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .dibDownsampled(count: 2, worstNativePixels: 256, worstDecodedPixels: 4),
            .unimplementedRecord(type: 14, count: 1),
        ], "unexpected log: \(log.entries)")
    }

    @Test("a DIB drawn at native size logs no downsample")
    func atNativeNoDownsample() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        // 4×4 native drawn 1:1 → footprint ≥ native → fast path, no log.
        fixture.stretchDIBits(
            bounds: (0, 0, 4, 4), dest: (x: 5, y: 5), destSize: (cx: 4, cy: 4), srcSize: (cx: 4, cy: 4),
            bmi: RenderFixture.bitmapInfoHeader(width: 4, height: 4, bitCount: 24),
            bits: DIBSample.solidRed24Bits(width: 4, height: 4)
        )
        let file = try fixture.parsed()
        let (_, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)], "no downsample at native, got: \(log.entries)")
    }

    @Test("downsample coalescing survives makeImage's clamp re-feed")
    func downsampleCoalescesThroughClamp() throws {
        var fixture = RenderFixture()
        // A hostile canvas forces a leading canvasClamped entry, exercising the
        // re-feed path that could otherwise split the downsample count.
        fixture.bounds = (left: 0, top: 0, right: 999_999_999, bottom: 99)
        for origin in [(x: Int32(5), y: Int32(5)), (x: Int32(30), y: Int32(30))] {
            fixture.stretchDIBits(
                bounds: (0, 0, 8, 8), dest: origin, destSize: (cx: 2, cy: 2), srcSize: (cx: 8, cy: 8),
                bmi: RenderFixture.bitmapInfoHeader(width: 8, height: 8, bitCount: 24),
                bits: DIBSample.solidRed24Bits(width: 8, height: 8)
            )
        }
        let file = try fixture.parsed()
        let (_, log) = try #require(EMFRenderer.makeImage(file))
        let counts = log.entries.compactMap { entry -> Int? in
            if case .dibDownsampled(let c, _, _) = entry { return c } else { return nil }
        }
        #expect(counts == [2], "downsample must coalesce to a single count-2 entry despite the clamp, got: \(log.entries)")
    }
}
