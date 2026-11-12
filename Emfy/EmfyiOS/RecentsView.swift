import SwiftUI
import UIKit

/// The compact-width library sidebar (iPhone, Split-View halves, the Duo outer
/// display): the approved recents home — a large-title screen with search, an
/// adaptive thumbnail grid sectioned into Today / Earlier, a first-launch empty
/// state, and Select mode. It lives inside the library window's `NavigationSplitView`
/// sidebar, which on compact width is a navigation stack, so selecting a tile sets
/// the shared `selection` and pushes the viewer (v3-plan §9.1). The regular-width
/// list is `RegularSidebarList`; the viewer detail is driven by a `DocumentSession`.
///
/// All bars are system-managed `.toolbar` items, so they move to the side vertical
/// bar on iPhone Duo (v3-plan §6); no hand-built capsules.
struct RecentsGrid: View {
    @Environment(RecentsStore.self) private var store
    @Environment(RemovalCoordinator.self) private var removal
    @Environment(ToastCenter.self) private var toast
    @Environment(EmfySettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var selection: UUID?

    @State private var isSelecting = false
    /// The files picked in Select mode, for Batch Convert (F1). Cleared on exit.
    @State private var selectedIDs: Set<UUID> = []
    @State private var showConvert = false
    @State private var isImporting = false
    @State private var activeSheet: RecentsSheet?
    /// The fold-aware column count (27.1+), or `nil` to use the adaptive grid.
    @State private var columnCount: Int?

    // The live query is plain state; it is mirrored into scene restoration only while
    // Private mode is off, so a search typed over private files never persists (S-L3).
    @State private var searchText = ""
    @SceneStorage("recents.search") private var storedSearch = ""

    /// Minimum tile width per Thumbnail size (S1a-5), each scaled with Dynamic Type so
    /// big text doesn't clip — at accessibility sizes it grows enough to collapse the
    /// grid to one column on a phone (A3).
    @ScaledMetric private var smallTileWidth: CGFloat = 120
    @ScaledMetric private var mediumTileWidth: CGFloat = 158
    @ScaledMetric private var largeTileWidth: CGFloat = 196

    private var minTileWidth: CGFloat {
        switch settings.thumbnailSize {
        case .small: smallTileWidth
        case .medium: mediumTileWidth
        case .large: largeTileWidth
        }
    }

    /// At accessibility sizes the grid is a single flexible column; otherwise it is
    /// adaptive with a maximum that can't fall below the (scaled) minimum, so a wide
    /// `minTileWidth` never exceeds a fixed 240 and overflows (A3).
    private var adaptiveColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 16)]
        }
        return [GridItem(.adaptive(minimum: minTileWidth, maximum: max(240, minTileWidth)), spacing: 16)]
    }

    var body: some View {
        // Filter the store once per body; `content` and `grid` reuse the result so
        // the list is no longer filtered four times a pass (P7).
        let filtered = filteredEntries
        return content(filtered: filtered)
            .navigationTitle("Recents")
            .searchable(text: $searchText, prompt: "Search recent files")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: MetafileTypes.readableContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .librarySheets($activeSheet, store: store, settings: settings)
            // Restore the last non-private query, then persist changes only while
            // Private mode is off (S-L3).
            .onAppear { if searchText.isEmpty { searchText = storedSearch } }
            .onChange(of: searchText) { _, query in
                if !settings.privateMode { storedSearch = query }
            }
            // The "couldn't open" alert now lives at the window level (C4a M5).
            // Reset Select mode when the list empties or a file is chosen (C4a M1).
            .onChange(of: store.entries.isEmpty) { _, empty in
                if empty { isSelecting = false }
            }
            .onChange(of: selection) { _, id in
                if id != nil { isSelecting = false }
            }
            // Leaving Select mode drops the multi-selection (F1).
            .onChange(of: isSelecting) { _, selecting in
                if !selecting { selectedIDs.removeAll() }
            }
            .sheet(isPresented: $showConvert) {
                IOSBatchConvertSheet(entries: selectedConvertEntries, store: store)
                    .environment(settings)
            }
    }

    /// The entries chosen in Select mode, for Batch Convert (newest-first, matching the
    /// grid order).
    private var selectedConvertEntries: [RecentEntry] {
        store.entries.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(filtered: [RecentEntry]) -> some View {
        if !store.didLoad {
            // Nothing until the persisted list has loaded (§h: no empty flash).
            Color.clear
        } else if store.entries.isEmpty {
            EmptyRecentsView(openAction: { isImporting = true })
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if settings.recentsLayout == .list {
            listLayout(sections: sections(filtered))
        } else {
            grid(sections: sections(filtered))
        }
    }

    /// The sorted, pinned/private-aware sections for the current search and sort
    /// (S1a-5). Search filters first, so every sort still searches.
    private func sections(_ filtered: [RecentEntry]) -> [RecentSections.Section] {
        RecentSections.build(filtered, sort: settings.sortRecentsBy, privateIDs: store.privateIDs)
    }

    private func grid(sections: [RecentSections.Section]) -> some View {
        ScrollView {
            gridBody(columns: resolvedColumns, sections: sections)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.width) { resolveColumns(proxy) }
            }
        }
    }

    /// The Thumbnail-size list layout (S1a-5): a system `List` of sections, each a
    /// row with a leading thumbnail. Tap opens; a context menu and swipe give Pin and
    /// Remove, and Select mode swaps in a per-row remove badge, as the grid does.
    private func listLayout(sections: [RecentSections.Section]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        RecentListRow(
                            entry: entry,
                            isSelecting: isSelecting,
                            onOpen: { selection = entry.id },
                            onRemove: { removal.requestRemoval(id: entry.id, store: store, toast: toast) },
                            isSelected: selectedIDs.contains(entry.id),
                            onToggleSelect: isSelecting ? { toggleSelected(entry.id) } : nil
                        )
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.plain)
    }

    private var resolvedColumns: [GridItem] {
        guard let count = columnCount else { return adaptiveColumns }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    private func resolveColumns(_ proxy: GeometryProxy) {
        // At accessibility sizes, force the single flexible column (A3); don't let the
        // Duo even-column path reintroduce a multi-column overflow.
        guard !dynamicTypeSize.isAccessibilitySize else {
            if columnCount != nil { columnCount = nil }
            return
        }
        guard #available(iOS 27.1, *) else { return }
        let count = DuoRegions.gridColumnCount(
            availableWidth: proxy.size.width - 32,
            minTileWidth: minTileWidth,
            spacing: 16,
            preferEven: DuoRegions.hasDivisionRegion(in: proxy)
        )
        if count != columnCount { columnCount = count }
    }

    private func gridBody(columns: [GridItem], sections: [RecentSections.Section]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
            ForEach(sections) { section in
                gridSection(section, columns: columns)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func gridSection(_ section: RecentSections.Section, columns: [GridItem]) -> some View {
        // Name/size collapse to one untitled section; pinned/private/date keep a header.
        if let title = section.title {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)
                .padding(.bottom, 6)
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(section.entries) { entry in
                tile(for: entry)
            }
        }
    }

    @ViewBuilder
    private func tile(for entry: RecentEntry) -> some View {
        if isSelecting {
            // Select mode is a multi-selection for Batch Convert (F1): a tap toggles the
            // file's membership, shown by a checkmark badge.
            Button {
                toggleSelected(entry.id)
            } label: {
                RecentTileView(entry: entry, isSelecting: false, isPrivate: store.isSessionPrivate(entry.id))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selectedIDs.contains(entry.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .padding(6)
                            .shadow(radius: 1)
                    }
                    .opacity(selectedIDs.contains(entry.id) ? 1 : 0.85)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.baseName)
            .accessibilityAddTraits(selectedIDs.contains(entry.id) ? [.isSelected, .isButton] : .isButton)
        } else {
            // A Button that sets the shared selection, pushing the viewer on compact
            // width. Assigning (not toggling) makes a rapid double tap idempotent.
            // The grid is the compact sidebar (iPhone, Duo outer, Split-View half).
            // A tap opens the file; a long press shows a UIKit context menu whose
            // "Open in New Window" uses UIWindowScene.ActivationAction — it shows the
            // "Open" alternate where a second window can't be created (iPhone, Duo
            // outer) and makes one where it can (Duo inner split half). The tile keeps
            // its button label; VoiceOver activates it to open and has a Remove action.
            RecentTileView(entry: entry, isSelecting: false, isPrivate: store.isSessionPrivate(entry.id))
                .overlay(
                    TileOpenInteraction(
                        entryID: entry.id,
                        onOpen: { selection = entry.id },
                        onRemove: { removal.requestRemoval(id: entry.id, store: store, toast: toast) },
                        isPinned: store.isPinned(entry.id),
                        canPin: !store.isSessionPrivate(entry.id),
                        onPin: { store.togglePin(entry.id) }
                    )
                )
                .accessibilityAction(.default) { selection = entry.id }
                .accessibilityActions {
                    if !store.isSessionPrivate(entry.id) {
                        Button(store.isPinned(entry.id) ? "Unpin" : "Pin") { store.togglePin(entry.id) }
                    }
                    Button("Remove from Recents", role: .destructive) {
                        removal.requestRemoval(id: entry.id, store: store, toast: toast)
                    }
                }
        }
    }

    // MARK: - Toolbar (system-managed)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        openItem
        selectItem
        trailingSpacer
        ToolbarItem(placement: .topBarTrailing) {
            LibraryMoreMenu(
                activeSheet: $activeSheet,
                entriesEmpty: store.entries.isEmpty,
                onClear: { removal.requestClear(store: store) }
            )
        }
        // Batch Convert bottom bar (F1), shown only in Select mode.
        if isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showConvert = true
                } label: {
                    Label("Convert…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(selectedIDs.isEmpty)
                Spacer()
                Text(selectedIDs.isEmpty ? "Select files to convert" : "\(selectedIDs.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Toggles a file's membership in the Select-mode multi-selection (F1).
    private func toggleSelected(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    /// On iOS 26.0–26.x, Select and More both land in `.topBarTrailing` and merge
    /// into one glass pill; a fixed spacer splits them back into separate pills (G3).
    /// From 27 the pinned/axis placements separate them, so no spacer is needed there.
    @ToolbarContentBuilder
    private var trailingSpacer: some ToolbarContent {
        if #unavailable(iOS 27.0) {
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }
    }

    @ToolbarContentBuilder
    private var openItem: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: .topBarPinnedTrailing) { openButton }
                .visibilityPriority(.high)
        } else {
            ToolbarItem(placement: .primaryAction) { openButton }
        }
    }

    @ToolbarContentBuilder
    private var selectItem: some ToolbarContent {
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
                .axisBehavior(.horizontalOnly)
        } else {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
        }
    }

    private var openButton: some View {
        Button {
            isImporting = true
        } label: {
            Label("Open from Files", systemImage: "folder")
        }
        .prominentOpenStyle()
        .keyboardShortcut("o", modifiers: .command)   // ⌘O on the library (M6)
    }

    private var selectButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .default) { isSelecting.toggle() }
            UIAccessibility.post(
                notification: .announcement,
                argument: isSelecting ? "Selecting recent files" : "Done selecting"
            )
        } label: {
            Label(
                isSelecting ? "Done" : "Select",
                systemImage: isSelecting ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        .labelStyle(.titleOnly)
        // Stay enabled while selecting so Done can exit even when the last file was
        // just removed and the list is now empty (C4a M1).
        .disabled(store.entries.isEmpty && !isSelecting)
    }

    // MARK: - Opening

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await open(url) }
        case .failure(let error):
            // A user cancel isn't an error (C4a M2).
            if (error as? CocoaError)?.code == .userCancelled { return }
            store.lastErrorMessage = "Emfy couldn’t open that file."
        }
    }

    private func open(_ url: URL) async {
        if let id = await store.handleOpenedURL(url) {
            isSelecting = false
            activeSheet = nil
            isImporting = false
            selection = id
        }
    }

    // MARK: - Derived data

    private var filteredEntries: [RecentEntry] {
        guard !searchText.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.displayName.localizedStandardContains(searchText)
        }
    }
}

/// The More-menu sheets.
enum RecentsSheet: String, Identifiable {
    case settings, about, whatsNew, changelog
    var id: String { rawValue }
}

/// Wraps a shared content view (What's New, Changelog) in a sheet with a Done
/// button.
struct InfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    SheetDoneToolbar { dismiss() }
                }
        }
    }
}

/// A dismiss-only sheet's close control (G2): the Liquid Glass close (X) button on
/// 26, a plain "Done" text button below — text only, so a pre-26 "Done" never
/// renders icon-only. Shared by the library sheets, About and the iOS Settings sheet.
struct SheetDoneToolbar: ToolbarContent {
    let onDismiss: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { onDismiss() }
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
            }
        }
    }
}

extension View {
    /// The system's prominent button treatment for the "Open from Files" toolbar
    /// action: Liquid Glass prominent on iOS 26+, bordered prominent before.
    @ViewBuilder
    func prominentOpenStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
