#if DEBUG
import EMFParse
import EMFRender
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - DEBUG Send-to-AI screenshots (A3b)
//
// Captures the A3b surfaces with no Screen Recording permission: the viewer's Share
// menu (a faithful STAND-IN, since a SwiftUI Menu popover can't be opened without a
// tap — the same limitation F1 noted) and the REAL "Send to AI…" confirm sheet. On
// Mac it also builds the actual package for a given metafile and logs the generated
// summary verbatim, so the gate can read it.
//
//   macOS: -EmfyDebugAIShareShots <base-path> <metafile-path>
//          → <base>-menu.png, <base>-confirm.png, <base>-render.png, <base>-summary.txt,
//            and the summary printed to stdout, then exits.
//   iOS:   -EmfyDebugAIShare  → shows the stand-in menu + confirm sheet as the app root
//          for an external `simctl io booted screenshot`.
//
// Inside `#if DEBUG`, so Release has none of it.

enum AIShareScreenshots {

    /// A faithful stand-in of the viewer's Share menu, with "Send to AI…" after the
    /// export items. Used because an open Menu popover isn't programmatically capturable.
    static func menuStandIn() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Share File", "square.and.arrow.up")
            menuRow("Share as PNG", "photo")
            menuRow("Share as PDF", "doc.richtext")
            menuRow("Share as SVG", "doc.text")
            Divider().padding(.vertical, 4)
            menuRow(AISharePackage.menuTitle, "sparkles", highlighted: true)
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(20)
    }

    private static func menuRow(_ title: String, _ symbol: String, highlighted: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
    }

    /// The confirm sheet with the opt-in toggle off — the real A3b view.
    static func confirmSheet() -> some View {
        AIShareConfirmSheet(includeOriginal: .constant(false), onConfirm: {}, onCancel: {})
    }

    // MARK: iOS root

    static var iosRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-EmfyDebugAIShare")
    }

    /// The stand-in menu above the real confirm sheet, as the iOS app root for a
    /// Simulator screenshot (a Menu popover can't be auto-opened without a tap).
    static func iosScreen() -> some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Viewer ▸ Share").font(.headline)
                menuStandIn()
            }
            VStack(spacing: 6) {
                Text("Confirm sheet").font(.headline)
                confirmSheet()
                    .frame(maxWidth: 360)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }

    // MARK: macOS capture

    #if os(macOS)
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugAIShareShots"), i + 2 < args.count else { return }
        let base = args[i + 1]
        let metafilePath = args[i + 2]
        Task { @MainActor in
            capture(base: base, metafilePath: metafilePath)
            exit(0)
        }
    }

    @MainActor
    private static func capture(base: String, metafilePath: String) {
        _ = captureView(menuStandIn(), size: NSSize(width: 280, height: 220), to: base + "-menu.png")
        _ = captureView(confirmSheet(), size: NSSize(width: 360, height: 220), to: base + "-confirm.png")

        let fileName = URL(fileURLWithPath: metafilePath).lastPathComponent
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metafilePath)),
              let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            print("AIShareScreenshots: could not load \(metafilePath)")
            return
        }
        let observation = MetafileRenderer.observe(prepared)
        // No OCR: Send to AI only includes picture text already cached in the viewer; a
        // cold capture has none, matching the shipped rule.
        let allText = DrawingTextExtractor.copyAllText(DrawingTextExtractor.extract(from: observation))
        let recordCount = prepared.recordKinds.reduce(0) { $0 + $1.count }
        let package = AISharePackageProducer.make(
            resolvedData: data, fileName: fileName, allText: allText, recordCount: recordCount,
            source: .original, prepared: prepared, editedScene: nil,
            background: .white, options: .default, includeOriginal: false)
        print("=== AI SHARE SUMMARY for \(fileName) ===")
        print(package.summary)
        print("=== END AI SHARE SUMMARY ===")
        try? package.summary.write(toFile: base + "-summary.txt", atomically: true, encoding: .utf8)
        if let png = package.pngData { try? png.write(to: URL(fileURLWithPath: base + "-render.png")) }
    }

    @MainActor
    private static func captureView<V: View>(_ view: V, size: NSSize, to path: String) -> Bool {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView, content.bounds.width > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
    #endif
}
#endif
