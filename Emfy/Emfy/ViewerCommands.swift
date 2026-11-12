import AppKit
import SwiftUI

// `ViewerActions` and the `FocusedValues.viewerActions` entry moved to
// `Shared/ViewerActions.swift` so iOS can publish and read them too (C4b K1). The
// Mac menus below are unchanged; the `NSAlert`/`NSOpenPanel` confirmation stays
// Mac-only here.

/// The File menu (C3b scope 2): Open…, the Open Recent submenu, and the Export /
/// Share group. New Window (⌘N) and the default File items come from the primary
/// `WindowGroup`; these add to them.
struct FileMenuCommands: Commands {
    let store: RecentsStore
    let coordinator: OpenCoordinator
    @FocusedValue(\.viewerActions) private var actions
    @FocusedValue(\.newDrawingAction) private var newDrawing
    @Environment(\.openWindow) private var openWindow

    private var noDocument: Bool { actions?.isDocumentLoaded != true }

    var body: some Commands {
        // New Drawing… (⌘N) opens the presets sheet in the focused window (E3a); New
        // Window moves to ⇧⌘N, so ⌘N creates a drawing rather than an empty window.
        CommandGroup(replacing: .newItem) {
            Button("New Drawing…") { newDrawing?.present() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newDrawing == nil)
            Button("New Window") { openWindow(id: "library") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Open…") {
                coordinator.presentOpenPanel(
                    store: store, openWindow: openWindow,
                    inNewWindow: EmfySettings.shared.openFilesIn == .newWindow
                )
            }
            .keyboardShortcut("o", modifiers: .command)

            OpenRecentMenu(store: store, coordinator: coordinator)
        }

        // Save in place and Revert to Opened Version (E2a). Save owns ⌘S; both read as
        // disabled until there are unsaved edits / an opened-version snapshot exists.
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions?.save?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.save == nil)
            Button("Revert to Opened Version") { actions?.revertToOpenedVersion?() }
                .disabled(actions?.revertToOpenedVersion == nil)
        }

        // Export lives at the standard File ▸ import/export anchor. The Share
        // submenu routes to the same per-window exporter as the toolbar's Share.
        CommandGroup(replacing: .importExport) {
            // ⇧⌘E exports in the default format (S1a-6 Export › Default export
            // format). The explicit per-format items stay below it.
            Button("Export…") {
                switch EmfySettings.shared.defaultExportFormat {
                case .png: actions?.exportPNG()
                case .pdf: actions?.exportPDF()
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(noDocument)

            Button("Export as PNG…") { actions?.exportPNG() }
                .disabled(noDocument)
            Button("Export as PDF…") { actions?.exportPDF() }
                .disabled(noDocument)
            Button("Export as SVG…") { actions?.exportSVG() }
                .disabled(noDocument)

            Divider()

            Menu("Share") {
                Button("Share File") { actions?.shareFile() }
                Button("Share as PNG") { actions?.sharePNG() }
                Button("Share as PDF") { actions?.sharePDF() }
                Button("Share as SVG") { actions?.shareSVG() }
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

/// The Edit menu's selection commands (E2b, design call 7), present only while a
/// document is in edit mode. Select All owns ⌘A; Deselect owns ⇧⌘A. Both read as
/// disabled (`nil` action) when not editing / nothing is selected.
struct EditMenuCommands: Commands {
    @FocusedValue(\.viewerActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            // Delete the selection (E2c). No key equivalent: the canvas handles the
            // bare Delete/Backspace key itself (so a focused text field keeps its own
            // backspace); this item is for discoverability and when the canvas isn't
            // focused.
            Button("Delete") { actions?.deleteSelection?() }
                .disabled(actions?.deleteSelection == nil)
            Divider()
            Button("Select All") { actions?.selectAllElements?() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(actions?.selectAllElements == nil)
            Button("Deselect All") { actions?.deselectElements?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions?.deselectElements == nil)
            Divider()
            // Insert ▸ Image… (E3c). ⇧⌘I is free; it opens an images-only NSOpenPanel.
            Button("Insert Image…") { actions?.insertImage?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.insertImage == nil)
        }
    }
}

/// The Open Recent submenu, built from the store's recent files (the newest ten),
/// plus Clear Menu. A `View` inside the File `CommandGroup`; reading `store.entries`
/// here makes the menu track the store through Observation.
struct OpenRecentMenu: View {
    let store: RecentsStore
    let coordinator: OpenCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Session-private opens are kept out of the Open Recent menu and its enabled
        // state, so a Private-mode file name never surfaces there (S-M2).
        let recents = OpenRecentList.items(from: store.nonPrivateEntries)
        Menu("Open Recent") {
            ForEach(recents) { entry in
                Button(entry.displayName) {
                    // Route to the front window, or open one when none exists (M5);
                    // the "Open files in → New window" setting forces a new one (S1a-4b).
                    coordinator.route(
                        entry.id, openWindow: openWindow,
                        inNewWindow: EmfySettings.shared.openFilesIn == .newWindow
                    )
                }
            }
            Divider()
            Button("Clear Menu") {
                MacRecentsConfirmation.confirmClear(store: store)
            }
        }
        .disabled(recents.isEmpty)
    }
}

/// The shared "clear the recent files" confirmation (C3b scope 2, 6; C4a H3). One
/// `NSAlert` so the Open Recent menu's Clear Menu and the macOS Settings' Clear
/// Recents ask the same question, with the same `RemovalConfirmation` wording. When
/// received files are present it offers "Save a Copy…", which writes copies into a
/// chosen folder before clearing (the only copies Emfy holds).
enum MacRecentsConfirmation {
    @MainActor
    static func confirmClear(store: RecentsStore) {
        // Count only non-private entries, so the confirmation never reveals that a
        // Private-mode file was opened — and never offers to Save a Copy of one (S-M2).
        let visible = store.nonPrivateEntries
        let received = visible.filter { $0.importedFileName != nil }.count
        let plan = RemovalConfirmation.plan(scope: .clear, receivedCount: received, totalCount: visible.count)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = plan.title
        alert.informativeText = plan.message
        if plan.offersSaveCopy { alert.addButton(withTitle: "Save a Copy…") }
        alert.addButton(withTitle: plan.destructiveTitle)
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if plan.offersSaveCopy {
            switch response {
            case .alertFirstButtonReturn: saveCopiesThenClear(store: store)
            case .alertSecondButtonReturn: store.clear()
            default: break
            }
        } else if response == .alertFirstButtonReturn {
            store.clear()
        }
    }

    /// Lets the user pick a folder, writes copies of every received file there under
    /// its real name, then clears — only if at least one copy was written.
    @MainActor
    private static func saveCopiesThenClear(store: RecentsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Copies"
        panel.message = "Choose a folder to save copies of files Emfy received from other apps."
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        // Never write a copy of a session-private received file (S-M2).
        let received = store.nonPrivateEntries.filter { $0.importedFileName != nil }
        Task { @MainActor in
            var savedAny = false
            for entry in received {
                guard let data = try? await store.resolveData(for: entry) else { continue }
                let destination = uniqueDestination(in: directory, name: entry.displayName)
                if (try? data.write(to: destination)) != nil { savedAny = true }
            }
            if savedAny { store.clear() }
        }
    }

    /// A non-colliding destination URL in `directory` for `name`.
    private static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }
}
