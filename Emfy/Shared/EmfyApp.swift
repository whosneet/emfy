import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Emfy — one multiplatform viewer for EMF / WMF files and their gzip-wrapped
/// .emz / .wmz forms, on macOS 14+ and iOS/iPadOS 17+ (v3-plan §9, §11). This one
/// `@main` App replaces the two platform-filtered apps retired in C3a slice 2.
///
/// The primary scene is a data-driven `WindowGroup`: `openWindow(id: "library",
/// value:)` opens a window already showing a given entry ("Open in New Window"),
/// and the default File ▸ New Window (⌘N) opens an empty one. Each window hosts a
/// `LibraryWindow` with its own selection and `DocumentSession` (v3-plan §11.2).
@main
struct EmfyApp: App {
    @State private var store = RecentsStore.shared
    @State private var coordinator = OpenCoordinator.shared

    var body: some Scene {
        WindowGroup(id: "library", for: LibraryWindowValue.self) { $value in
            RootView(initialSelection: value?.entryID)
                .environment(store)
                .environment(coordinator)
                #if os(macOS)
                // Deliver Finder opens to an existing window instead of spawning a
                // new one, while still creating a window on a cold launch (v3-plan
                // §9.1). Applied to the root view (not the scene), per Apple.
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
                #endif
        }
        #if os(macOS)
        // Keep the standard sidebar and inspector View-menu toggles and shortcuts
        // (Axiom swiftui-differences.md). The full menu redesign is C3b; File ▸ Open
        // is added here so the app still opens files from a menu now that
        // DocumentGroup is gone.
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    coordinator.presentOpenPanel(store: store)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            EmfyCommands()
        }
        #endif

        #if os(macOS)
        // Single-instance auxiliary windows the Help menu raises by id. They opt
        // out of external events too, so an incoming file never falls through to
        // one of them once the library group has opted out (v3-plan §9.1).
        Window("What's New in Emfy", id: "whats-new") {
            WhatsNewView()
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentSize)

        Window("Emfy Changelog", id: "changelog") {
            ChangelogView()
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 460, height: 600)
        #endif
    }
}

/// The per-window root. On iOS DEBUG builds it still hosts the Quick Look probe
/// surfaces (I4 gates b/c) when launched with their environment flags; otherwise,
/// and always on macOS, it is the library window.
private struct RootView: View {
    let initialSelection: UUID?

    var body: some View {
        #if os(iOS) && DEBUG
        if let probeIndex = QuickLookProbeView.requestedStartIndex {
            QuickLookProbeView(startIndex: probeIndex)
                .ignoresSafeArea()
        } else if QuickLookThumbnailProbeView.isRequested {
            QuickLookThumbnailProbeView()
        } else {
            LibraryWindow(initialSelection: initialSelection)
        }
        #else
        LibraryWindow(initialSelection: initialSelection)
        #endif
    }
}
