import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

@Suite("Rendered drawing semantics")
struct DrawingTests {

    /// A self-intersecting pentagram on the fixture's 100×100 canvas
    /// (MM_TEXT: logical == device == image pixels). Its centre has winding
    /// number 2: filled under WINDING, a hole under ALTERNATE.
    private static let pentagram: [(Int16, Int16)] = [
        (50, 10), (74, 85), (11, 38), (89, 38), (26, 85),
    ]

    private static func renderPentagram(fillModeRaw: UInt32) throws -> RasterizedImage {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN: no outline
        fixture.setPolyFillMode(fillModeRaw)
        fixture.polygon16(Self.pentagram)

        let file = try fixture.parsed()
        let rendered = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
        // The only log entry is the benign EOF terminator skip.
        #expect(rendered.1.entries == [.unimplementedRecord(type: 14, count: 1)])
        return try #require(RasterizedImage(rendered.0))
    }

    @Test("ALTERNATE vs WINDING fill differ at a pentagram's centre")
    func polyfillRules() throws {
        let alternate = try Self.renderPentagram(fillModeRaw: 0x01)
        let winding = try Self.renderPentagram(fillModeRaw: 0x02)

        // Centre pixel: winding 2 → ALTERNATE (even-odd) leaves the white
        // background; WINDING fills black.
        let alternateCentre = alternate[50, 50]
        let windingCentre = winding[50, 50]
        #expect(alternateCentre.r == 255 && alternateCentre.g == 255 && alternateCentre.b == 255)
        #expect(windingCentre.r == 0 && windingCentre.g == 0 && windingCentre.b == 0)

        // A point inside the top tip has winding 1: black under BOTH rules.
        #expect(alternate[50, 30].r == 0)
        #expect(winding[50, 30].r == 0)
    }

    // MARK: - Bezier count validation

    @Test("bezier shape validation", arguments: [
        // (count, continuesFrom, usable, malformed)
        (0, false, 0, true),     // plain with no start point
        (1, false, 1, false),    // start only: degenerate but well-formed
        (4, false, 4, false),    // start + one triple
        (5, false, 4, true),     // one stray point dropped
        (6, false, 4, true),     // two stray points dropped
        (7, false, 7, false),    // start + two triples
        (0, true, 0, false),     // …To with nothing: a no-op, not malformed
        (2, true, 0, true),      // …To with a partial triple
        (3, true, 3, false),
        (5, true, 3, true),
    ])
    func bezierShapeValidation(testCase: (Int, Bool, Int, Bool)) {
        let (count, continues, usable, malformed) = testCase
        let shape = PathBuilder.bezierShape(
            pointCount: count,
            continuesFromCurrentPosition: continues
        )
        #expect(shape.usableCount == usable)
        #expect(shape.isMalformed == malformed)
    }

    @Test("malformed polyBezier16 renders the well-formed prefix and logs")
    func bezierPrefixRenders() throws {
        var fixture = RenderFixture()
        // Default DC pen is BLACK_PEN (cosmetic). 5 points = start + one
        // triple + 1 stray: the cubic (10,50)→(90,50) with both controls at
        // y=10 passes exactly through (50,20) at t=0.5.
        fixture.polyBezier16([(10, 50), (30, 10), (70, 10), (90, 50), (95, 95)])

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .malformedBezier(pointCount: 5),
            .unimplementedRecord(type: 14, count: 1),   // EOF terminator
        ])

        let pixels = try #require(RasterizedImage(image))
        // Ink from the curve near its midpoint …
        #expect(pixels.containsDarkPixel(in: (x: 46, y: 16, width: 9, height: 9)))
        // … and none where the dropped 5th point would have led (the stray
        // suffix toward (95,95) must NOT be drawn).
        #expect(!pixels.containsDarkPixel(in: (x: 88, y: 88, width: 12, height: 12)))
    }

    @Test("malformed polyBezierTo16 renders prefix and advances the position")
    func bezierToPrefixRenders() throws {
        var fixture = RenderFixture()
        fixture.moveToEx(10, 90)
        // 4 points: one whole triple (ending at (90,90)) + 1 stray.
        fixture.polyBezierTo16([(10, 10), (90, 10), (90, 90), (5, 5)])
        // lineTo draws from the CURRENT POSITION: if the position advanced to
        // the prefix end (90,90), this strokes the bottom edge y=90.
        fixture.lineTo(10, 90)

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .malformedBezier(pointCount: 4),
            .unimplementedRecord(type: 14, count: 1),   // EOF terminator
        ])

        let pixels = try #require(RasterizedImage(image))
        // The bottom edge line exists (current position was advanced) …
        #expect(pixels.containsDarkPixel(in: (x: 45, y: 87, width: 10, height: 6)))
        // … and nothing was drawn toward the stray (5,5).
        #expect(!pixels.containsDarkPixel(in: (x: 0, y: 0, width: 12, height: 12)))
    }

    // MARK: - ROP2 (D5: best partial output)

    @Test("a non-copy ROP2 mode logs but the shape still renders as copy")
    func rop2StillRenders() throws {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
        fixture.setROP2(0x06)                 // R2_XORPEN — unsupported
        fixture.polygon16([(20, 20), (80, 20), (80, 80), (20, 80)])

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries == [
            .unsupportedROP2(rawMode: 0x06, count: 1),
            .unimplementedRecord(type: 14, count: 1),
        ])

        // The square is still filled — drawn as if R2_COPYPEN.
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels[50, 50] == (0, 0, 0, 255))
    }

    // MARK: - Dash application (pixel-level, guards setLineDash)

    /// A geometric PS_USERSTYLE pen strokes a long horizontal line under a 2×
    /// world transform; the wide user pattern leaves a probeable ink run and a
    /// probeable gap. This asserts the RENDERER APPLIES the dash (calls
    /// setLineDash) — a dash→solid regression turns the gap pixel red and fails
    /// here. PenMappingTests only checks the mapped dash ARRAY; the snapshot's
    /// 1% tolerance could absorb a solid-line regression. This closes that gap.
    @Test("a dashed geometric pen leaves background in its gaps and ink on its dashes")
    func dashedPenLeavesGaps() throws {
        var fixture = RenderFixture()
        // PS_GEOMETRIC | PS_USERSTYLE | PS_ENDCAP_FLAT: butt caps so a dash end
        // does not bleed round-cap ink into the following gap.
        let style: UInt32 = 0x0001_0000 | 0x07 | 0x200
        // Logical dash pattern [30, 30]; the 2× transform scales it to target
        // units [60, 60], and width 4 → 8 target units.
        fixture.extCreatePen(index: 1, style: style, width: 4, r: 255, g: 0, b: 0, styleEntries: [30, 30])
        fixture.selectObject(1)
        fixture.setWorldTransform(2, 0, 0, 2, 0, 0)   // logical → device 2×
        // Logical (1,25)→(49,25) → device (2,50)→(98,50), length 96 target.
        // Dash phase 0: ink along path length [0,60) → device x [2,62); gap
        // [60,96] → device x [62,98].
        fixture.moveToEx(1, 25)
        fixture.lineTo(49, 25)

        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])

        // INK: device x≈30 is well inside the first dash [2,62); the pen is red.
        let ink = image[30, 50]
        #expect(ink.r > 200 && ink.g < 60 && ink.b < 60, "on a dash: expected red ink, got \(ink)")
        // GAP: device x≈80 is well inside the gap [62,98); background stays white.
        let gap = image[80, 50]
        #expect(gap.r > 220 && gap.g > 220 && gap.b > 220, "in a dash gap: expected white background, got \(gap)")
    }

    private static func render(_ fixture: RenderFixture) throws -> (RasterizedImage, EMFRenderLog) {
        let file = try fixture.parsed()
        let rendered = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
        return (try #require(RasterizedImage(rendered.0)), rendered.1)
    }

    // MARK: - Implemented-record render probes (ROUNDRECT / ARC / POLYPOLYGON16)

    @Test("ROUNDRECT fills its interior and rounds its corners away")
    func roundRectRenders() throws {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
        // Box (10,10)-(90,90) with a large 40×40 corner ellipse: the extreme
        // corner pixel is cut away, the centre is filled.
        fixture.roundRect(10, 10, 90, 90, cornerW: 40, cornerH: 40)

        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        #expect(Self.isBlack(image[50, 50]), "interior filled")
        #expect(Self.isWhite(image[12, 12]), "rounded corner cut away")
        #expect(Self.isWhite(image[5, 50]), "outside the box")
    }

    @Test("ARC strokes an outline without filling its interior")
    func arcRenders() throws {
        var fixture = RenderFixture()
        // Default DC pen is BLACK_PEN (cosmetic). Coincident start/end radials
        // draw the FULL ellipse inscribed in (20,20)-(80,80).
        fixture.arc(box: (20, 20, 80, 80), start: (80, 50), end: (80, 50))

        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        // Ink lands on the ellipse outline (its left edge near device (20,50)).
        #expect(image.containsDarkPixel(in: (x: 17, y: 45, width: 8, height: 10)),
                "expected arc outline ink near the ellipse's left edge")
        // ARC is stroke-only: the centre stays background.
        #expect(Self.isWhite(image[50, 50]), "arc must not fill its interior")
    }

    @Test("POLYPOLYGON16 fills each sub-polygon, leaving the gap between them")
    func polyPolygon16Renders() throws {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
        // Two disjoint squares: left 10..30, right 70..90 (both y 40..60).
        fixture.polyPolygon16([
            [(10, 40), (30, 40), (30, 60), (10, 60)],
            [(70, 40), (90, 40), (90, 60), (70, 60)],
        ])

        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        #expect(Self.isBlack(image[20, 50]), "first sub-polygon filled")
        #expect(Self.isBlack(image[80, 50]), "second sub-polygon filled")
        #expect(Self.isWhite(image[50, 50]), "the gap between the two polygons stays background")
    }

    private static func isBlack(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r < 40 && p.g < 40 && p.b < 40
    }
    private static func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 220 && p.g > 220 && p.b > 220
    }

    // MARK: - 32-bit poly render variants (POLYLINE 4 / POLYLINETO 6 / POLYBEZIER 2)

    @Test("32-bit POLYLINE strokes its segments")
    func polyline32Renders() throws {
        var fixture = RenderFixture()   // default BLACK_PEN
        fixture.polyline([(10, 20), (90, 20)])   // horizontal segment at y=20
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        #expect(image.containsDarkPixel(in: (x: 45, y: 17, width: 10, height: 6)), "POLYLINE ink missing")
    }

    @Test("32-bit POLYLINETO strokes from the current position")
    func polylineTo32Renders() throws {
        var fixture = RenderFixture()
        fixture.moveToEx(10, 80)
        fixture.polylineTo([(90, 80)])           // continues to a horizontal at y=80
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        #expect(image.containsDarkPixel(in: (x: 45, y: 77, width: 10, height: 6)), "POLYLINETO ink missing")
    }

    @Test("32-bit POLYBEZIER strokes the cubic through its midpoint")
    func polyBezier32Renders() throws {
        var fixture = RenderFixture()
        // start + one triple: the cubic (10,50)→(90,50) with both controls at
        // y=10 passes through (50,20) at t=0.5 (mirrors bezierPrefixRenders).
        fixture.polyBezier([(10, 50), (30, 10), (70, 10), (90, 50)])
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])
        #expect(image.containsDarkPixel(in: (x: 46, y: 16, width: 9, height: 9)), "POLYBEZIER ink missing")
    }

    // MARK: - Hostile canvas

    @Test("hostile header bounds clamp the makeImage canvas per side and log")
    func canvasClamp() throws {
        var fixture = RenderFixture()
        fixture.bounds = (left: 0, top: 0, right: 999_999_999, bottom: 499)

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))

        // Width clamps to the per-side cap; the resulting 16384×500 = 8.19 Mpx
        // is under the 32-Mpx area cap, so the height is untouched.
        #expect(image.width == 16_384)
        #expect(image.height == 500)
        #expect(image.width * image.height <= EMFRenderer.canvasAreaCap)
        #expect(log.entries.first == .canvasClamped(
            requestedWidth: 1_000_000_000,
            requestedHeight: 500,
            renderedWidth: 16_384,
            renderedHeight: 500
        ))
    }

    @Test("a within-per-side-cap but huge-area canvas clamps by area, aspect kept")
    func canvasAreaClamp() throws {
        var fixture = RenderFixture()
        // 16000×16000 = 256 Mpx: each side is under the 16384 per-side cap, so
        // ONLY the area cap bites. Aspect ratio (1:1) must be preserved.
        fixture.bounds = (left: 0, top: 0, right: 15_999, bottom: 15_999)

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))

        // sqrt(32_000_000 / 256_000_000) = 0.353553…; 16000 × that, floored,
        // is 5656 on each side (5656² = 31_990_336 ≤ 32 Mpx).
        #expect(image.width == 5_656)
        #expect(image.height == 5_656)
        #expect(image.width * image.height <= EMFRenderer.canvasAreaCap)
        // Square in, square out: the aspect ratio survived the area scale.
        #expect(image.width == image.height)
        #expect(log.entries.first == .canvasClamped(
            requestedWidth: 16_000,
            requestedHeight: 16_000,
            renderedWidth: 5_656,
            renderedHeight: 5_656
        ))
    }

    @Test("a non-square huge-area canvas clamps by area while preserving aspect")
    func canvasAreaClampNonSquare() throws {
        var fixture = RenderFixture()
        // 16000×8000 = 128 Mpx, 2:1. Both sides under the per-side cap; only
        // the area cap applies. The 2:1 ratio must survive (within rounding).
        fixture.bounds = (left: 0, top: 0, right: 15_999, bottom: 7_999)

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))

        #expect(image.width * image.height <= EMFRenderer.canvasAreaCap)
        // sqrt(32_000_000 / 128_000_000) = 0.5; 16000×0.5=8000, 8000×0.5=4000.
        #expect(image.width == 8_000)
        #expect(image.height == 4_000)
        #expect(log.entries.first == .canvasClamped(
            requestedWidth: 16_000,
            requestedHeight: 8_000,
            renderedWidth: 8_000,
            renderedHeight: 4_000
        ))
    }

    @Test("degenerate header bounds still produce a canvas, with a log entry")
    func degenerateBounds() throws {
        var fixture = RenderFixture()
        fixture.bounds = (left: 10, top: 10, right: 9, bottom: 9)   // negative extent

        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file))

        #expect(image.width == 1)
        #expect(image.height == 1)
        // Clamp entry from canvas sizing, zero-extent entry from the
        // device→target fit.
        #expect(log.entries.contains(.zeroExtentMapping))
        #expect(log.entries.contains(.canvasClamped(
            requestedWidth: 0,
            requestedHeight: 0,
            renderedWidth: 1,
            renderedHeight: 1
        )))
    }

    // MARK: - Render-into-context surface

    @Test("render(into:target:) maps device space onto the target rect")
    func renderIntoTarget() throws {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 255, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
        // Fill the left half of the 100×100 device space.
        fixture.polygon16([(0, 0), (50, 0), (50, 100), (0, 100)])
        let file = try fixture.parsed()

        // Render into the RIGHT half of a 200×100 canvas.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 200, height: 100,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            Issue.record("could not create bitmap context")
            return
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))

        let log = EMFRenderer.render(
            file,
            into: context,
            target: CGRect(x: 100, y: 0, width: 100, height: 100)
        )
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)])

        let image = try #require(context.makeImage())
        let pixels = try #require(RasterizedImage(image))
        // Left half of the canvas: untouched white.
        #expect(pixels[50, 50] == (255, 255, 255, 255))
        // Target's left half (canvas x 100…150): red fill.
        #expect(pixels[125, 50] == (255, 0, 0, 255))
        // Target's right half: white.
        #expect(pixels[175, 50] == (255, 255, 255, 255))
    }
}
