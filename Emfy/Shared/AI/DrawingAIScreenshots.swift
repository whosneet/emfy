#if DEBUG && os(macOS)
import AppKit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process AI screenshots (A1a verification)
//
// Captures the three A1a surfaces — the Describe section, the Ask chat, and the
// Settings Apple Intelligence group — into PNGs by hosting the REAL views (with
// seeded state) in an offscreen window and using `cacheDisplay`, so they can be
// shot with no Screen Recording permission. Inside `#if DEBUG`, so Release has
// none of it.
//
//   -EmfyDebugAIShots <base-path>
//
// writes <base>-describe.png, <base>-ask.png and <base>-settings.png, then exits.

enum DrawingAIScreenshots {
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugAIShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            capture(all: base)
            exit(0)
        }
    }

    @MainActor
    private static func capture(all base: String) {
        let inputs = DrawingAIInspectorInputs(
            contentID: 1, fileName: "gate-p4-text.emf", unsupportedNotes: [],
            dataProvider: { nil }
        )

        // (a) Describe section, seeded with a finished description.
        let describe = DrawingDescribeModel()
        describe.debugSeed(text: "This is an Enhanced Metafile drawing with a page size of 99.6 × 46.7 mm. Its main contents are text elements such as “Hello Emfy 123,” “Quick brown fox,” and “Bold small text.” The drawing is built from text-drawing and object records.")
        let describeView = Form {
            Section {
                LabeledContent("Format", value: "Enhanced Metafile")
                LabeledContent("Picture size", value: "398 × 187")
            }
            DrawingDescribeSection(model: describe, altTextStore: DrawingAltTextStore(), inputs: inputs)
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 360)
        _ = capture(view: describeView, size: NSSize(width: 360, height: 360), to: base + "-describe.png")

        // (b) Ask chat, seeded with a Q&A and the "Used:" footnote.
        let ask = DrawingAskModel()
        ask.debugSeed(messages: [
            .init(role: .user, text: "What text is in this drawing?"),
            .init(role: .assistant, text: "The drawing contains the following text:\n- Hello Emfy 123\n- Quick brown fox\n- Bold small text", toolsUsed: [DrawingAIToolName.findText, DrawingAIToolName.getDrawingInfo]),
        ], contentID: inputs.contentID)
        let askView = DrawingAskView(model: ask, inputs: inputs)
            .frame(width: 360, height: 420)
        _ = capture(view: askView, size: NSSize(width: 360, height: 420), to: base + "-ask.png")

        // (c) Settings ▸ Apple Intelligence group.
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
