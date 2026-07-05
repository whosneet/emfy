import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Proves the snapshot comparator's FAILURE paths actually fire — an
/// always-green comparator would silently rot the phase gate. The pass path
/// is exercised by the snapshot suite itself.
///
/// These tests verify against a DEDICATED baseline, `comparator-selftest`, and
/// write/remove artifacts under `.build/emfy-snapshot-artifacts/comparator-selftest`.
/// That name is deliberately NOT any real snapshot's: the self-tests and the
/// gate snapshots run in parallel, and the self-tests remove their artifact dir
/// on the way out. Pointing them at a real gate name (e.g. gate-p2-house) would
/// let this suite delete a genuine gate failure's actual/expected/diff PNGs out
/// from under someone debugging it.
///
/// Disabled in record mode: these tests feed deliberately WRONG images into
/// `verify`, which in record mode would overwrite real baselines.
@Suite("Snapshot comparator failure paths", .enabled(if: !isRecordingBaselines))
struct ComparatorTests {

    /// The self-test artifact directory (never a real snapshot's name).
    private static let selfTestBaseline = "comparator-selftest"
    private static var selfTestArtifactDirectory: URL {
        TestPaths.artifactsDirectory.appendingPathComponent(selfTestBaseline)
    }

    /// Renders one gate file for cross-comparison material.
    private static func gateImage(_ name: String) throws -> CGImage {
        let file = try parseCorpusFile("\(name).emf")
        let rendered = try #require(EMFRenderer.makeImage(file))
        return rendered.0
    }

    /// A blank 100×100 canvas — same dimensions as the `comparator-selftest`
    /// baseline (a solid-black 100×100 fill), but every pixel differs from it.
    private static func blankSelfTestSizedImage() throws -> CGImage {
        let fixture = RenderFixture()          // default 100×100 bounds, no drawing
        let file = try fixture.parsed()
        let rendered = try #require(EMFRenderer.makeImage(file))
        return rendered.0
    }

    @Test("different same-size images fail and write artifacts")
    func pixelMismatchFails() throws {
        // A blank white 100×100 canvas against the solid-black 100×100 baseline:
        // same dimensions, so the comparison reaches the per-pixel pass and
        // nearly every pixel differs — well past the 1% budget.
        let blank = try Self.blankSelfTestSizedImage()
        let failure = SnapshotComparator.verify(blank, baselineNamed: Self.selfTestBaseline)

        let message = try #require(failure, "comparator passed two different images")
        #expect(message.contains("of pixels differ"))
        #expect(message.contains("emfy-snapshot-artifacts"))

        let artifactDirectory = Self.selfTestArtifactDirectory
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
        // The 373×273 star render against the 100×100 self-test baseline: the
        // dimensions differ, so the comparator must fail on size alone.
        let star = try Self.gateImage("gate-p2-star")
        let failure = SnapshotComparator.verify(star, baselineNamed: Self.selfTestBaseline)
        let message = try #require(failure, "comparator passed a size mismatch")
        #expect(message.contains("size mismatch"))

        try? FileManager.default.removeItem(at: Self.selfTestArtifactDirectory)
    }

    @Test("an unknown baseline name fails with recording guidance")
    func missingBaselineFails() throws {
        let star = try Self.gateImage("gate-p2-star")
        let failure = SnapshotComparator.verify(star, baselineNamed: "no-such-baseline")
        let message = try #require(failure)
        #expect(message.contains("EMFY_RECORD=1"))
    }
}
