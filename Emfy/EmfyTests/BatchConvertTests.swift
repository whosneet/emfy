import EMFRender
import Foundation
import Testing

// F1 unit tests for the pure batch-convert engine (`BatchConvert`): output naming
// with no-overwrite, bounded concurrency, report classification, and the
// log-and-skip classification of a hostile/garbage input through `BatchRenderer`.

@Suite struct BatchConvertTests {

    private func source(_ name: String, dir: String = "/in") -> BatchSource {
        BatchSource(url: URL(fileURLWithPath: "\(dir)/\(name)"))
    }

    private func convertedNames(_ report: BatchReport) -> [String] {
        report.entries.compactMap {
            if case .converted(let url) = $0.outcome { return url.lastPathComponent }
            return nil
        }
    }

    // MARK: naming + no overwrite

    @Test func sameStemGetsNumberedSuffixes() async {
        let dir = URL(fileURLWithPath: "/out")
        let report = await BatchConvert.run(
            sources: [source("a.emf"), source("a.wmf")],
            format: .png, maxConcurrent: 1,
            destination: { _ in dir },
            produce: { _, _ in .converted(Data([1])) },
            write: { _, _ in },
            fileExists: { _ in false })
        #expect(convertedNames(report) == ["a.png", "a 2.png"])
    }

    @Test func existingFileOnDiskIsNeverOverwritten() async {
        let dir = URL(fileURLWithPath: "/out")
        let existing: Set<String> = ["/out/a.png"]
        let report = await BatchConvert.run(
            sources: [source("a.emf"), source("a.wmf")],
            format: .png, maxConcurrent: 1,
            destination: { _ in dir },
            produce: { _, _ in .converted(Data([1])) },
            write: { _, _ in },
            fileExists: { existing.contains($0.path) })
        // The on-disk "a.png" is skipped over, so the two outputs take " 2" and " 3".
        #expect(convertedNames(report) == ["a 2.png", "a 3.png"])
    }

    @Test func differentDirectoriesDoNotCollide() async {
        // "Next to originals": each output lands beside its own source, so identical
        // stems in different folders both keep the base name.
        let report = await BatchConvert.run(
            sources: [source("a.emf", dir: "/one"), source("a.emf", dir: "/two")],
            format: .pdf, maxConcurrent: 1,
            destination: { $0.url.deletingLastPathComponent() },
            produce: { _, _ in .converted(Data([1])) },
            write: { _, _ in },
            fileExists: { _ in false })
        let paths = report.entries.compactMap {
            if case .converted(let url) = $0.outcome { return url.path }
            return nil
        }
        #expect(paths == ["/one/a.pdf", "/two/a.pdf"])
    }

    // MARK: bounded concurrency

    @Test func neverRunsMoreThanTheConcurrencyLimit() async {
        let tracker = ConcurrencyTracker()
        let sources = (0..<8).map { source("f\($0).emf") }
        _ = await BatchConvert.run(
            sources: sources,
            format: .png, maxConcurrent: 2,
            destination: { _ in URL(fileURLWithPath: "/out") },
            produce: { _, _ in
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(15))
                await tracker.leave()
                return .converted(Data([1]))
            },
            write: { _, _ in },
            fileExists: { _ in false })
        let peak = await tracker.peak
        #expect(peak <= 2)
        #expect(peak == 2)   // with 8 sources it does reach the limit
    }

    // MARK: report classification

    @Test func reportBucketsConvertedSkippedAndFailed() async {
        let sources = [source("good.emf"), source("hostile.emf"), source("err.emf"), source("good2.emf")]
        let report = await BatchConvert.run(
            sources: sources,
            format: .png, maxConcurrent: 2,
            destination: { _ in URL(fileURLWithPath: "/out") },
            produce: { src, _ in
                switch src.displayName {
                case "hostile.emf": return .unparseable(reason: "Not a supported metafile.")
                case "err.emf": return .failed(reason: "Couldn’t produce a PNG.")
                default: return .converted(Data([1]))
                }
            },
            write: { _, _ in },
            fileExists: { _ in false })
        #expect(report.converted == 2)
        #expect(report.skipped == 1)
        #expect(report.failed == 1)
        // Every source is accounted for: processed + cancelled == total.
        #expect(report.entries.count + report.cancelled == sources.count)
    }

    @Test func writeErrorIsReportedAsFailed() async {
        struct WriteError: Error {}
        let report = await BatchConvert.run(
            sources: [source("a.emf")],
            format: .pdf, maxConcurrent: 1,
            destination: { _ in URL(fileURLWithPath: "/out") },
            produce: { _, _ in .converted(Data([1])) },
            write: { _, _ in throw WriteError() },
            fileExists: { _ in false })
        #expect(report.failed == 1)
        #expect(report.converted == 0)
    }

    @Test func emptyInputIsAnEmptyReport() async {
        let report = await BatchConvert.run(
            sources: [], format: .png,
            destination: { _ in URL(fileURLWithPath: "/out") },
            produce: { _, _ in .converted(Data()) },
            write: { _, _ in },
            fileExists: { _ in false })
        #expect(report.entries.isEmpty)
        #expect(report.cancelled == 0)
    }

    // MARK: log-and-skip on hostile input (real renderer)

    @Test(arguments: BatchOutputFormat.allCases)
    func hostileBytesAreSkippedNotCrashed(_ format: BatchOutputFormat) {
        let garbage = Data((0..<128).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 7) })
        let outcome = BatchRenderer.produce(
            bytes: garbage, format: format, pngScale: 2, background: .white, options: .default)
        // A hostile input is never a crash and never a silent success — it is a typed
        // skip (log-and-skip, §8).
        if case .unparseable = outcome { } else {
            Issue.record("expected .unparseable for garbage \(format.rawValue), got \(outcome)")
        }
    }

    @Test func emptyBytesAreSkipped() {
        for format in BatchOutputFormat.allCases {
            let outcome = BatchRenderer.produce(
                bytes: Data(), format: format, pngScale: 2, background: .white, options: .default)
            if case .unparseable = outcome { } else {
                Issue.record("expected .unparseable for empty \(format.rawValue)")
            }
        }
    }
}

/// Tracks the peak number of `produce` closures running at once, to prove the
/// engine's concurrency bound.
private actor ConcurrencyTracker {
    private(set) var peak = 0
    private var inflight = 0

    func enter() {
        inflight += 1
        peak = max(peak, inflight)
    }

    func leave() {
        inflight -= 1
    }
}
