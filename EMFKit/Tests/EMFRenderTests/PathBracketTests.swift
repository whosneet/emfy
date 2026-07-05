import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-3 path brackets ([MS-EMF] §2.3.10, §2.3.5.9/.38/.39): geometry inside
/// a bracket records into the current path instead of drawing; the closers
/// paint and consume it. All probes are on the fixture's 100×100 MM_TEXT canvas
/// (logical == device == image pixel, y-down, row 0 = top).
@Suite("Path brackets")
struct PathBracketTests {

    /// A solid black brush selected, NULL pen (no outline) unless a test needs
    /// one — so fill probes are unambiguous.
    private static func blackFillNoPen(_ fixture: inout RenderFixture) {
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
    }

    private static func render(_ fixture: RenderFixture) throws -> (RasterizedImage, EMFRenderLog) {
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
        return (try #require(RasterizedImage(image)), log)
    }

    /// The benign EOF-terminator skip that ends every fixture file.
    private static let eofOnly: [EMFRenderLog.Entry] = [.unimplementedRecord(type: 14, count: 1)]

    // MARK: - Recording vs drawing

    @Test("geometry inside a bracket draws nothing until FILLPATH")
    func recordingDrawsNothing() throws {
        // First: a rectangle recorded into a bracket, then ENDPATH — but NO
        // closer. The canvas must be untouched white.
        var recorded = RenderFixture()
        Self.blackFillNoPen(&recorded)
        recorded.beginPath()
        recorded.rectangle(20, 20, 80, 80)
        recorded.endPath()
        let (unpainted, unpaintedLog) = try Self.render(recorded)
        #expect(unpaintedLog.entries == Self.eofOnly)
        #expect(unpainted[50, 50] == (255, 255, 255, 255), "recording must not draw")
        #expect(unpainted[30, 30] == (255, 255, 255, 255))

        // Same records plus FILLPATH: now the rectangle interior is black.
        var painted = RenderFixture()
        Self.blackFillNoPen(&painted)
        painted.beginPath()
        painted.rectangle(20, 20, 80, 80)
        painted.endPath()
        painted.fillPath()
        let (filled, filledLog) = try Self.render(painted)
        #expect(filledLog.entries == Self.eofOnly)
        #expect(filled[50, 50] == (0, 0, 0, 255), "FILLPATH must paint the recorded rect")
    }

    @Test("moveTo starts subpaths; closeFigure splits them so the fill differs")
    func closeFigureStartsNewFigure() throws {
        // Path A: three points, ONE open subpath. FILLPATH auto-closes it into
        // a triangle; the centroid (≈50,60) fills black.
        var triangle = RenderFixture()
        Self.blackFillNoPen(&triangle)
        triangle.beginPath()
        triangle.moveToEx(20, 80)
        triangle.lineTo(50, 20)
        triangle.lineTo(80, 80)
        triangle.endPath()
        triangle.fillPath()
        let (tri, triLog) = try Self.render(triangle)
        #expect(triLog.entries == Self.eofOnly)
        #expect(tri[50, 60] == (0, 0, 0, 255), "auto-closed triangle fills its centroid")

        // Path B: CLOSEFIGURE after two points splits the run into two
        // degenerate line figures ((20,80)→(50,20) closed, then (50,20)→(80,80)
        // as a new figure). Neither has area — the centroid stays white.
        var split = RenderFixture()
        Self.blackFillNoPen(&split)
        split.beginPath()
        split.moveToEx(20, 80)
        split.lineTo(50, 20)
        split.closeFigure()
        split.lineTo(80, 80)
        split.endPath()
        split.fillPath()
        let (splitImg, splitLog) = try Self.render(split)
        #expect(splitLog.entries == Self.eofOnly)
        #expect(splitImg[50, 60] == (255, 255, 255, 255), "CLOSEFIGURE split leaves no fillable area")
    }

    @Test("CLOSEFIGURE adds the closing edge when stroking an open V")
    func closeFigureStroke() throws {
        // A cosmetic black pen (stock BLACK_PEN, default) strokes the path; NULL
        // brush so only the outline shows. Open V: two edges meeting at the top.
        var openV = RenderFixture()
        openV.selectObject(0x8000_0005)       // NULL_BRUSH (no fill)
        openV.beginPath()
        openV.moveToEx(20, 20)
        openV.lineTo(50, 80)
        openV.lineTo(80, 20)
        openV.endPath()
        openV.strokePath()
        let (v, vLog) = try Self.render(openV)
        #expect(vLog.entries == Self.eofOnly)
        // No closing edge across the top-middle gap (around y≈20, x≈50 is a
        // vertex, but the horizontal span 30..70 at y≈20 has no stroke between
        // the two arms except at the arms themselves). Probe the interior just
        // below the top edge, between the arms: no ink.
        #expect(!v.containsDarkPixel(in: (x: 45, y: 30, width: 10, height: 6)),
                "open V has no closing edge across its middle")

        // With CLOSEFIGURE, the third edge (80,20)→(20,20) is stroked along the
        // top; probe the top edge midpoint for ink.
        var closed = RenderFixture()
        closed.selectObject(0x8000_0005)      // NULL_BRUSH
        closed.beginPath()
        closed.moveToEx(20, 20)
        closed.lineTo(50, 80)
        closed.lineTo(80, 20)
        closed.closeFigure()
        closed.endPath()
        closed.strokePath()
        let (tri, triLog) = try Self.render(closed)
        #expect(triLog.entries == Self.eofOnly)
        #expect(tri.containsDarkPixel(in: (x: 45, y: 18, width: 10, height: 5)),
                "CLOSEFIGURE strokes the closing top edge")
    }

    // MARK: - Closer edge cases

    @Test("a closer with no current path logs noCurrentPath and skips")
    func closerWithNoPath() throws {
        var fixture = RenderFixture()
        Self.blackFillNoPen(&fixture)
        fixture.fillPath()                    // no bracket ever opened
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [
            .noCurrentPath(record: 62),
            .unimplementedRecord(type: 14, count: 1),
        ])
        #expect(image[50, 50] == (255, 255, 255, 255), "nothing to fill")
    }

    @Test("a second FILLPATH right after the first logs noCurrentPath (path consumed)")
    func pathConsumedBySecondFill() throws {
        var fixture = RenderFixture()
        Self.blackFillNoPen(&fixture)
        fixture.beginPath()
        fixture.rectangle(20, 20, 80, 80)
        fixture.endPath()
        fixture.fillPath()                    // consumes the path
        fixture.fillPath()                    // nothing left
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [
            .noCurrentPath(record: 62),
            .unimplementedRecord(type: 14, count: 1),
        ])
        // The first fill still painted.
        #expect(image[50, 50] == (0, 0, 0, 255))
    }

    @Test("a nested BEGINPATH logs and starts a fresh bracket")
    func nestedBeginPath() throws {
        var fixture = RenderFixture()
        Self.blackFillNoPen(&fixture)
        fixture.beginPath()
        fixture.rectangle(0, 0, 40, 40)       // recorded into bracket 1
        fixture.beginPath()                   // nested: logs, discards bracket 1
        fixture.rectangle(60, 60, 90, 90)     // recorded into the fresh bracket
        fixture.endPath()
        fixture.fillPath()
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [
            .nestedBeginPath,
            .unimplementedRecord(type: 14, count: 1),
        ])
        // Only the fresh bracket's rect painted; the discarded one did not.
        #expect(image[75, 75] == (0, 0, 0, 255), "fresh bracket fills")
        #expect(image[20, 20] == (255, 255, 255, 255), "discarded bracket does not")
    }

    // MARK: - Fill vs stroke vs stroke-and-fill

    /// A distinct-outcome probe set on a rectangle (20,20)-(80,80) filled red
    /// with a thick (width 8) blue pen. Interior centre, an edge band, and the
    /// outside are probed.
    private static func rectBracket(_ fixture: inout RenderFixture) {
        fixture.createSolidBrush(index: 1, r: 255, g: 0, b: 0)  // red brush
        fixture.selectObject(1)
        // Geometric blue pen, width 8.
        fixture.createPen(index: 2, style: 0, width: 8, r: 0, g: 0, b: 255)
        fixture.selectObject(2)
        fixture.beginPath()
        fixture.rectangle(20, 20, 80, 80)
        fixture.endPath()
    }

    @Test("FILLPATH fills without outline")
    func fillOnly() throws {
        var fixture = RenderFixture()
        Self.rectBracket(&fixture)
        fixture.fillPath()
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(image[50, 50] == (255, 0, 0, 255), "interior red")
        // The edge (x≈20) is red-filled but NOT blue-stroked.
        #expect(image[20, 50].b < 128, "no blue outline under FILLPATH")
    }

    @Test("STROKEPATH outlines without fill")
    func strokeOnly() throws {
        var fixture = RenderFixture()
        Self.rectBracket(&fixture)
        fixture.strokePath()
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        // Interior NOT filled (white), edge IS blue.
        #expect(image[50, 50] == (255, 255, 255, 255), "interior unfilled")
        #expect(image.containsBluePixel(in: (x: 16, y: 46, width: 9, height: 9)),
                "left edge is blue-stroked")
    }

    @Test("STROKEANDFILLPATH fills AND outlines")
    func strokeAndFill() throws {
        var fixture = RenderFixture()
        Self.rectBracket(&fixture)
        fixture.strokeAndFillPath()
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(image[50, 50] == (255, 0, 0, 255), "interior red-filled")
        #expect(image.containsBluePixel(in: (x: 16, y: 46, width: 9, height: 9)),
                "left edge blue-stroked")
    }

    @Test("polyfill mode is respected through FILLPATH on a self-intersecting path")
    func fillPathPolyfillMode() throws {
        // A pentagram recorded into a bracket; its centre has winding number 2:
        // filled under WINDING, a hole under ALTERNATE.
        func pentagram(fillModeRaw: UInt32) throws -> RasterizedImage {
            var fixture = RenderFixture()
            fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
            fixture.selectObject(1)
            fixture.selectObject(0x8000_0008) // NULL_PEN
            fixture.setPolyFillMode(fillModeRaw)
            fixture.beginPath()
            fixture.polygon16([(50, 10), (74, 85), (11, 38), (89, 38), (26, 85)])
            fixture.endPath()
            fixture.fillPath()
            let (image, _) = try Self.render(fixture)
            return image
        }
        let alternate = try pentagram(fillModeRaw: 0x01)
        let winding = try pentagram(fillModeRaw: 0x02)
        #expect(alternate[50, 50] == (255, 255, 255, 255), "ALTERNATE: centre is a hole")
        #expect(winding[50, 50] == (0, 0, 0, 255), "WINDING: centre is filled")
    }

    // MARK: - Transform mid-bracket

    @Test("a transform change mid-bracket affects only later records")
    func transformMidBracket() throws {
        // Two rectangles recorded into one bracket. Before the second, a world
        // transform translates by (+40, 0). The first rect keeps its logical
        // position; the second shifts right. Both fill black on FILLPATH.
        var fixture = RenderFixture()
        Self.blackFillNoPen(&fixture)
        fixture.beginPath()
        fixture.rectangle(5, 40, 25, 60)          // left rect: x 5..25
        fixture.setWorldTransform(1, 0, 0, 1, 40, 0)  // translate +40 in x
        fixture.rectangle(5, 40, 25, 60)          // same logical coords → x 45..65
        fixture.endPath()
        fixture.fillPath()
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        // First rect at its original spot (transform applied AFTER it recorded).
        #expect(image[15, 50] == (0, 0, 0, 255), "pre-transform rect stays put")
        // Second rect shifted +40.
        #expect(image[55, 50] == (0, 0, 0, 255), "post-transform rect shifted right")
        // The gap between them (x≈35) is untouched.
        #expect(image[35, 50] == (255, 255, 255, 255), "gap between the two rects")
    }
}
