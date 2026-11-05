import AppKit
import SwiftUI

/// The focused viewer's menu-exposable actions (C3b scope 1). `MacViewerPane`
/// publishes this via `.focusedSceneValue` so the single, shared menu bar drives
/// whichever library window is key, and each window drives its own document. The
/// closures capture that window's zoom controller and exporter; `isDocumentLoaded`
/// gates the menu items.
struct ViewerActions {
    var isDocumentLoaded: Bool
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fit: () -> Void
    var actualSize: () -> Void
    var exportPNG: () -> Void
    var exportPDF: () -> Void
    var shareFile: () -> Void
    var sharePNG: () -> Void
    var sharePDF: () -> Void
}

extension FocusedValues {
    /// The key window's viewer actions, or `nil` when no library window is focused
    /// (menu items then read as disabled).
    @Entry var viewerActions: ViewerActions?
}

/// The File menu (C3b scope 2): Open…, the Open Recent submenu, and the Export /
/// Share group. New Window (⌘N) and the default File items come from the primary
/// `WindowGroup`; these add to them.
struct FileMenuCommands: Commands {
    let store: RecentsStore
    let coordinator: OpenCoordinator
    @FocusedValue(\.viewerActions) private var actions

    private var noDocument: Bool { actions?.isDocumentLoaded != true }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                coordinator.presentOpenPanel(store: store)
            }
            .keyboardShortcut("o", modifiers: .command)

            OpenRecentMenu(store: store, coordinator: coordinator)
        }

        // Export lives at the standard File ▸ import/export anchor. The Share
        // submenu routes to the same per-window exporter as the toolbar's Share.
        CommandGroup(replacing: .importExport) {
            Button("Export as PNG…") { actions?.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(noDocument)
            Button("Export as PDF…") { actions?.exportPDF() }
                .disabled(noDocument)

            Divider()

            Menu("Share") {
                Button("Share File") { actions?.shareFile() }
                Button("Share as PNG") { actions?.sharePNG() }
                Button("Share as PDF") { actions?.sharePDF() }
            }
            .disabled(noDocument)
        }
    }
}

/// The View menu's zoom group (C3b scope 2). Zoom In owns ⌘+ as its shown
/// accelerator; ⌘= is registered view-side in `MacViewerPane`, because a US
/// keyboard sends "=" unshifted and one menu item can show only one shortcut.
struct ViewMenuCommands: Commands {
    @FocusedValue(\.viewerActions) private var actions

    private var noDocument: Bool { actions?.isDocumentLoaded != true }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(noDocument)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(noDocument)
            Button("Actual Size") { actions?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(noDocument)
            Button("Zoom to Fit") { actions?.fit() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(noDocument)
        }
    }
}

/// The Open Recent submenu, built from the store's recent files (the newest ten),
/// plus Clear Menu. A `View` inside the File `CommandGroup`; reading `store.entries`
/// here makes the menu track the store through Observation.
struct OpenRecentMenu: View {
    let store: RecentsStore
    let coordinator: OpenCoordinator

    var body: some View {
        Menu("Open Recent") {
            ForEach(OpenRecentList.items(from: store.entries)) { entry in
                Button(entry.displayName) {
                    coordinator.selectInFront(entry.id)
                }
            }
            Divider()
            Button("Clear Menu") {
                MacRecentsConfirmation.confirmClear(store: store)
            }
        }
        .disabled(store.entries.isEmpty)
    }
}

/// The shared "clear the recent files" confirmation (C3b scope 2, 6). One `NSAlert`
/// so the Open Recent menu's Clear Menu and the macOS Settings' Clear Recents ask
/// the same question before calling the store's existing `clear()`.
enum MacRecentsConfirmation {
    @MainActor
    static func confirmClear(store: RecentsStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Recents?"
        alert.informativeText = "This removes every file from your recent list. The files themselves are not deleted."
        alert.addButton(withTitle: "Clear Recents")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }
}
