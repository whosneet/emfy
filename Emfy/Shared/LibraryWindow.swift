import SwiftUI

/// One library window: a `NavigationSplitView` with a recents sidebar and a viewer
/// detail (v3-plan §9.1). On macOS and regular-width iPad it is a true multi-column
/// layout; on iPhone and narrow widths it collapses to the approved grid → viewer
/// push. Each window owns its selection and its `DocumentSession`, so multiple
/// windows never share viewer state (v3-plan §11.2).
///
/// Compact-width push: a `NavigationSplitView` only auto-pushes the detail when the
/// sidebar is a `List(selection:)`. The compact sidebar is the approved grid, so
/// the push is driven explicitly by a `navigationDestination` on the sidebar; at
/// regular width that destination is inert and the detail column shows instead.
struct LibraryWindow: View {
    @Environment(RecentsStore.self) private var store
    @Environment(OpenCoordinator.self) private var coordinator
    @Environment(EmfySettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The entry a data-driven "Open in New Window" asked for, or `nil` for an
    /// empty window (⌘N). Applied once the store has loaded.
    let initialSelection: UUID?

    @State private var model = LibraryWindowModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// One toast surface and one removal coordinator per window, injected so the
    /// sidebar, the viewer and the inspector all post to the same surface (C4a H3,
    /// H6/A2, M3).
    @State private var toastCenter = ToastCenter()
    @State private var removal = RemovalCoordinator()
    /// Drives the "No File Selected" detail's Open… button (C4a L1).
    @State private var isImporting = false
    #if os(macOS)
    /// Whether this window is key, so the "couldn't open" alert shows only in the
    /// front window rather than every window or none (C4a M5).
    @State private var isKeyWindow = false
    #endif
    #if os(iOS)
    /// Drives the once-per-launch What's New sheet on iOS (C3b scope 7); hosted at
    /// the window level so it presents on both iPhone and iPad regardless of the
    /// sidebar variant.
    @State private var showLaunchWhatsNew = false
    #endif

    // Scene-scoped so each window (iOS multi-scene, Mac tabs/windows) restores its
    // own selection rather than sharing one.
    @SceneStorage("library.selection") private var storedSelection: String?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Inject the window's observable environment INSIDE each column, not as a
            // modifier on the whole split view. `NavigationSplitView` hosts its columns
            // in separate UIKit containers; the app-switcher snapshot re-lays those
            // column hosts out under an override orientation, and an `.environment`
            // applied outside the split view isn't yet bridged into them at that point,
            // so an `@Environment(Observable.self)` read force-unwraps nil and traps
            // (C1: EXC_BREAKPOINT in EnvironmentBox.update during the snapshot rotation).
            // Each column carrying its own copy keeps the reads valid through that pass.
            withLibraryEnvironment {
                LibrarySidebar(selection: $model.selection, isCompact: isCompactWindow)
                    #if os(iOS)
                    // Compact width collapses the split view to this stack; push the
                    // viewer explicitly when the grid sets a selection. Inert at
                    // regular width, where the detail column shows instead.
                    .navigationDestination(item: $model.selection) { id in
                        withLibraryEnvironment {
                            ViewerDetail(entryID: id, onRemove: { model.selection = nil })
                                .id(id)
                        }
                    }
                    #endif
            }
        } detail: {
            withLibraryEnvironment { detailColumn }
        }
        .environment(toastCenter)
        .environment(removal)
        .toastOverlay(toastCenter)
        .recentsRemoval(removal, store: store, toast: toastCenter)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: MetafileTypes.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { if let id = await store.handleOpenedURL(url) { model.selection = id } }
            }
        }
        // Host the "couldn't open" alert at the window (C4a M5): visible with the
        // sidebar collapsed or a compact viewer pushed, and — on macOS — only in the
        // key window, so several windows don't each raise it.
        .alert(
            "Couldn’t open file",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil && errorAlertAllowed },
                set: { if !$0 { store.lastErrorMessage = nil } }
            ),
            presenting: store.lastErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { store.lastErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .task {
            await store.loadIfNeeded()
            // Sync the settings-driven cap and Private mode into the store before the
            // first open can add anything (S1a-5).
            store.capLimit = settings.recentsToKeep.count
            store.setPrivate(settings.privateMode)
            #if DEBUG
            // UI-test seeding (DEBUG only): SIMCTL_CHILD_EMFY_SEED_RECEIVED=<n>.
            if let raw = ProcessInfo.processInfo.environment["EMFY_SEED_RECEIVED"], let n = Int(raw), n > 0 {
                await store.seedReceivedForUITesting(count: n)
            }
            // Seed specific host files as received entries (DEBUG only):
            // SIMCTL_CHILD_EMFY_SEED_FILES=<path1:path2:…> — used for screenshots.
            if let files = ProcessInfo.processInfo.environment["EMFY_SEED_FILES"], !files.isEmpty {
                await store.seedReceivedFilesForUITesting(paths: files.split(separator: ":").map(String.init))
            }
            #endif
            applyInitialSelection()
            #if os(iOS)
            // One scene, once per version, once per launch (C3b scope 7), gated by the
            // "Show What's New after updates" setting (S1a-5).
            if WhatsNewPresenter.claimLaunchPresentation(enabled: settings.showWhatsNewAfterUpdates) {
                showLaunchWhatsNew = true
            }
            #endif
        }
        .onAppear { toastCenter.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in toastCenter.reduceMotion = newValue }
        // Reconcile selection when the shown entry is removed — here or in another
        // window, via Clear Recents or a prune — so the viewer never orphans (C4a H8).
        .onChange(of: store.entries) { _, _ in
            if let id = model.selection, store.entry(id: id) == nil {
                model.selection = nil
            }
        }
        .onChange(of: model.selection) { _, id in
            // Never persist the selection of a session-private entry into scene
            // restoration, so a Private-mode file isn't re-selected on relaunch (S-L3).
            if let id, store.isSessionPrivate(id) {
                storedSelection = nil
            } else {
                storedSelection = id?.uuidString
            }
        }
        // Keep the store's Private mode in step with the setting (S1a-5): turning it
        // off drops this launch's Private entries; the persisted history is untouched.
        .onChange(of: settings.privateMode) { _, on in
            store.setPrivate(on)
        }
        // External opens (Finder, Files, Mail, Messages) land in the front window.
        // SwiftUI spawns a window for the file event and delivers the URL here; on
        // macOS, if another window already exists this is a duplicate — route the
        // file into the existing front window and close this one; otherwise (a cold
        // launch) show it here. iOS shows it in this active scene (v3-plan §9.1).
        .onOpenURL { url in
            Task { await openExternal(url) }
        }
        #if os(iOS)
        // A window opened by "Open in New Window" (UIWindowScene.ActivationAction)
        // carries the entry to show in its user activity (v3-plan §9.1).
        .onContinueUserActivity(WindowOpenActivity.type) { activity in
            if let id = WindowOpenActivity.entryID(from: activity), store.entry(id: id) != nil {
                model.selection = id
            }
        }
        .sheet(isPresented: $showLaunchWhatsNew) {
            InfoSheet(title: "What's New") { WhatsNewView() }
        }
        #endif
        #if os(macOS)
        .onAppear {
            // The coordinator's stored selector holds `model` strongly, matching this
            // closure's own capture. It is released on `onDisappear` via `unregister`,
            // and `model` never references the coordinator, so there is no cycle.
            coordinator.register(windowID: model.windowID) { entryID in
                model.selection = entryID
            }
        }
        .onDisappear {
            coordinator.unregister(windowID: model.windowID)
        }
        .background(
            WindowFrontReporter { isKey in
                isKeyWindow = isKey
                if isKey { coordinator.markFront(windowID: model.windowID) }
            }
        )
        #endif
    }

    /// Re-injects every observable the window's columns, pushed viewers and sheets
    /// read, so each separately-hosted `NavigationSplitView` column (and the compact
    /// pushed viewer) carries its own copy rather than relying on an injection made
    /// outside the split view surviving the snapshot re-layout (C1).
    @ViewBuilder
    private func withLibraryEnvironment<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .environment(store)
            .environment(coordinator)
            .environment(settings)
            .environment(toastCenter)
            .environment(removal)
    }

    // MARK: - Detail column

    /// Whether this window is compact (iPhone, narrow). The window-level size class
    /// is the right signal for sidebar and detail layout — a split view's sidebar
    /// column reports compact even on a regular-width iPad.
    private var isCompactWindow: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var detailColumn: some View {
        // At compact width the viewer is pushed by the sidebar's
        // navigationDestination, so the detail column stays empty — only one
        // DocumentSession ever exists.
        if isCompactWindow {
            Color.clear
        } else {
            regularDetail
        }
    }

    @ViewBuilder
    private var regularDetail: some View {
        if let id = model.selection {
            ViewerDetail(entryID: id, onRemove: { model.selection = nil })
                .id(id)
        } else {
            // "No File Selected" now carries an Open… action, so the invitation to
            // "open one" is actionable (C4a L1).
            ContentUnavailableView {
                Label("No File Selected", systemImage: "doc.richtext")
            } description: {
                Text("Choose a file from the sidebar, or open one.")
            } actions: {
                Button("Open…") { isImporting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Whether this window may raise the "couldn't open" alert: only the key window
    /// on macOS, always on iOS (one active scene) — so several windows don't each
    /// show it and a windowless open still surfaces one (C4a M5).
    private var errorAlertAllowed: Bool {
        #if os(macOS)
        isKeyWindow
        #else
        true
        #endif
    }

    // MARK: - Selection restoration

    /// Honours a window opened on a specific entry, else restores the window's last
    /// selection — each only when the entry still exists.
    private func applyInitialSelection() {
        let storedID = storedSelection.flatMap { UUID(uuidString: $0) }
        // "Reopen last file at launch" off starts the window empty unless a specific
        // entry was requested (Open in New Window), which is always honoured (S1a-5).
        guard let id = LaunchSelection.restored(
            reopenLastFile: settings.reopenLastFileAtLaunch,
            requested: initialSelection,
            stored: storedID
        ), store.entry(id: id) != nil else { return }
        model.selection = id
    }

    /// Imports a file arriving from Finder / Files / Mail / Messages and shows it per
    /// the "Open files in" setting (S1a-4c). `handlesExternalEvents(preferring:allowing:)`
    /// delivers the open to the front window (macOS) or the active scene (iOS); in
    /// front-window mode this selects it here, and in new-window mode it opens a
    /// value-keyed library window, which SwiftUI brings forward if one already shows
    /// the file (the dedup). The setting is honoured only where a second window can
    /// exist (Mac, iPad); on the iPhone it's hidden and an external open fills the
    /// front window. An empty front window is always filled, so a cold-launch open
    /// never strands the window SwiftUI spawned for it.
    private func openExternal(_ url: URL) async {
        await store.loadIfNeeded()
        // Capture this (front) window's emptiness before the import, so a
        // cold-launch open fills the spawned empty window instead of spawning beside it.
        let frontWindowIsEmpty = model.selection == nil
        guard let id = await store.handleOpenedURL(url) else { return }
        let destination = OpenRouting.externalDestination(
            openInNewWindow: settings.openFilesIn == .newWindow,
            hasOpenWindow: true,
            frontWindowIsEmpty: frontWindowIsEmpty,
            // The front window already showing this file keeps it — no duplicate
            // window when the same file is reopened (S1a-5 carry-over).
            frontWindowShowsFile: model.selection == id,
            supportsMultipleWindows: supportsMultipleWindows
        )
        switch destination {
        case .frontWindow:
            if model.selection != id { model.selection = id }
        case .newWindow:
            openWindow(id: "library", value: LibraryWindowValue(entryID: id))
        }
    }
}

/// The detail: a per-open `DocumentSession` plus the platform viewer. Owning the
/// session here (rather than in `LibraryWindow`) means the same view serves both
/// the regular-width detail column and the compact `navigationDestination` push,
/// with exactly one session per shown file (v3-plan §11.2).
struct ViewerDetail: View {
    @Environment(RecentsStore.self) private var store
    @Environment(EmfySettings.self) private var settings
    let entryID: UUID
    /// Clears the window's selection when the file is removed from Recents.
    let onRemove: () -> Void

    @State private var session: DocumentSession?

    var body: some View {
        Group {
            if let session {
                #if os(macOS)
                MacViewerPane(session: session, onRemove: onRemove)
                #else
                MetafileViewerScreen(session: session, onRemove: onRemove)
                #endif
            } else {
                Color.clear
            }
        }
        .task(id: entryID) {
            // Seed the session with the current Rendering options so the opening
            // render already honours them; live changes flow through the viewer (S1b).
            let newSession = DocumentSession(entryID: entryID, store: store, options: settings.renderOptions)
            session = newSession
            await newSession.load()
        }
    }
}

/// Per-window state held by reference, so the open coordinator's stored selector
/// closure (which outlives a single `body` evaluation) always targets this
/// window's live selection. A plain `@State` can't be captured that way.
@MainActor
@Observable
final class LibraryWindowModel {
    let windowID = UUID()
    var selection: UUID?
}
