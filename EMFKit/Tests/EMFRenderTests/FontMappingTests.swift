import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// LOGFONT → CTFont resolution and text-rendering semantics (primer §6 phase 4).
@Suite("Font mapping and text rendering")
struct FontMappingTests {

    private static func logFont(
        height: Int32 = -32,
        weight: Int32 = 400,
        escapement: Int32 = 0,
        italic: UInt8 = 0,
        underline: UInt8 = 0,
        strikeOut: UInt8 = 0,
        faceName: String
    ) -> LogFont {
        LogFont(
            height: height, width: 0, escapement: escapement, orientation: 0,
            weight: weight, italic: italic, underline: underline, strikeOut: strikeOut,
            charSet: 0, outPrecision: 0, clipPrecision: 0, quality: 0,
            pitchAndFamily: 0, faceName: faceName
        )
    }

    private static func resolve(_ font: LogFont) -> (ResolvedFont, EMFRenderLog) {
        var log = EMFRenderLog()
        let resolved = FontMapper.resolve(font, log: &log)
        return (resolved, log)
    }

    private static func family(_ font: CTFont) -> String {
        (CTFontCopyFamilyName(font) as String).lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - Direct resolve vs substitution

    @Test("a font that resolves directly is used as-is, no substitution log")
    func directResolve() {
        // Arial and Times New Roman ship with macOS and resolve directly.
        for face in ["Arial", "Times New Roman"] {
            let (resolved, log) = Self.resolve(Self.logFont(faceName: face))
            #expect(Self.family(resolved.base) == face.lowercased().filter { !$0.isWhitespace })
            #expect(log.isClean, "unexpected substitution for \(face): \(log.entries)")
        }
    }

    @Test("a missing family substitutes and logs once (coalesced by family)")
    func substitutionLogged() {
        // A face that certainly does not exist forces the default fallback.
        var log = EMFRenderLog()
        _ = FontMapper.resolve(Self.logFont(faceName: "NoSuchFace_ZZZ"), log: &log)
        _ = FontMapper.resolve(Self.logFont(faceName: "NoSuchFace_ZZZ"), log: &log)
        // Coalesced by requested family: one entry, count 2.
        #expect(log.entries == [
            .fontSubstituted(requested: "NoSuchFace_ZZZ", used: FontMapper.defaultFamily, count: 2),
        ])
    }

    @Test("substitution table maps known Windows families")
    func substitutionTable() {
        // These may or may not exist depending on installed fonts; assert the
        // substitution TARGET only when CoreText actually misses the request.
        func substituteTarget(_ face: String) -> String? {
            var log = EMFRenderLog()
            _ = FontMapper.resolve(Self.logFont(faceName: face), log: &log)
            if case .fontSubstituted(_, let used, _) = log.entries.first {
                return used
            }
            return nil   // resolved directly on this machine
        }
        // MS Sans Serif → Helvetica when missing.
        if let used = substituteTarget("MS Sans Serif") {
            #expect(used == "Helvetica")
        }
        // A CJK family, when missing, falls to the default (CTLine cascades).
        if let used = substituteTarget("SimSun") {
            #expect(used == FontMapper.defaultFamily)
        }
    }

    // MARK: - Traits

    @Test("bold trait applied for weight >= 600")
    func boldTrait() {
        let (resolved, _) = Self.resolve(Self.logFont(weight: 700, faceName: "Arial"))
        let traits = CTFontGetSymbolicTraits(resolved.base)
        #expect(traits.contains(.traitBold))
    }

    @Test("italic trait applied for lfItalic != 0")
    func italicTrait() {
        let (resolved, _) = Self.resolve(Self.logFont(italic: 1, faceName: "Times New Roman"))
        let traits = CTFontGetSymbolicTraits(resolved.base)
        #expect(traits.contains(.traitItalic))
    }

    @Test("weight < 600 and lfItalic 0 apply no bold/italic")
    func regularTraits() {
        let (resolved, _) = Self.resolve(Self.logFont(weight: 400, italic: 0, faceName: "Arial"))
        let traits = CTFontGetSymbolicTraits(resolved.base)
        #expect(!traits.contains(.traitBold))
        #expect(!traits.contains(.traitItalic))
    }

    // MARK: - Height sign convention ([MS-EMF] §2.2.13)

    @Test("negative lfHeight is em height; positive is cell height (0.9×); 0 is default")
    func heightSignConvention() {
        let identity = CGAffineTransform.identity
        // Negative → point size = |height|.
        #expect(FontMapper.devicePointSize(logicalHeight: -40, logicalToTarget: identity) == 40)
        // Positive → em ≈ 0.9 × cell height.
        #expect(abs(FontMapper.devicePointSize(logicalHeight: 40, logicalToTarget: identity) - 36) < 0.01)
        // Zero → the 12pt default.
        #expect(FontMapper.devicePointSize(logicalHeight: 0, logicalToTarget: identity) == FontMapper.defaultHeight)
    }

    @Test("lfHeight scales by the transform's average scale")
    func heightScales() {
        // A 2× uniform scale doubles the point size.
        let doubled = CGAffineTransform(scaleX: 2, y: 2)
        #expect(FontMapper.devicePointSize(logicalHeight: -30, logicalToTarget: doubled) == 60)
    }

    @Test("an absurd lfHeight is clamped to the ceiling; normal sizes untouched (§8, R3)")
    func hostileHeightClamped() {
        let identity = CGAffineTransform.identity
        // A single hostile EMR_EXTCREATEFONTINDIRECTW: enormous em (negative)
        // and cell (positive) heights both clamp to the ceiling — never handed
        // to CoreText as a ~2e9-point outline-flattening request.
        #expect(FontMapper.devicePointSize(logicalHeight: -2_000_000_000, logicalToTarget: identity)
            == FontMapper.maxDevicePointSize)
        #expect(FontMapper.devicePointSize(logicalHeight: 2_000_000_000, logicalToTarget: identity)
            == FontMapper.maxDevicePointSize)
        // A normal height is well below the ceiling and passes through unchanged.
        #expect(FontMapper.devicePointSize(logicalHeight: -28, logicalToTarget: identity) == 28)
    }

    // MARK: - Text orientation (the y-flip trap)

    /// Renders a single left/baseline "L" at a known reference and returns the
    /// rasterised image. "L" has a distinctive vertical mass distribution: the
    /// bottom serif/foot is heavier than the top, so upright text has MORE dark
    /// ink in its lower half than its upper half.
    private static func renderL() throws -> RasterizedImage {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)                      // TA_LEFT | TA_BASELINE
        fixture.extCreateFontIndirectW(index: 1, height: -48, faceName: "Arial")
        fixture.selectObject(1)
        fixture.extTextOutW(reference: (x: 20, y: 60), string: "L")
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        return try #require(RasterizedImage(image))
    }

    @Test("text is upright, not mirrored or upside-down")
    func textOrientation() throws {
        let pixels = try Self.renderL()
        // Baseline at device y=60; the glyph spans ~x[23..45] y[25..59] (measured).
        // "L": the vertical stem runs the full height on the LEFT (x≈23..26);
        // the foot extends RIGHT only at the BOTTOM. Probe the bottom-right vs
        // top-right of the glyph box, clear of the stem (x≥30): upright "L" has
        // ink bottom-right (the foot), none top-right.
        let footBottomRight = pixels.containsDarkPixel(in: (x: 30, y: 54, width: 12, height: 6))
        let topRight = pixels.containsDarkPixel(in: (x: 30, y: 26, width: 12, height: 6))
        #expect(footBottomRight, "no ink where an upright L's foot should be (bottom-right)")
        #expect(!topRight, "ink where an upside-down L's foot would be (top-right) — text is flipped")
    }

    // MARK: - Alignment

    /// The device x where dark ink first appears on the baseline row band, for a
    /// run drawn with the given horizontal alignment at reference x=100.
    private static func inkLeftEdge(align: UInt32) throws -> Int {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 199, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(align)
        fixture.extCreateFontIndirectW(index: 1, height: -24, faceName: "Arial")
        fixture.selectObject(1)
        fixture.extTextOutW(reference: (x: 100, y: 50), string: "MMM")
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        for x in 0 ..< pixels.width where pixels.containsDarkPixel(in: (x: x, y: 30, width: 1, height: 20)) {
            return x
        }
        return -1
    }

    @Test("horizontal alignment moves the run's ink relative to the reference")
    func horizontalAlignment() throws {
        // Use TA_BASELINE (24) so the run's ink sits ABOVE the reference y in the
        // scanned band. Horizontal codes: TA_LEFT=0, TA_RIGHT=2, TA_CENTER=6.
        let left = try Self.inkLeftEdge(align: 24)         // left + baseline
        let right = try Self.inkLeftEdge(align: 24 | 2)    // right + baseline
        let center = try Self.inkLeftEdge(align: 24 | 6)   // center + baseline

        // TA_LEFT: ink starts AT the reference (x≈100).
        #expect(left >= 90 && left <= 110, "left-aligned ink should start near x=100, got \(left)")
        // TA_RIGHT: the run ends at the reference, so ink starts well LEFT of it.
        #expect(right < left - 10, "right-aligned ink should start well left of left-aligned, got \(right) vs \(left)")
        // TA_CENTER: ink starts between right and left.
        #expect(center < left - 5 && center > right + 5, "center between right(\(right)) and left(\(left)), got \(center)")
    }

    // MARK: - Dx spacing

    @Test("Dx array positions glyphs with an explicit wide gap")
    func dxSpacing() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 199, 49)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)
        fixture.extCreateFontIndirectW(index: 1, height: -20, faceName: "Arial")
        fixture.selectObject(1)
        // Two glyphs; the first advance is a wide 120-unit gap so the 2nd glyph
        // lands far to the right (near x=150), leaving a blank band in between.
        fixture.extTextOutW(reference: (x: 10, y: 30), string: "II", dx: [120, 20])
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))

        // First glyph near x=10.
        #expect(pixels.containsDarkPixel(in: (x: 8, y: 12, width: 10, height: 16)))
        // A blank band in the middle (x ~60..110) — the wide Dx gap.
        #expect(!pixels.containsDarkPixel(in: (x: 60, y: 12, width: 40, height: 16)))
        // Second glyph near x=130 (10 + 120).
        #expect(pixels.containsDarkPixel(in: (x: 122, y: 12, width: 16, height: 16)))
    }

    // MARK: - TA_UPDATECP

    @Test("TA_UPDATECP advances the current position so consecutive runs abut")
    func updateCP() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 299, 49)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        // TA_UPDATECP (1) | TA_BASELINE (24) = 25.
        fixture.setTextAlign(25)
        fixture.extCreateFontIndirectW(index: 1, height: -24, faceName: "Arial")
        fixture.selectObject(1)
        fixture.moveToEx(10, 30)
        // Two consecutive runs; with UPDATECP the second continues where the
        // first ended (no reference point is used).
        fixture.extTextOutW(reference: (x: 0, y: 0), string: "AAAA", dx: [16, 16, 16, 16])
        fixture.extTextOutW(reference: (x: 0, y: 0), string: "BBBB", dx: [16, 16, 16, 16])
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))

        // The first run occupies x≈10..74 (10 + 4×16). The second must land
        // right after — ink continuous across x=74..138, none far right of that.
        #expect(pixels.containsDarkPixel(in: (x: 78, y: 12, width: 40, height: 18)), "second run did not continue from the advanced position")
        // And ink must begin at the first run's start (x≈10), proving the first
        // run drew at the current position, not at reference (0,0).
        #expect(pixels.containsDarkPixel(in: (x: 8, y: 12, width: 12, height: 18)))
        #expect(!pixels.containsDarkPixel(in: (x: 0, y: 12, width: 4, height: 18)), "ink at x=0 means a run drew at reference (0,0) instead of the current position")
    }

    @Test("TA_UPDATECP advance does not trap or wrap on a hostile font size (§8)")
    func updateCPHostileAdvance() throws {
        // A gigantic font under TA_UPDATECP would make the typographic advance
        // exceed Int32 range: the old `Int32(advance.rounded())` trapped and the
        // `&+` wrapped. This must render (skipping past the canvas) without
        // crashing — makeImage returning any image proves no trap fired.
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(25)                       // TA_UPDATECP | TA_BASELINE
        // Character height near Int32.min → an astronomically wide advance.
        fixture.extCreateFontIndirectW(index: 1, height: Int32.min + 1, faceName: "Arial")
        fixture.selectObject(1)
        fixture.moveToEx(0, 50)
        fixture.extTextOutW(reference: (x: 0, y: 0), string: "WWWW")
        fixture.extTextOutW(reference: (x: 0, y: 0), string: "WWWW")
        let file = try fixture.parsed()
        // The assertion is simply that this returns without a crash.
        _ = try #require(EMFRenderer.makeImage(file))
    }

    // MARK: - ETO_OPAQUE background

    @Test("ETO_OPAQUE fills the rectangle with the background colour")
    func opaqueBackground() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setBkColor(r: 0, g: 0, b: 255)        // blue background
        fixture.setTextAlign(24)
        fixture.extCreateFontIndirectW(index: 1, height: -20, faceName: "Arial")
        fixture.selectObject(1)
        // ETO_OPAQUE (0x0002) with a rectangle 10,10..70,70.
        fixture.extTextOutW(
            reference: (x: 15, y: 50), string: "x",
            options: 0x0002, rectangle: (10, 10, 70, 70)
        )
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))

        // A corner of the rect well away from the glyph is blue.
        #expect(pixels.containsBluePixel(in: (x: 55, y: 15, width: 10, height: 10)))
        // Outside the rect stays white.
        let outside = pixels[85, 85]
        #expect(outside.r > 200 && outside.g > 200 && outside.b > 200)
    }

    // MARK: - Underline / strike-out

    @Test("underline draws below the baseline")
    func underline() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)
        fixture.extCreateFontIndirectW(index: 1, height: -40, underline: 1, faceName: "Arial")
        fixture.selectObject(1)
        // A period at baseline y=50 has almost no ink except at the baseline; an
        // underline still runs the full width just below it.
        fixture.extTextOutW(reference: (x: 20, y: 50), string: "...")
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        // Ink just below the baseline (y 51..58) across the run width.
        #expect(pixels.containsDarkPixel(in: (x: 22, y: 51, width: 30, height: 8)), "no underline below the baseline")
    }

    @Test("strike-out draws a line through the run above the baseline")
    func strikeOut() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)
        fixture.extCreateFontIndirectW(index: 1, height: -40, strikeOut: 1, faceName: "Arial")
        fixture.selectObject(1)
        // Periods: nearly no glyph ink above the baseline, but the strike-out
        // runs the full width around half the x-height above the baseline.
        fixture.extTextOutW(reference: (x: 20, y: 60), string: "...")
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))
        // Ink above the baseline (y 45..56), across the run — the strike line.
        #expect(pixels.containsDarkPixel(in: (x: 22, y: 45, width: 30, height: 11)), "no strike-through above the baseline")
    }

    // MARK: - Escapement rotation

    @Test("escapement 900 (90° CCW) rotates the baseline upward")
    func escapement90() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)
        // Escapement 900 tenths = 90° counterclockwise: the run advances UP the
        // screen instead of rightward.
        fixture.extCreateFontIndirectW(index: 1, height: -20, escapement: 900, faceName: "Arial")
        fixture.selectObject(1)
        fixture.extTextOutW(reference: (x: 50, y: 80), string: "MMMM", dx: [16, 16, 16, 16])
        let file = try fixture.parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file))
        let pixels = try #require(RasterizedImage(image))

        // Ink runs UPWARD from the reference (measured x[35..49] y[16..78]), NOT
        // rightward. Probe well ABOVE the reference near the reference x.
        #expect(pixels.containsDarkPixel(in: (x: 34, y: 16, width: 16, height: 20)), "run did not advance upward for 90° CCW escapement")
        // And no ink far to the RIGHT of the reference (would mean it advanced
        // rightward, i.e. no rotation).
        #expect(!pixels.containsDarkPixel(in: (x: 70, y: 70, width: 29, height: 16)), "ink to the right means the baseline was not rotated")
    }

    // MARK: - Glyph index skip

    @Test("ETO_GLYPH_INDEX run is skipped with a coalesced log")
    func glyphIndexSkipped() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 99, 99)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.setTextAlign(24)
        fixture.extCreateFontIndirectW(index: 1, height: -40, faceName: "Arial")
        fixture.selectObject(1)
        // ETO_GLYPH_INDEX (0x0010): glyph ids, not characters — skip the run.
        fixture.extTextOutW(reference: (x: 10, y: 50), string: "AB", options: 0x0010)
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .glyphIndexTextSkipped(count: 1),
            .unimplementedRecord(type: 14, count: 1),
        ])
        // Nothing drawn.
        let pixels = try #require(RasterizedImage(image))
        #expect(!pixels.containsDarkPixel(in: (x: 0, y: 0, width: 99, height: 99)))
    }

    // MARK: - DC state integration

    @Test("SELECTOBJECT of a font resolves it into the DC; DELETEOBJECT keeps the copy")
    func fontSelectionState() throws {
        var dc = makeTextDC()
        var log = EMFRenderLog()

        _ = dc.apply(.extCreateFontIndirectW(ExtCreateFontPayload(
            ihFonts: 1,
            logFont: Self.logFont(height: -30, faceName: "Arial"),
            hasExtendedData: false
        )), log: &log)
        #expect(dc.objects[1] != nil)

        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        #expect(dc.state.font != nil)
        #expect(dc.state.font?.logicalHeight == -30)

        // Deleting the table slot leaves the DC's resolved copy intact.
        _ = dc.apply(.deleteObject(.table(index: 1)), log: &log)
        #expect(dc.state.font?.logicalHeight == -30)
        #expect(dc.objects.isEmpty)
        #expect(log.isClean)
    }

    @Test("stock FONT selection resolves to a system font and logs (coalesced)")
    func stockFontSelection() {
        var dc = makeTextDC()
        var log = EMFRenderLog()
        // SYSTEM_FONT = 0x8000000D.
        _ = dc.apply(.selectObject(.stock(.systemFont)), log: &log)
        #expect(dc.state.font != nil)
        _ = dc.apply(.selectObject(.stock(.systemFont)), log: &log)
        #expect(log.entries == [.stockFontUsed(rawValue: 0x8000_000D, count: 2)])
    }

    @Test("SETTEXTCOLOR / SETBKCOLOR / SETTEXTALIGN update DC state")
    func textStateRecords() {
        var dc = makeTextDC()
        var log = EMFRenderLog()

        _ = dc.apply(.setTextColor(ColorRef(red: 1, green: 2, blue: 3)), log: &log)
        _ = dc.apply(.setBkColor(ColorRef(red: 4, green: 5, blue: 6)), log: &log)
        _ = dc.apply(.setTextAlign(TextAlign(rawValue: 6)), log: &log)

        #expect(dc.state.textColor == ColorRef(red: 1, green: 2, blue: 3))
        #expect(dc.state.bkColor == ColorRef(red: 4, green: 5, blue: 6))
        #expect(dc.state.textAlign.horizontal == .center)
        #expect(log.isClean)
    }
}
