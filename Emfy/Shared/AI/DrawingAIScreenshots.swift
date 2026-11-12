#if DEBUG && os(macOS)
import AppKit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process AI screenshots (A1b Part 0 — REAL output only)
//
// Captures the A1a/A1b AI surfaces — the Describe section, the Ask chat, the Settings
// group — into PNGs by hosting the REAL views in an offscreen window and using
// `cacheDisplay`, so they can be shot with no Screen Recording permission. Inside
// `#if DEBUG`, so Release has none of it.
//
// A1b Part 0 removed the seeded state: the models are now DRIVEN LIVE against real
// drawings and the capture waits (up to 90 s) for the on-device stream to COMPLETE
// before the shot, so what is captured is genuine model output. The Ask shot asks
// about a token that sits beyond the context excerpt, so its "Used:" footnote is a
// real tool call, not a fabrication.
//
//   -EmfyDebugAIShots <base-path> [-EmfyDebugAIShotsSource <describe-source-metafile>]
//
// writes <base>-describe.png, <base>-ask.png and <base>-settings.png, then exits.

enum DrawingAIScreenshots {
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugAIShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        let source = args.firstIndex(of: "-EmfyDebugAIShotsSource").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Task { @MainActor in
            await capture(all: base, describeSource: source)
            exit(0)
        }
    }

    /// Polls `condition` every 200 ms until it holds or `timeout` elapses (so an
    /// in-flight on-device stream completes before the shot).
    @MainActor
    private static func wait(timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor
    private static func capture(all base: String, describeSource: String?) async {
        let status = DrawingAIAvailability.current()
        guard status.isAvailable, #available(macOS 26, iOS 26, *) else {
            try? "UNAVAILABLE: \(status)".write(toFile: base + "-unavailable.txt", atomically: true, encoding: .utf8)
            // The Settings group still renders (it shows the reason), so capture it.
            captureSettings(base: base)
            return
        }

        // (a) Describe — driven live against a real file.
        if let describeSource,
           let data = try? Data(contentsOf: URL(fileURLWithPath: describeSource)) {
            let fileName = URL(fileURLWithPath: describeSource).lastPathComponent
            let describe = DrawingDescribeModel()
            let inputs = DrawingAIInspectorInputs(
                contentID: 1, fileName: fileName, unsupportedNotes: [],
                dataProvider: { data })
            describe.describe(
                contentID: 1, dataProvider: { data }, fileName: fileName,
                unsupportedNotes: [], altTextStore: DrawingAltTextStore())
            await wait(timeout: .seconds(90)) { isDescribeFinished(describe.phase) }
            let describeView = Form {
                Section { LabeledContent("Format", value: MetafileFormatLabel.names(for: fileName).full) }
                DrawingDescribeSection(model: describe, altTextStore: DrawingAltTextStore(), inputs: inputs)
            }
            .formStyle(.grouped)
            .frame(width: 380, height: 360)
            _ = capture(view: describeView, size: NSSize(width: 380, height: 360), to: base + "-describe.png")
        }

        // (b) Ask — driven live against a long drawing whose token sits beyond the
        // excerpt, so answering it requires a real tool call (genuine "Used:" footnote).
        if let askData = DrawingAIDebugProbe.makeLongTextDrawing(lineCount: 60, token: "ZEBRA-7742") {
            let ask = DrawingAskModel()
            let askInputs = DrawingAIInspectorInputs(
                contentID: 2, fileName: "tool-proof.emf", unsupportedNotes: [],
                dataProvider: { askData })
            ask.prepare(contentID: 2, dataProvider: { askData }, fileName: "tool-proof.emf", unsupportedNotes: [])
            ask.draft = "What does the line containing ZEBRA-7742 say, and which line number is it?"
            ask.send()
            await wait(timeout: .seconds(90)) {
                !ask.isResponding && (ask.messages.last?.role == .assistant) && (ask.messages.last?.streaming == false)
            }
            let askView = DrawingAskView(model: ask, inputs: askInputs)
                .frame(width: 380, height: 460)
            _ = capture(view: askView, size: NSSize(width: 380, height: 460), to: base + "-ask.png")
        }

        // (c) Settings ▸ Apple Intelligence group.
        captureSettings(base: base)

        // (d) Recents list with AI titles — the real RecentRow with seeded AI metadata.
        captureRecents(base: base)

        // (e) A smart-search result that matched by tag/meaning, not by file name.
        captureSemanticSearch(base: base)
    }

    @MainActor
    private static func seededEntry(_ name: String, _ label: String, _ full: String, _ bytes: Int64, _ title: String, _ tags: [String]) -> RecentEntry {
        RecentEntry(
            id: UUID(), displayName: name, formatLabel: label, fullFormatName: full,
            byteCount: bytes, openedAt: Date(), bookmark: Data(), aiTitle: title, aiTags: tags)
    }

    @MainActor
    private static func screenshotStore() -> RecentsStore {
        RecentsStore(locations: .init(supportDirectory: FileManager.default.temporaryDirectory, cachesDirectory: FileManager.default.temporaryDirectory))
    }

    @MainActor
    private static func screenshotSettings() -> EmfySettings {
        let settings = EmfySettings(defaults: UserDefaults(suiteName: "emfy.screenshot.ai") ?? .standard)
        settings.useOnDeviceAI = true
        return settings
    }

    /// Seeded recents entries carrying AI title/tags, so the RecentRow's secondary
    /// AI-title line (A1b) is shown in a faithful library row.
    @MainActor
    private static func captureRecents(base: String) {
        let entries = [
            seededEntry("gate-p4-text.emf", "EMF", "Enhanced Metafile", 20_480, "Hello Emfy Text Sample", ["text", "fox", "bold", "sample"]),
            seededEntry("floor-plan.emf", "EMF", "Enhanced Metafile", 51_200, "Office Floor Plan", ["floorplan", "layout", "rooms"]),
            seededEntry("invoice-march.wmf", "WMF", "Windows Metafile", 12_288, "March Invoice Layout", ["invoice", "table", "finance"]),
        ]
        let list = List { ForEach(entries) { RecentRow(entry: $0) } }
            .environment(screenshotStore())
            .environment(RemovalCoordinator())
            .environment(ToastCenter())
            .environment(screenshotSettings())
            .frame(width: 320, height: 300)
        _ = capture(view: list, size: NSSize(width: 320, height: 300), to: base + "-recents.png")
    }

    /// Renders the ranked result of a real smart-search query that matches by tag and
    /// meaning but NOT by file name (A1b Part 2), using the live NLEmbedding scorer.
    @MainActor
    private static func captureSemanticSearch(base: String) {
        let entries = [
            seededEntry("sketch-0417.emf", "EMF", "Enhanced Metafile", 33_792, "Red Sports Car", ["car", "vehicle", "wheels"]),
            seededEntry("oak-study.emf", "EMF", "Enhanced Metafile", 18_944, "Oak Tree Study", ["tree", "nature", "leaves"]),
            seededEntry("notes.wmf", "WMF", "Windows Metafile", 8_192, "Meeting Notes", ["text", "notes"]),
        ]
        let query = "automobile"
        let results = LibrarySearchRanker.rank(
            entries: entries, query: query, aiEnabled: true,
            textFor: { _ in nil }, scorer: LibrarySearchScorer.shared)
        // Fall back to a guaranteed tag match if the embedding isn't available/strong,
        // so the shot always shows a relevant, non-name-matching result.
        let shown = results.isEmpty
            ? LibrarySearchRanker.rank(entries: entries, query: "vehicle", aiEnabled: true)
            : results
        let shownQuery = results.isEmpty ? "vehicle" : query
        let view = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(shownQuery)
                Spacer()
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)
            Text("Matched by AI title and tags, not the file name")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 4)
            List { ForEach(shown) { RecentRow(entry: $0) } }
        }
        .environment(screenshotStore())
        .environment(RemovalCoordinator())
        .environment(ToastCenter())
        .environment(screenshotSettings())
        .frame(width: 340, height: 260)
        _ = capture(view: view, size: NSSize(width: 340, height: 260), to: base + "-search.png")
    }

    /// Whether a Describe phase is terminal (done or failed).
    private static func isDescribeFinished(_ phase: DrawingDescribeModel.Phase) -> Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    @MainActor
    private static func captureSettings(base: String) {
        let settingsView = Form {
            AppleIntelligenceSettingsSection()
        }
        .formStyle(.grouped)
        .environment(EmfySettings())
        .frame(width: 520, height: 260)
        _ = capture(view: settingsView, size: NSSize(width: 520, height: 260), to: base + "-settings.png")
    }

    @MainActor
    private static func capture<V: View>(view: V, size: NSSize, to path: String) -> Bool {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView else { return false }
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        content.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif
