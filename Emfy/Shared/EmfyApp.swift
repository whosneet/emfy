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
    // The S1a settings store, injected into every window on both platforms.
    @State private var settings = EmfySettings.shared

    init() {
        // Sync the settings-driven cap and Private mode into the shared store before
        // any scene appears or a cold-launch open arrives (S1a-5 review): a Finder /
        // Files open at launch, and a windowless Settings change on the Mac, must
        // honour them even with no library window open. The per-window sync in
        // LibraryWindow stays as an idempotent backstop.
        let settings = EmfySettings.shared
        RecentsStore.shared.capLimit = settings.recentsToKeep.count
        RecentsStore.shared.setPrivate(settings.privateMode)
    }

    var body: some Scene {
        WindowGroup(id: "library", for: LibraryWindowValue.self) { $value in
            RootView(initialSelection: value?.entryID)
                .environment(store)
                .environment(coordinator)
                .environment(settings)
                #if os(macOS)
                // Deliver Finder opens to an existing window instead of spawning a
                // new one, while still creating a window on a cold launch (v3-plan
                // §9.1). Applied to the root view (not the scene), per Apple.
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
                #endif
        }
        #if os(macOS)
        // The full Mac menu bar (C3b scope 2): the standard sidebar/inspector View
        // toggles, File (Open…, Open Recent, Export, Share), View (zoom), and Help.
        // The menu bar owns the keyboard shortcuts; the toolbar buttons carry none.
        .commands {
            AboutCommands()
            SidebarCommands()
            InspectorCommands()
            FileMenuCommands(store: store, coordinator: coordinator)
            ViewMenuCommands()
            EmfyCommands()
        }
        #else
        // The iPad/iPhone View menu: the viewer's zoom group, the controls toggle,
        // and Info, routed through the menu bar so they fire without the detail
        // holding focus (C4b K1).
        .commands {
            ViewerCommandsIOS()
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

        // The Settings scene (⌘,) — Library and Help & diagnostics in C3b (scope 6).
        // The store is injected so Clear Recents can read and clear it.
        Settings {
            SettingsView()
                .environment(store)
                .environment(settings)
        }
        #endif
    }
}

/// The per-window root. On iOS DEBUG builds it still hosts the Quick Look probe
/// surfaces (I4 gates b/c) when launched with their environment flags; otherwise,
/// and always on macOS, it is the library window.
private struct RootView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(EmfySettings.self) private var settings
    #endif
    let initialSelection: UUID?

    var body: some View {
        content
        #if os(macOS)
            // Open the What's New window once per installed version, once per launch
            // (C3b scope 7), gated by the "Show What's New after updates" setting
            // (S1a-5). The decision and the once-per-launch guard are shared; the
            // first library window to appear claims the presentation.
            .onAppear {
                if WhatsNewPresenter.claimLaunchPresentation(enabled: settings.showWhatsNewAfterUpdates) {
                    openWindow(id: "whats-new")
                }
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
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
