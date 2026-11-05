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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var selection: UUID?

    @State private var isSelecting = false
    @State private var isImporting = false
    @State private var activeSheet: RecentsSheet?
    /// The fold-aware column count (27.1+), or `nil` to use the adaptive grid.
    @State private var columnCount: Int?

    @SceneStorage("recents.search") private var searchText = ""

    /// Minimum tile width, scaled with Dynamic Type so big text doesn't clip — at
    /// accessibility sizes this grows enough to collapse the grid to one column on
    /// a phone (A3).
    @ScaledMetric private var minTileWidth: CGFloat = 158

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
            .librarySheets($activeSheet)
            // The "couldn't open" alert now lives at the window level (C4a M5).
            // Reset Select mode when the list empties or a file is chosen (C4a M1).
            .onChange(of: store.entries.isEmpty) { _, empty in
                if empty { isSelecting = false }
            }
            .onChange(of: selection) { _, id in
                if id != nil { isSelecting = false }
            }
    }

    // MARK: - Content

    private func content(filtered: [RecentEntry]) -> some View {
        ZStack {
            if !store.didLoad {
                // Nothing until the persisted list has loaded (§h: no empty flash).
                Color.clear
            } else if store.entries.isEmpty {
                EmptyRecentsView(openAction: { isImporting = true })
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                grid(filtered: filtered)
            }
        }
    }

    private func grid(filtered: [RecentEntry]) -> some View {
        // One pass splits today vs earlier, feeding both sections (P7).
        let partition = RecentEntry.partitionedByDay(filtered)
        return ScrollView {
            gridBody(columns: resolvedColumns, partition: partition)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.width) { resolveColumns(proxy) }
            }
        }
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

    private func gridBody(columns: [GridItem], partition: (today: [RecentEntry], earlier: [RecentEntry])) -> some View {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
            section(title: "Today", entries: partition.today, columns: columns)
            section(title: "Earlier", entries: partition.earlier, columns: columns)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func section(title: String, entries: [RecentEntry], columns: [GridItem]) -> some View {
        if !entries.isEmpty {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)
                .padding(.bottom, 6)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    tile(for: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for entry: RecentEntry) -> some View {
        if isSelecting {
            // The tile removes through the shared coordinator from the environment,
            // so it no longer takes a per-entry closure (P3).
            RecentTileView(entry: entry, isSelecting: true)
        } else {
            // A Button that sets the shared selection, pushing the viewer on compact
            // width. Assigning (not toggling) makes a rapid double tap idempotent.
            // The grid is the compact sidebar (iPhone, Duo outer, Split-View half).
            // A tap opens the file; a long press shows a UIKit context menu whose
            // "Open in New Window" uses UIWindowScene.ActivationAction — it shows the
            // "Open" alternate where a second window can't be created (iPhone, Duo
            // outer) and makes one where it can (Duo inner split half). The tile keeps
            // its button label; VoiceOver activates it to open and has a Remove action.
            RecentTileView(entry: entry, isSelecting: false)
                .overlay(
                    TileOpenInteraction(
                        entryID: entry.id,
                        onOpen: { selection = entry.id },
                        onRemove: { removal.requestRemoval(id: entry.id, store: store, toast: toast) }
                    )
                )
                .accessibilityAction(.default) { selection = entry.id }
                .accessibilityActions {
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
