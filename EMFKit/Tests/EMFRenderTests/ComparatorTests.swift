import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Proves the snapshot comparator's FAILURE paths actually fire — an
/// always-green comparator would silently rot the phase gate. The pass path
/// is exercised by the snapshot suite itself.
///
/// Disabled in record mode: these tests feed deliberately WRONG images into
/// `verify`, which in record mode would overwrite real baselines.
@Suite("Snapshot comparator failure paths", .enabled(if: !isRecordingBaselines))
struct ComparatorTests {

    /// Renders one gate file for cross-comparison material.
    private static func gateImage(_ name: String) throws -> CGImage {
        let file = try parseCorpusFile("\(name).emf")
        let rendered = try #require(EMFRenderer.makeImage(file))
        return rendered.0
    }

    @Test("different same-size images fail and write artifacts")
    func pixelMismatchFails() throws {
        // The star render against the HOUSE baseline: same 373×273 canvas,
        // completely different scene.
        let star = try Self.gateImage("gate-p2-star")
        let failure = SnapshotComparator.verify(star, baselineNamed: "gate-p2-house")

        let message = try #require(failure, "comparator passed two different images")
        #expect(message.contains("of pixels differ"))
        #expect(message.contains("emfy-snapshot-artifacts"))

        let artifactDirectory = TestPaths.artifactsDirectory
            .appendingPathComponent("gate-p2-house")
        for artifact in ["actual.png", "expected.png", "diff.png"] {
            let url = artifactDirectory.appendingPathComponent(artifact)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "missing failure artifact \(artifact)"
            )
        }
        // Leave no bait for someone debugging a REAL gate failure later.
        try? FileManager.default.removeItem(at: artifactDirectory)
    }

    @Test("a size mismatch fails before any pixel comparison")
    func sizeMismatchFails() throws {
        var fixture = RenderFixture()   // 100×100 canvas ≠ 373×273 baseline
        fixture.polygon16([(10, 10), (90, 10), (50, 90)])
        let file = try fixture.parsed()
        let rendered = try #require(EMFRenderer.makeImage(file))

        let failure = SnapshotComparator.verify(rendered.0, baselineNamed: "gate-p2-house")
        let message = try #require(failure, "comparator passed a size mismatch")
        #expect(message.contains("size mismatch"))

        try? FileManager.default.removeItem(
            at: TestPaths.artifactsDirectory.appendingPathComponent("gate-p2-house")
        )
    }

    @Test("an unknown baseline name fails with recording guidance")
    func missingBaselineFails() throws {
        let star = try Self.gateImage("gate-p2-star")
        let failure = SnapshotComparator.verify(star, baselineNamed: "no-such-baseline")
        let message = try #require(failure)
        #expect(message.contains("EMFY_RECORD=1"))
    }
}
