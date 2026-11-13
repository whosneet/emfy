// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for EMR_ABORTPATH (68). A path bracket that builds a large
/// rectangle, is ABORTED, then "filled" must paint NOTHING — the fill closer has
/// no path to consume. The differential test proves the abort by comparing to a
/// run where the bracket is never opened at all; the snapshot pins the single
/// genuinely-drawn rectangle.
@Suite("ABORTPATH render")
struct SnapshotAbortPathTests {

    /// Draws one real blue rectangle, then (optionally) opens a path bracket for
    /// a big rectangle, aborts it, and issues STROKEANDFILLPATH — which must
    /// draw nothing because ABORTPATH discarded the path.
    private static func fixture(withAbortedBracket: Bool) -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 159, 119)
        f.createSolidBrush(index: 1, r: 60, g: 120, b: 200)
        f.createPen(index: 2, style: 0, width: 2, r: 0, g: 0, b: 0)
        f.selectObject(1)
        f.selectObject(2)
        // A genuine filled rectangle via a completed path bracket.
        f.beginPath()
        f.rectangle(20, 20, 70, 70)
        f.endPath()
        f.strokeAndFillPath()

        if withAbortedBracket {
            // A second, larger rectangle whose bracket is ABORTED before fill.
            f.beginPath()
            f.rectangle(10, 10, 150, 110)
            f.abortPath()
            f.strokeAndFillPath()   // nothing to fill — the path was discarded
        }
        return f
    }

    @Test("an aborted path bracket draws nothing: identical to never opening it")
    func abortDrawsNothing() throws {
        let abortedImage = try #require(EMFRenderer.makeImage(Self.fixture(withAbortedBracket: true).parsed())?.0)
        let baselineImage = try #require(EMFRenderer.makeImage(Self.fixture(withAbortedBracket: false).parsed())?.0)
        let aborted = try #require(RasterizedImage(abortedImage))
        let baseline = try #require(RasterizedImage(baselineImage))
        var differing = 0
        for i in stride(from: 0, to: aborted.pixels.count, by: 1) where aborted.pixels[i] != baseline.pixels[i] {
            differing += 1
        }
        #expect(differing == 0, "ABORTPATH left \(differing) differing bytes — the aborted path painted")
    }

    @Test("ABORTPATH fixture matches the accepted baseline (only the real rect)")
    func snapshot() throws {
        let image = try #require(EMFRenderer.makeImage(Self.fixture(withAbortedBracket: true).parsed())?.0)
        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-abortpath")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
