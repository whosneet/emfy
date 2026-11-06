import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// E1a fidelity gate: the scene renderer's output must match
/// `MetafileRenderer`'s render of the source within the snapshot tolerance,
/// proving the import lift captured the drawing. Geometry elements are drawn
/// from their VALUE-TYPE geometry and style; text/image/passthrough elements
/// replay through EMFRender (their content is asserted in the model tests).
struct SceneFidelityTests {

    /// Per-channel tolerance and differing-pixel budget match the renderer's
    /// snapshot comparator (16/255, 1%).
    static let tolerance = 16
    static let maxDifferingFraction = 0.01
    static let maxMeanDelta = 2.0

    @Test func sceneRenderMatchesSourceForEveryCommittedFile() throws {
        let files = EditTestPaths.committedMetafiles()
        try #require(!files.isEmpty)

        var report = "\n=== E1a fidelity table (scene render vs source) ===\n"
        for url in files {
            let data = try Data(contentsOf: url)
            guard let opened = try? OpenedMetafile.open(data),
                  let prepared = MetafileRenderer.prepare(opened),
                  let (sourceImage, _) = MetafileRenderer.makeImage(prepared)
            else {
                Issue.record("could not render source \(url.lastPathComponent)")
                continue
            }
            let scene = try SceneImporter.import(data: data)
            guard let sceneImage = SceneRenderer.makeImage(scene) else {
                Issue.record("could not render scene \(url.lastPathComponent)")
                continue
            }

            let diff = compareImages(sceneImage, sourceImage, tolerance: Self.tolerance)
            report += String(
                format: "%-32@ size=%@ maxΔ=%3d diff=%6.3f%% mean=%.3f\n",
                url.lastPathComponent, diff.sameSize ? "ok" : "MISMATCH",
                diff.maxChannelDelta, diff.differingFraction * 100, diff.meanDelta
            )

            #expect(diff.sameSize, "\(url.lastPathComponent): render size differs from source")
            #expect(diff.differingFraction <= Self.maxDifferingFraction,
                    "\(url.lastPathComponent): \(diff.differingFraction * 100)% of pixels differ (budget \(Self.maxDifferingFraction * 100)%)")
            #expect(diff.meanDelta <= Self.maxMeanDelta,
                    "\(url.lastPathComponent): mean per-channel Δ \(diff.meanDelta) (budget \(Self.maxMeanDelta))")
        }
        print(report)
    }
}
