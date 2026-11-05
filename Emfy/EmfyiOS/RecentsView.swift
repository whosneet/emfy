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
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selection: UUID?

    @State private var isSelecting = false
    @State private var isImporting = false
    @State private var activeSheet: RecentsSheet?
    /// The fold-aware column count (27.1+), or `nil` to use the adaptive grid.
    @State private var columnCount: Int?

    @SceneStorage("recents.search") private var searchText = ""

    /// Minimum tile width, scaled with Dynamic Type so big text doesn't clip — at
    /// accessibility sizes this grows enough to collapse the grid to one column on
    /// a phone (A7).
    @ScaledMetric private var minTileWidth: CGFloat = 158

    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: minTileWidth, maximum: 240), spacing: 16)]
    }

    var body: some View {
        content
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
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .about: AboutView()
                case .whatsNew: InfoSheet(title: "What's New") { WhatsNewView() }
                case .changelog: InfoSheet(title: "Changelog") { ChangelogView() }
                }
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
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            if !store.didLoad {
                // Nothing until the persisted list has loaded (§h: no empty flash).
                Color.clear
            } else if store.entries.isEmpty {
                EmptyRecentsView(openAction: { isImporting = true })
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            gridBody(columns: resolvedColumns)
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
        guard #available(iOS 27.1, *) else { return }
        let count = DuoRegions.gridColumnCount(
            availableWidth: proxy.size.width - 32,
            minTileWidth: minTileWidth,
            spacing: 16,
            preferEven: DuoRegions.hasDivisionRegion(in: proxy)
        )
        if count != columnCount { columnCount = count }
    }

    private func gridBody(columns: [GridItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
            section(title: "Today", entries: todayEntries, columns: columns)
            section(title: "Earlier", entries: earlierEntries, columns: columns)
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
            RecentTileView(entry: entry, isSelecting: true) {
                store.remove(entry.id)
            }
        } else {
            // A Button that sets the shared selection, pushing the viewer on compact
            // width. Assigning (not toggling) makes a rapid double tap idempotent.
            // The grid is the compact sidebar (iPhone, Duo outer, Split-View half).
            // A tap opens the file; a long press shows a UIKit context menu whose
            // "Open in New Window" uses UIWindowScene.ActivationAction — it shows the
            // "Open" alternate where a second window can't be created (iPhone, Duo
            // outer) and makes one where it can (Duo inner split half). The tile keeps
            // its button label; VoiceOver activates it to open and has a Remove action.
            RecentTileView(entry: entry, isSelecting: false, onRemove: {})
                .overlay(
                    TileOpenInteraction(
                        entryID: entry.id,
                        onOpen: { selection = entry.id },
                        onRemove: { store.remove(entry.id) }
                    )
                )
                .accessibilityAction(.default) { selection = entry.id }
                .accessibilityActions {
                    Button("Remove from Recents", role: .destructive) { store.remove(entry.id) }
                }
        }
    }

    // MARK: - Toolbar (system-managed)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        openItem
        selectItem
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
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
        .disabled(store.entries.isEmpty)
    }

    private var moreMenu: some View {
        Menu {
            Button { activeSheet = .about } label: {
                Label("About Emfy", systemImage: "info.circle")
            }
            Button { activeSheet = .whatsNew } label: {
                Label("What's New", systemImage: "sparkles")
            }
            Button { activeSheet = .changelog } label: {
                Label("Changelog", systemImage: "list.bullet.rectangle")
            }
            Divider()
            Button {
                if let url = EmfyLinks.contact { openURL(url) }
            } label: {
                Label("Contact", systemImage: "envelope")
            }
            Button {
                if let url = EmfyLinks.gitHub { openURL(url) }
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(reduceMotion ? nil : .default) { store.clear() }
            } label: {
                Label("Clear Recents", systemImage: "trash")
            }
            .disabled(store.entries.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Opening

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await open(url) }
        case .failure:
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

    private var todayEntries: [RecentEntry] {
        filteredEntries.filter { Calendar.current.isDateInToday($0.openedAt) }
    }

    private var earlierEntries: [RecentEntry] {
        filteredEntries.filter { !Calendar.current.isDateInToday($0.openedAt) }
    }
}

/// The More-menu sheets.
enum RecentsSheet: String, Identifiable {
    case about, whatsNew, changelog
    var id: String { rawValue }
}

/// The project's outbound links, shared by the More menu and About sheet.
enum EmfyLinks {
    static let gitHub = URL(string: "https://github.com/whosneet/emfy")

    static var contact: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@arrley.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "Emfy - Feedback/Support")]
        return components.url
    }
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
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
