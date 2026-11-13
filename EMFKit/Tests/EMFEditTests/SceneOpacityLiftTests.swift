import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// P1 polish: EMF+ alpha lives in the brush/pen ARGB. After an opacity edit is
/// exported and the file reopened, the inspector's Opacity row (`style.opacity`)
/// must read the edited value — not 100% — and the rendered alpha must be
/// unchanged (no double application at render or export).
struct SceneOpacityLiftTests {

    private func scene(_ name: String) throws -> Scene {
        try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name)))
    }

    private static let fillable: Set<ElementKind> = [.rect, .ellipse, .roundRect, .polygon, .polyline, .line, .path, .arc, .bezier]

    @Test func opacityRoundTripsThroughStyleOpacity() throws {
        let base = try scene("gate-p2-house.emf")
        let target = try #require(base.editableElements.first { Self.fillable.contains($0.kind) })
        var edited = base
        try edited.setOpacity([target.id], 0.4)

        let exported = try SceneExporter.export(edited, as: .emf)
        let reimport = try SceneImporter.import(data: exported.data)

        // The inspector reads `style.opacity`: it must reopen at ~40%, not 100% (the bug).
        let semi = try #require(
            reimport.editableElements.first { abs($0.style.opacity - 0.4) < 0.03 },
            "no element reopened at ~40% opacity; opacities=\(reimport.editableElements.map(\.style.opacity))")
        // The alpha is held in opacity with opaque paint, never doubled into both —
        // effective (opacity × paint alpha) must still be ~0.4, never ~0.16.
        let effective = semi.style.opacity * (semi.style.fill?.color.alpha ?? 1)
        #expect(abs(effective - 0.4) < 0.05, "effective alpha \(effective) should be ~0.4 (no double-apply)")
    }

    @Test func renderAlphaUnchangedAfterLift() throws {
        // The lift must not change what is drawn: the exported file rendered directly and
        // the re-imported scene rendered through SceneRenderer agree within tolerance.
        let base = try scene("gate-p2-house.emf")
        let target = try #require(base.editableElements.first { Self.fillable.contains($0.kind) })
        var edited = base
        try edited.setOpacity([target.id], 0.4)
        let exported = try SceneExporter.export(edited, as: .emf)

        let reimport = try SceneImporter.import(data: exported.data)
        let viaScene = try #require(SceneRenderer.makeImage(reimport, scale: 1))
        let opened = try OpenedMetafile.open(exported.data)
        let viaRenderer = try #require(MetafileRenderer.makeImage(opened, scale: 1)?.0)

        let diff = compareImages(viaScene, viaRenderer, tolerance: 16)
        #expect(diff.sameSize && diff.differingFraction < 0.02,
                "re-imported render differs from the exported file by \(diff.differingFraction)")
    }
}
