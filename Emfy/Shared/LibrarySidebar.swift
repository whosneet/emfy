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
    @Environment(EmfySettings.self) private var settings
    #if os(iOS)
    @Environment(AIProviderStore.self) private var aiProviders: AIProviderStore?
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Binding var selection: UUID?

    @State private var searchText = ""
    /// The search text after a short debounce, so the smart-search ranking (and any
    /// embedding lookup) never runs on every keystroke (A1b Part 2).
    @State private var debouncedQuery = ""
    @State private var isImporting = false
    #if os(iOS)
    // The shared library sheets, reachable from the iPad regular-width sidebar (H1).
    @State private var activeSheet: RecentsSheet?
    /// Drives the New Drawing presets sheet from the iPad library "+" (E3a).
    @State private var showNewDrawing = false
    /// Drives the "New Drawing from Description…" sheet from the iPad library "+" (X2d).
    @State private var showGenerateDrawing = false
    #endif

    var body: some View {
        content
            .navigationTitle("Recents")
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search recent files")
            // Debounce the query (A1b Part 2): the ranking and any embedding lookup run
            // after typing settles, not per keystroke.
            .task(id: searchText) {
                if searchText.isEmpty { debouncedQuery = ""; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedQuery = searchText
            }
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
            .librarySheets($activeSheet, store: store, settings: settings)
            .sheet(isPresented: $showNewDrawing) {
                NewDrawingSheet { preset in
                    Task {
                        if let id = await NewDrawing.create(preset, in: store) { selection = id }
                    }
                }
            }
            .sheet(isPresented: $showGenerateDrawing) {
                GenerateDrawingSheet { data in
                    Task {
                        if let id = await NewDrawing.create(data: data, in: store) { selection = id }
                    }
                }
            }
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
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            RecentRow(entry: entry, isPrivate: store.isSessionPrivate(entry.id))
                                .tag(entry.id)
                                .contextMenu { rowMenu(for: entry) }
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #endif
        }
    }

    /// The sorted, pinned/private-aware sections for the current search and sort
    /// (S1a-5). Search filters first, so every sort still searches. An active smart
    /// search shows one relevance-ranked section (no date/name re-sort), so the ranking
    /// survives (A1b Part 2).
    private var sections: [RecentSections.Section] {
        if !debouncedQuery.isEmpty, aiSearchEnabled {
            return [RecentSections.Section(kind: .all, entries: filteredEntries)]
        }
        return RecentSections.build(filteredEntries, sort: settings.sortRecentsBy, privateIDs: store.privateIDs)
    }

    /// Whether smart (AI) search is active — the AI toggle on and Private mode off.
    private var aiSearchEnabled: Bool {
        DrawingTitleTagPolicy.shouldDisplay(aiEnabled: settings.useOnDeviceAI, privateMode: settings.privateMode)
    }

    #if os(iOS)
    /// Whether an AI engine is available, so the library "+" offers "New Drawing from
    /// Description…" only when it can actually run (X2d).
    private var generateDrawingAvailable: Bool {
        let onDevice = settings.useOnDeviceAI && DrawingAIAvailability.current().isAvailable
        if let aiProviders { return aiProviders.resolvedEngine(onDeviceAvailable: onDevice) != nil }
        return onDevice
    }
    #endif

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
        // New Drawing (E3a) + New Drawing from Description (X2d): the iPad library "+" offers
        // a blank preset or an AI-generated drawing. The generate item appears only when an
        // AI engine is available.
        ToolbarItem {
            Menu {
                Button { showNewDrawing = true } label: { Label("New Drawing…", systemImage: "doc") }
                if generateDrawingAvailable {
                    Button { showGenerateDrawing = true } label: { Label("New Drawing from Description…", systemImage: "wand.and.stars") }
                }
            } label: {
                Label("New Drawing", systemImage: "plus")
            }
            .help("New Drawing")
            .accessibilityIdentifier("libraryNewDrawing")
        }
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
        // A session-only Private entry can't be pinned (it never persists).
        if !store.isSessionPrivate(entry.id) {
            let pinned = store.isPinned(entry.id)
            Button {
                store.togglePin(entry.id)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
        }
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
        guard !debouncedQuery.isEmpty else { return store.entries }
        // AI off (or Private): plain file-name matching, exactly as before.
        guard aiSearchEnabled else {
            return store.entries.filter { $0.displayName.localizedStandardContains(debouncedQuery) }
        }
        // AI on: rank by name, AI title, tags, extracted/OCR text and meaning.
        return LibrarySearchRanker.rank(
            entries: store.entries, query: debouncedQuery, aiEnabled: true,
            textFor: { LibrarySearchIndex.shared.text(for: $0) },
            scorer: LibrarySearchScorer.shared)
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
    @Environment(RemovalCoordinator.self) private var removal
    @Environment(ToastCenter.self) private var toast
    @Environment(EmfySettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let entry: RecentEntry
    /// Whether this is a session-only Private-mode entry (shows the marker, hides Pin).
    var isPrivate: Bool = false

    /// Only held on a cache miss; the hit path reads the cache in `body` so a
    /// rebuilt row never blanks and NSCache stays free to evict (P4).
    @State private var loadedThumbnail: CGImage?

    private var thumbnail: CGImage? {
        store.cachedThumbnail(for: entry) ?? loadedThumbnail
    }

    /// The sidebar thumbnail, capped at accessibility text sizes so the (now 3-line)
    /// name and meta keep room, mirroring the grid tile and list row (A-M8).
    private var thumbnailBox: CGSize {
        let base = settings.thumbnailSize.sidebarThumbnail
        guard dynamicTypeSize.isAccessibilitySize else { return base }
        let cap: CGFloat = 40
        guard base.width > cap else { return base }
        return CGSize(width: cap, height: base.height * (cap / base.width))
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnailTile
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    // Wrap to two lines with middle truncation, so a long name reads
                    // like "gate-p3-…shapes.emf" instead of "gat….emf"; three at
                    // accessibility sizes, like the other two surfaces (A-M8).
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .truncationMode(.middle)
                Text(entry.metaLine())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                RecentAITitleLine(entry: entry)
            }
            if isPrivate {
                Spacer(minLength: 4)
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Mac tooltip on the Private marker (A-L1).
                    .help("Private: not saved to history")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        // One shared label so all three surfaces read identically, including ", Pinned"
        // (A-M4/A5).
        .accessibilityLabel(entry.accessibilityLabel(pinned: store.isPinned(entry.id), isPrivate: isPrivate))
        // The same VoiceOver actions the grid tile and list row offer, so all three
        // surfaces match: Open in New Window (where a second window can exist),
        // Pin/Unpin (not for Private), and Remove (A-M8).
        .accessibilityActions {
            if OpenRouting.offersNewWindow(supportsMultipleWindows: supportsMultipleWindows) {
                Button("Open in New Window") {
                    openWindow(id: "library", value: LibraryWindowValue(entryID: entry.id))
                }
            }
            if !isPrivate {
                Button(store.isPinned(entry.id) ? "Unpin" : "Pin") { store.togglePin(entry.id) }
            }
            Button("Remove from Recents", role: .destructive) {
                removal.requestRemoval(id: entry.id, store: store, toast: toast)
            }
        }
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
            .frame(width: thumbnailBox.width, height: thumbnailBox.height)
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
