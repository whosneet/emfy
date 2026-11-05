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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The entry a data-driven "Open in New Window" asked for, or `nil` for an
    /// empty window (⌘N). Applied once the store has loaded.
    let initialSelection: UUID?

    @State private var model = LibraryWindowModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    // Scene-scoped so each window (iOS multi-scene, Mac tabs/windows) restores its
    // own selection rather than sharing one.
    @SceneStorage("library.selection") private var storedSelection: String?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(selection: $model.selection, isCompact: isCompactWindow)
                #if os(iOS)
                // Compact width collapses the split view to this stack; push the
                // viewer explicitly when the grid sets a selection. Inert at
                // regular width, where the detail column shows instead.
                .navigationDestination(item: $model.selection) { id in
                    ViewerDetail(entryID: id, onRemove: { model.selection = nil })
                        .id(id)
                }
                #endif
        } detail: {
            detailColumn
        }
        .task {
            await store.loadIfNeeded()
            applyInitialSelection()
        }
        .onChange(of: model.selection) { _, id in
            storedSelection = id?.uuidString
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
            WindowFrontReporter {
                coordinator.markFront(windowID: model.windowID)
            }
        )
        #endif
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
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.richtext",
                description: Text("Choose a file from the sidebar, or open one.")
            )
        }
    }

    // MARK: - Selection restoration

    /// Honours a window opened on a specific entry, else restores the window's last
    /// selection — each only when the entry still exists.
    private func applyInitialSelection() {
        if let initialSelection, store.entry(id: initialSelection) != nil {
            model.selection = initialSelection
        } else if let stored = storedSelection,
                  let id = UUID(uuidString: stored),
                  store.entry(id: id) != nil {
            model.selection = id
        }
    }

    /// Imports a file arriving from Finder / Files / Mail / Messages and shows it in
    /// the front window (v3-plan §9.1). `handlesExternalEvents(preferring:allowing:)`
    /// delivers the open to an existing window (macOS) or the active scene (iOS), so
    /// this simply sets the selection — no spawned-window cleanup needed.
    private func openExternal(_ url: URL) async {
        await store.loadIfNeeded()
        guard let id = await store.handleOpenedURL(url) else { return }
        if model.selection != id { model.selection = id }
    }
}

/// The detail: a per-open `DocumentSession` plus the platform viewer. Owning the
/// session here (rather than in `LibraryWindow`) means the same view serves both
/// the regular-width detail column and the compact `navigationDestination` push,
/// with exactly one session per shown file (v3-plan §11.2).
struct ViewerDetail: View {
    @Environment(RecentsStore.self) private var store
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
            let newSession = DocumentSession(entryID: entryID, store: store)
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
