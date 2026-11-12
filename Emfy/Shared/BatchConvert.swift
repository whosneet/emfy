import Foundation

/// The output format a batch run writes each file as (F1 design call 4).
enum BatchOutputFormat: String, CaseIterable, Sendable, Identifiable {
    case png
    case pdf
    case svg

    var id: String { rawValue }
    var pathExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

/// One input to a batch run: a stable id and the original file URL. The output stem
/// is the original's name without its extension, so "<stem>.<ext>" names the result.
struct BatchSource: Sendable, Identifiable, Equatable {
    let id: UUID
    let url: URL

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    /// The output filename stem — the original name with its extension removed.
    var stem: String { url.deletingPathExtension().lastPathComponent }
    /// The original file name, shown in the report.
    var displayName: String { url.lastPathComponent }
}

/// What producing one output yielded. `.unparseable` is the log-and-skip path for a
/// hostile or non-metafile input (§8): it never crashes the run, it is reported as a
/// skip with a reason. `.failed` is an unexpected production error (e.g. an encode
/// failure on a parseable file).
enum BatchProduceOutcome: Sendable, Equatable {
    case converted(Data)
    case unparseable(reason: String)
    case failed(reason: String)
}

/// The per-file and aggregate result of a batch run (F1: a per-file report of
/// converted / skipped / failed).
struct BatchReport: Sendable, Equatable {
    /// One file's fate.
    enum Outcome: Sendable, Equatable {
        /// Converted and written to this URL.
        case converted(URL)
        /// Skipped because the input could not be parsed (the reason is shown).
        case skipped(reason: String)
        /// Failed after a successful parse (a write or encode error).
        case failed(reason: String)
    }

    struct Entry: Sendable, Equatable, Identifiable {
        let id: UUID
        let displayName: String
        let outcome: Outcome
    }

    /// The entries in source order (cancelled, never-started files are absent).
    let entries: [Entry]
    /// How many sources were never processed because the run was cancelled.
    let cancelled: Int

    var converted: Int { entries.filter { if case .converted = $0.outcome { return true }; return false }.count }
    var skipped: Int { entries.filter { if case .skipped = $0.outcome { return true }; return false }.count }
    var failed: Int { entries.filter { if case .failed = $0.outcome { return true }; return false }.count }
}

/// The pure batch-convert engine (F1 design call 4). It owns the policy — output
/// naming with no-overwrite, bounded concurrency, per-file classification and the
/// aggregate report — while the renderer (`produce`: bytes → output data or a typed
/// skip) and the writer (`write`: data → URL) are injected, so the engine is tested
/// without EMFKit or the disk. Foundation only.
enum BatchConvert {
    /// The default maximum number of files converted at once (owner: concurrency 2).
    static let defaultConcurrency = 2

    /// Runs the batch. Each source is produced (possibly concurrently, bounded by
    /// `maxConcurrent`), then its output is written under a non-colliding
    /// "<stem>.<ext>" in `destination(source)`. Cancelling the surrounding task stops
    /// scheduling new files; those already in flight finish and appear in the report,
    /// and the untouched remainder is counted in `cancelled`.
    ///
    /// - Parameters:
    ///   - destination: the directory to write a source's output into (a chosen folder
    ///     or, for "next to originals", the source's own directory).
    ///   - produce: renders a source into `format`, or returns a typed skip/failure.
    ///   - write: writes bytes to the claimed URL, or throws.
    ///   - fileExists: whether a path is already taken on disk (drives no-overwrite).
    ///   - progress: called on the engine's task with the running completed count.
    static func run(
        sources: [BatchSource],
        format: BatchOutputFormat,
        maxConcurrent: Int = defaultConcurrency,
        destination: @escaping @Sendable (BatchSource) -> URL,
        produce: @escaping @Sendable (BatchSource, BatchOutputFormat) async -> BatchProduceOutcome,
        write: @escaping @Sendable (Data, URL) throws -> Void,
        fileExists: @escaping @Sendable (URL) -> Bool,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async -> BatchReport {
        guard !sources.isEmpty else { return BatchReport(entries: [], cancelled: 0) }
        let namer = OutputNamer(fileExists: fileExists)
        let limit = min(max(1, maxConcurrent), sources.count)

        var byIndex: [Int: BatchReport.Entry] = [:]
        var completed = 0

        await withTaskGroup(of: (Int, BatchReport.Entry).self) { group in
            var next = 0
            while next < limit {
                let index = next
                next += 1
                group.addTask {
                    (index, await process(sources[index], format: format, namer: namer,
                                          destination: destination, produce: produce, write: write))
                }
            }
            while let (index, entry) = await group.next() {
                byIndex[index] = entry
                completed += 1
                progress(completed)
                if !Task.isCancelled, next < sources.count {
                    let scheduled = next
                    next += 1
                    group.addTask {
                        (scheduled, await process(sources[scheduled], format: format, namer: namer,
                                                  destination: destination, produce: produce, write: write))
                    }
                }
            }
        }

        let entries = (0..<sources.count).compactMap { byIndex[$0] }
        return BatchReport(entries: entries, cancelled: sources.count - entries.count)
    }

    /// Produces one source and classifies it. A production skip/failure never touches
    /// the disk; a conversion claims a non-colliding name, then writes.
    private static func process(
        _ source: BatchSource,
        format: BatchOutputFormat,
        namer: OutputNamer,
        destination: @Sendable (BatchSource) -> URL,
        produce: @Sendable (BatchSource, BatchOutputFormat) async -> BatchProduceOutcome,
        write: @Sendable (Data, URL) throws -> Void
    ) async -> BatchReport.Entry {
        let id = source.id
        let name = source.displayName
        switch await produce(source, format) {
        case .unparseable(let reason):
            return BatchReport.Entry(id: id, displayName: name, outcome: .skipped(reason: reason))
        case .failed(let reason):
            return BatchReport.Entry(id: id, displayName: name, outcome: .failed(reason: reason))
        case .converted(let data):
            let url = await namer.claim(
                directory: destination(source), stem: source.stem, ext: format.pathExtension)
            do {
                try write(data, url)
                return BatchReport.Entry(id: id, displayName: name, outcome: .converted(url))
            } catch {
                return BatchReport.Entry(id: id, displayName: name, outcome: .failed(reason: String(describing: error)))
            }
        }
    }
}

/// Serialises output-name assignment so two files converting at once can never claim
/// the same path. A name is taken when it is already on disk (`fileExists`) or already
/// claimed this run; the first free name is "<stem>.<ext>", then "<stem> 2.<ext>",
/// "<stem> 3.<ext>", … (F1: never overwrite; add " 2" and so on on a clash).
private actor OutputNamer {
    private var claimed: Set<String> = []
    private let fileExists: @Sendable (URL) -> Bool

    init(fileExists: @escaping @Sendable (URL) -> Bool) {
        self.fileExists = fileExists
    }

    func claim(directory: URL, stem: String, ext: String) -> URL {
        var index = 1
        while true {
            let base = index == 1 ? stem : "\(stem) \(index)"
            let url = directory.appendingPathComponent("\(base).\(ext)")
            let key = url.path.lowercased()
            if !claimed.contains(key), !fileExists(url) {
                claimed.insert(key)
                return url
            }
            index += 1
        }
    }
}
