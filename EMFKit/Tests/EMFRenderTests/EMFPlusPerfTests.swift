import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - Render performance (primer §6 phase 6)
//
// A wall-clock floor test, not a benchmark harness: it renders the LARGEST
// committed corpus file end to end through `EMFRenderer.makeImage` and asserts
// it finishes well under a generous bound, guarding against a catastrophic
// (e.g. accidentally quadratic) regression. It also REPORTS — without asserting
// — the timings of the four hand-authored EMF+ files so an EMF+ playback
// slowdown is visible in the log. Only committed corpus files are used; the
// large work-sourced stress file is verified separately and never referenced
// here.
@Suite("Render performance")
struct EMFPlusPerfTests {

    /// A generous per-file wall-clock ceiling. The committed corpus tops out at
    /// ~16 KB, so a healthy render is milliseconds; 2 s catches only a gross
    /// regression while staying robust to a cold CoreGraphics start and CI load.
    private static let ceiling: Duration = .seconds(2)

    /// Milliseconds from a `Duration`, for human-readable reporting.
    private static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) * 1e-15
    }

    /// The committed corpus `.emf` files, largest first (by byte size).
    private static func corpusFilesBySizeDescending() -> [(name: String, bytes: Int)] {
        let directory = TestPaths.repositoryRoot.appendingPathComponent("corpus")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "emf" }
            .compactMap { url -> (name: String, bytes: Int)? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
                return (url.lastPathComponent, size)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    @Test("the largest committed corpus file renders under a generous wall-clock bound")
    func largestCorpusFileRendersQuickly() throws {
        let largest = try #require(Self.corpusFilesBySizeDescending().first, "no committed corpus .emf files found")
        let file = try parseCorpusFile(largest.name)

        let clock = ContinuousClock()
        var image: CGImage?
        let elapsed = clock.measure {
            image = EMFRenderer.makeImage(file)?.0
        }
        _ = try #require(image, "makeImage returned nil for \(largest.name)")

        print("[perf] largest committed corpus file \(largest.name) (\(largest.bytes) B) rendered in "
            + String(format: "%.1f ms", Self.milliseconds(elapsed)))
        #expect(elapsed < Self.ceiling,
                "\(largest.name) took \(Self.milliseconds(elapsed)) ms, over the \(Self.milliseconds(Self.ceiling)) ms ceiling")
    }

    @Test("EMF+ corpus files render (reported, not asserted)")
    func emfPlusFilesRenderTimingsReported() throws {
        let clock = ContinuousClock()
        for name in [
            "handmade-emfplus-shapes.emf",
            "handmade-emfplus-dual.emf",
            "handmade-emfplus-image.emf",
            "handmade-emfplus-text.emf",
        ] {
            let file = try parseCorpusFile(name)
            var image: CGImage?
            let elapsed = clock.measure { image = EMFRenderer.makeImage(file)?.0 }
            #expect(image != nil, "makeImage returned nil for \(name)")
            print("[perf] \(name) rendered in " + String(format: "%.1f ms", Self.milliseconds(elapsed)))
        }
    }
}
