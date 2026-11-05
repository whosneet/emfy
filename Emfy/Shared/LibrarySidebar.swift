import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The library window's leading column. At regular width (Mac, iPad) it is a
/// searchable list of recents with small thumbnails, selection, an Open… button,
/// and a per-row context menu. At compact width (iPhone, narrow) it is the
/// approved recents grid, which pushes the viewer by setting the same selection
/// (v3-plan §9.1). Both read the shared `RecentsStore` and respect `didLoad`.
struct LibrarySidebar: View {
    @Binding var selection: UUID?
    /// Whether the *window* is compact (iPhone, narrow). Passed from `LibraryWindow`
    /// rather than read here, because a split view's narrow sidebar column reports a
    /// compact size class even on a regular-width iPad — which would wrongly show the
    /// grid there. The window's own size class is the right signal.
    var isCompact: Bool = false

    var body: some View {
        #if os(iOS)
        if isCompact {
            RecentsGrid(selection: $selection)
        } else {
            RegularSidebarList(selection: $selection)
        }
        #else
        RegularSidebarList(selection: $selection)
        #endif
    }
}

/// The regular-width recents list: thumbnail + name + meta rows, `.searchable`,
/// an Open… button, selection that drives the detail column, and a context menu
/// (Open in New Window, Show in Finder on macOS, Remove from Recents).
struct RegularSidebarList: View {
    @Environment(RecentsStore.self) private var store
    @Environment(RemovalCoordinator.self) private var removal
    @Environment(ToastCenter.self) private var toast
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Binding var selection: UUID?

    @State private var searchText = ""
    @State private var isImporting = false
    #if os(iOS)
    // The shared library sheets, reachable from the iPad regular-width sidebar (H1).
    @State private var activeSheet: RecentsSheet?
    #endif

    var body: some View {
        content
            .navigationTitle("Recents")
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search recent files")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: MetafileTypes.readableContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            // The "couldn't open" alert now lives at the window level (C4a M5).
            #if os(iOS)
            .librarySheets($activeSheet)
            #endif
            // A readable sidebar width so file names aren't truncated to "gat….emf".
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    @ViewBuilder
    private var content: some View {
        if !store.didLoad {
            // Nothing until the persisted list has loaded (§h: no empty flash).
            Color.clear
        } else if store.entries.isEmpty {
            emptyState
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $selection) {
                ForEach(filteredEntries) { entry in
                    RecentRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu { rowMenu(for: entry) }
                }
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #endif
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No recent files", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Open an EMF or WMF file to get started. Compressed .emz and .wmz files work too.")
        } actions: {
            Button("Open…") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                isImporting = true
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .help("Open a metafile")
            // On iPad ⌘O opens from the sidebar; on macOS the menu bar owns ⌘O.
            #if os(iOS)
            .keyboardShortcut("o", modifiers: .command)
            #endif
        }
        #if os(iOS)
        // The iPad regular-width sidebar reaches Settings/About/What's New/Changelog/
        // Clear Recents through the shared More menu, like the compact grid (C4a H1).
        ToolbarItem {
            LibraryMoreMenu(
                activeSheet: $activeSheet,
                entriesEmpty: store.entries.isEmpty,
                onClear: { removal.requestClear(store: store) }
            )
        }
        #endif
    }

    @ViewBuilder
    private func rowMenu(for entry: RecentEntry) -> some View {
        if OpenRouting.offersNewWindow(supportsMultipleWindows: supportsMultipleWindows) {
            Button {
                openWindow(id: "library", value: LibraryWindowValue(entryID: entry.id))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        #if os(macOS)
        Button {
            revealInFinder(entry)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        #endif
        Divider()
        Button(role: .destructive) {
            if selection == entry.id { selection = nil }
            // Received files confirm first and offer Save a Copy; ordinary files are
            // removed instantly with an Undo toast (C4a H3).
            removal.requestRemoval(id: entry.id, store: store, toast: toast)
        } label: {
            Label("Remove from Recents", systemImage: "trash")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                if let id = await store.handleOpenedURL(url) { selection = id }
            }
        case .failure(let error):
            // A user cancel isn't an error (C4a M2).
            if (error as? CocoaError)?.code == .userCancelled { return }
            store.lastErrorMessage = "Emfy couldn’t open that file."
        }
    }

    private var filteredEntries: [RecentEntry] {
        guard !searchText.isEmpty else { return store.entries }
        return store.entries.filter { $0.displayName.localizedStandardContains(searchText) }
    }

    #if os(macOS)
    private func revealInFinder(_ entry: RecentEntry) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: RecentsStore.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}

/// One regular-width sidebar row: a small white-paper thumbnail, the file name,
/// and a format · size/date meta line. The thumbnail loads (and regenerates when
/// the cache was purged) off the main actor, exactly as the grid tile does.
struct RecentRow: View {
    @Environment(RecentsStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let entry: RecentEntry

    /// Only held on a cache miss; the hit path reads the cache in `body` so a
    /// rebuilt row never blanks and NSCache stays free to evict (P4).
    @State private var loadedThumbnail: CGImage?

    private var thumbnail: CGImage? {
        store.cachedThumbnail(for: entry) ?? loadedThumbnail
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnailTile
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    // Wrap to two lines with middle truncation, so a long name reads
                    // like "gate-p3-…shapes.emf" instead of "gat….emf".
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(entry.metaLine())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        // Include the same date/size the row shows, so VoiceOver isn't missing it (A5).
        .accessibilityLabel("\(entry.baseName), \(entry.formatLabel), \(entry.metaSecond())")
        // Re-fire on a file change or a cache eviction while the row stays alive, so
        // an evicted thumbnail reloads rather than staying blank (P4 / review #3).
        .task(id: ThumbnailTaskID(name: entry.thumbnailFileName, needsLoad: thumbnail == nil)) {
            guard store.cachedThumbnail(for: entry) == nil else { return }
            loadedThumbnail = await store.loadThumbnail(for: entry)
        }
    }

    private var thumbnailTile: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.white)
            .frame(width: 46, height: 34)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}
