#if DEBUG
import CoreSpotlight
import EMFRender
import Foundation

// DEBUG-only F3d verification: a real Core Spotlight round-trip. It builds the production
// searchable item for a file (parse → text extract), indexes it into CSSearchableIndex,
// then polls CSSearchQuery for a word for up to 30 s and logs the hit count. Cross-platform
// so it can run where the Spotlight index is reachable (the iOS Simulator, or an installed
// Mac app). Compiled out of Release entirely.

enum SpotlightCheck {
    /// Also mirror every line to a file in the container temp, so an `open`/`simctl` run
    /// (whose stderr the shell can't capture) still reports the result.
    private static let resultFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("spotlight-check-result.txt")

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("EMFY-F3D \(message)\n".utf8))
        let line = "EMFY-F3D \(message)\n"
        if let handle = try? FileHandle(forWritingTo: resultFile) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: resultFile, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func runIfRequested(settings: EmfySettings) async {
        guard let path = EditorDebugLaunch.spotlightCheckPath else { return }
        await perform(path: path, query: EditorDebugLaunch.spotlightCheckQuery, settings: settings)
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    @MainActor
    private static func perform(path: String, query: String, settings: EmfySettings) async {
        let id = "spotlight-check-\(UUID().uuidString)"
        let fileName = (path as NSString).lastPathComponent
        // A sandboxed app can't read corpus/ directly; copy into the container temp first
        // (the same path -EmfyDebugOpen uses), then read the copy.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfySpotCheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let copyURL = tmpDir.appendingPathComponent(fileName)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copyURL)
        let data = (try? Data(contentsOf: copyURL)) ?? Data()
        log("spotlight-check: read \(data.count) bytes from \(fileName)")
        let options = settings.renderOptions
        let item: DrawingSpotlightItem? = await Task.detached(priority: .userInitiated) {
            guard let loaded = try? MetafileLoader.load(data, options: options) else { return nil }
            let observation = MetafileRenderer.observe(loaded.prepared, options: options)
            let runs = DrawingTextExtractor.extract(from: observation)
            return DrawingSpotlightBuilder.item(
                id: id, fileName: fileName,
                contentTypeIdentifier: SpotlightService.contentTypeIdentifier(for: fileName),
                drawingText: runs, pictureText: [])
        }.value
        guard let item else { log("spotlight-check: could not build an item from \(fileName)"); return }
        log("spotlight-check: indexing \(fileName) textContent=\"\(item.textContent.prefix(60))\"")
        guard CSSearchableIndex.isIndexingAvailable() else { log("spotlight-check: indexing unavailable"); return }
        do {
            try await CSSearchableIndex.default().indexSearchableItems([CoreSpotlightIndex.searchableItem(item)])
        } catch {
            log("spotlight-check: index error \(error.localizedDescription)")
        }
        // Index propagation lags; poll CSSearchQuery for up to 30 s.
        var hits = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            hits = await queryHitCount(for: query)
            if hits > 0 { break }
            try? await Task.sleep(for: .seconds(1))
        }
        log("spotlight-check: query=\"\(query)\" hits=\(hits)")
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
    }

    @MainActor
    private static func queryHitCount(for text: String) async -> Int {
        await withCheckedContinuation { continuation in
            let queryString = "textContent == \"*\(text)*\"cd || title == \"*\(text)*\"cd"
            let query = CSSearchQuery(queryString: queryString, attributes: ["title"])
            let counter = Counter()
            query.foundItemsHandler = { items in counter.add(items.count) }
            query.completionHandler = { _ in continuation.resume(returning: counter.value) }
            query.start()
        }
    }

    private final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func add(_ x: Int) { lock.lock(); n += x; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
#endif
