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
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("EMFY-F3D \(message)\n".utf8))
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
