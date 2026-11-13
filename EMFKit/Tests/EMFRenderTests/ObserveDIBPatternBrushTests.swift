import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R2: a primitive filled with a DIB pattern brush is NOT lifted to an editable
/// element (v1 lifts solid fills only). Like GRADIENTFILL it must be captured as
/// a REPLAYABLE passthrough op during `observe`, or the scene importer makes an
/// empty passthrough element and the editor's `SceneRenderer` drops the fill the
/// viewer draws — a per-file fidelity divergence (`corpusLocalUneditedMatchesViewer`).
///
/// Guards both capture paths added in R2:
///  - a geometry primitive (rectangle) → a `.passthrough` op carrying its
///    `.rectangle` payload, which `replay` re-runs with the pattern brush;
///  - a path-bracket fill (FILLPATH) → a `.passthrough` op with NO payload but
///    the device geometry, which `replay` fills with the pattern brush.
@Suite("DIB pattern-brush observation capture")
struct ObserveDIBPatternBrushTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 119, 119)
        let tile = SnapshotDIBPatternBrushTests.quadrantTile()
        f.createDIBPatternBrush(index: 1, bmi: tile.bmi, bits: tile.bits)
        f.selectObject(1)                     // select the pattern brush
        f.selectObject(0x8000_0008)           // NULL_PEN

        f.rectangle(8, 8, 56, 56)             // geometry fill

        f.beginPath()                         // path-bracket fill
        f.rectangle(64, 64, 112, 112)
        f.endPath()
        f.fillPath()
        return f
    }

    @Test("pattern-filled geometry and path are captured as replayable passthrough ops")
    func capturesPassthroughOps() throws {
        let data = Self.fixture().data()
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let observation = MetafileRenderer.observe(prepared)

        // Every drawing op this file produces is a pattern fill → all passthrough.
        let passthrough = observation.ops.filter { $0.kind == .passthrough }
        try #require(passthrough.count == 2, "expected 2 passthrough ops, got \(observation.ops.map(\.kind))")

        // The geometry (rectangle) op carries its payload so replay re-draws it.
        let rectOps = passthrough.filter {
            if case .rectangle = $0.replayPayload { return true }
            return false
        }
        #expect(rectOps.count == 1, "the pattern rectangle should carry a .rectangle replay payload")
        #expect(!rectOps.first!.deviceGeometry.isEmpty)

        // The path-closer op carries no payload but a non-empty device geometry,
        // which replay fills with the pattern brush from the captured state.
        let pathOps = passthrough.filter { $0.replayPayload == nil }
        #expect(pathOps.count == 1, "the pattern path fill should be a payload-less passthrough op")
        #expect(!pathOps.first!.deviceGeometry.isEmpty)
    }

    @Test("replaying a pattern passthrough op paints the tile, not a blank")
    func replayPaintsPattern() throws {
        let data = Self.fixture().data()
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let observation = MetafileRenderer.observe(prepared)
        let rectOp = try #require(observation.ops.first {
            if case .rectangle = $0.replayPayload { return true }
            return false
        })

        // Replay the geometry op into a fresh 64×64 context at scale 1 (base =
        // identity-ish device→target for this canvas) and confirm a tile pixel
        // is painted with a quadrant colour, not left blank.
        let w = 64, h = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // deviceToTarget for a 120-tall page rendered into our 64px crop is not the
        // canvas fit here; we only need SOME transform that lands the rect in view.
        // Use the op's own device→target identity with a y-flip matching EMFRender.
        let base = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        EMFRenderer.replay(rectOp, into: ctx, deviceToTarget: base)

        // Sample inside the rectangle (device 8..56 → after the flip, still inside
        // the 64px crop). At least one quadrant colour must be present.
        func painted(_ x: Int, _ y: Int) -> Bool {
            let o = (y * w + x) * 4
            return px[o] > 20 || px[o + 1] > 20 || px[o + 2] > 20
        }
        #expect(painted(20, 20) || painted(30, 30) || painted(40, 40),
                "replay of a pattern fill must paint the tile, not leave it blank")
    }
}
