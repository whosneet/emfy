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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Binding var selection: UUID?

    @State private var searchText = ""
    @State private var isImporting = false

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
            .alert(
                "Couldn’t open file",
                isPresented: Binding(
                    get: { store.lastErrorMessage != nil },
                    set: { if !$0 { store.lastErrorMessage = nil } }
                ),
                presenting: store.lastErrorMessage
            ) { _ in
                Button("OK", role: .cancel) { store.lastErrorMessage = nil }
            } message: { message in
                Text(message)
            }
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
        }
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
            store.remove(entry.id)
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
        case .failure:
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

    @State private var thumbnail: CGImage?

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
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.baseName), \(entry.formatLabel), \(sizeString)")
        .task(id: entry.thumbnailFileName) {
            thumbnail = store.cachedThumbnail(for: entry)
            thumbnail = await store.loadThumbnail(for: entry)
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

    private var metaLine: String {
        let second = Calendar.current.isDateInToday(entry.openedAt)
            ? sizeString
            : entry.openedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(entry.formatLabel) · \(second)"
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
    }
}
