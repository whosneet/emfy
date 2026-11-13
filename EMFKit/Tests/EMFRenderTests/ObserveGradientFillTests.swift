import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1b regression: EMR_GRADIENTFILL (118) is a DIRECT draw the viewer paints but
/// v1 does not lift to an editable element. Like PATBLT / SETPIXEL / the blits,
/// its playback MUST capture a replayable passthrough op during `observe`, or the
/// scene importer makes an empty passthrough element and the editor's
/// `SceneRenderer` drops the gradient the viewer draws — a per-file fidelity
/// divergence (the solid gradient region differs well past the 0.5% budget).
///
/// Guards the capture call added in the gradientFill case of `EMFRenderer`: the
/// snapshot test only proves the viewer draws it, not that the observation (the
/// scene's lift source) can replay it.
@Suite("GRADIENTFILL observation capture")
struct ObserveGradientFillTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 119, 119)
        f.gradientFill(
            bounds: (10, 10, 100, 100),
            vertices: [
                RenderFixture.triVertex(x: 10, y: 10, r: 230, g: 30, b: 30),
                RenderFixture.triVertex(x: 100, y: 100, r: 30, g: 30, b: 230),
            ],
            mode: 0,   // GRADIENT_FILL_RECT_H
            mesh: [0, 1]
        )
        return f
    }

    @Test("a gradient fill is captured as a replayable passthrough op")
    func capturesPassthroughOp() throws {
        let data = Self.fixture().data()
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let observation = MetafileRenderer.observe(prepared)

        let gradientOps = observation.ops.filter {
            if case .gradientFill = $0.replayPayload { return true }
            return false
        }
        try #require(gradientOps.count == 1, "expected exactly one captured gradient op, got \(gradientOps.count)")
        let op = gradientOps[0]
        // Kept as passthrough (not lifted to an editable primitive) and carrying
        // its own payload so `EMFRenderer.replay` reproduces it exactly.
        #expect(op.kind == .passthrough)
        // Its bounds geometry is non-empty, so the scene element occupies the
        // gradient region rather than collapsing to a zero-size passthrough.
        #expect(!op.deviceGeometry.isEmpty)
    }
}
