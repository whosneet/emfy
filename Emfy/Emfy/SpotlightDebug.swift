#if DEBUG && os(macOS)
import AppKit
import CoreSpotlight
import EMFRender
import Foundation
import SwiftUI

// DEBUG-only F3d verification helpers (macOS): a real Core Spotlight round-trip (index a file,
// query CSSearchQuery, log the hit count) and an offscreen stand-in of the viewer context menu
// (a live NSMenu can't be captured). Compiled out of Release entirely.

enum SpotlightDebug {
    /// Also mirror every line to a file in the container temp, so an `open`-launched run
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

    // MARK: - Real Spotlight check (-EmfyDebugSpotlightCheck <path>)

    @MainActor
    static func runSpotlightCheckIfRequested(settings: EmfySettings) async {
        guard let path = EditorDebugLaunch.spotlightCheckPath else { return }
        await performCheck(path: path, query: EditorDebugLaunch.spotlightCheckQuery, settings: settings)
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    @MainActor
    private static func performCheck(path: String, query: String, settings: EmfySettings) async {
        let id = "spotlight-check-\(UUID().uuidString)"
        let fileName = (path as NSString).lastPathComponent
        // The sandboxed Debug app can't read corpus/ directly; copy into the container temp
        // first (the same path -EmfyDebugOpen uses), then read the copy.
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

    // MARK: - Translate menu stand-in (-EmfyDebugTranslateMenu, screenshot g)

    @MainActor
    static func runTranslateMenuIfRequested() async {
        guard EditorDebugLaunch.translateMenu, let base = EditorDebugLaunch.screenshotBase else { return }
        try? await Task.sleep(for: .milliseconds(1200))   // let SwiftUI build the menu bar
        auditEditMenu()
        _ = captureStandIn(to: base + "-g-translate-menu.png")
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    @MainActor
    private static func auditEditMenu() {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" || $0.title == "Edit" })?.submenu else {
            log("translate-menu: <no Edit menu>"); return
        }
        editMenu.update()
        let hasTranslate = editMenu.items.contains { $0.title.hasPrefix("Translate") }
        log("translate-menu: Edit menu has Translate… = \(hasTranslate)")
    }

    @MainActor
    private static func captureStandIn(to path: String) -> Bool {
        let host = NSHostingView(rootView: TranslateMenuStandIn())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Viewer menu"
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let view = window.contentView else { return false }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// A stand-in rendering of the viewer context menu's items (F3d g), since a live NSMenu can't
/// be captured. The real items are MacViewerPane's `translateMenuItem` (context menu) and the
/// Edit menu's Copy All Text / Translate… / Find; this reproduces their label + symbol.
private struct TranslateMenuStandIn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Copy All Text", "text.quote")
            Divider().padding(.vertical, 4)
            row("Translate…", "translate")
            Divider().padding(.vertical, 4)
            row("Find…", "magnifyingglass")
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.background)
    }

    private func row(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.body)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
    }
}
#endif
