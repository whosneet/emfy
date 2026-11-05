import SwiftUI
import UIKit

/// The recents home: a large-title screen with search, an adaptive thumbnail
/// grid sectioned into Today / Earlier, and a first-launch empty state. Files
/// open through the Files picker, a share, or an incoming document, and each
/// opened file lands here.
///
/// All bars are system-managed `.toolbar` items inside the `NavigationStack`, so
/// they move to the side vertical bar on iPhone Duo (v3-plan §6, Duo rules); no
/// hand-built capsules.
struct RecentsView: View {
    @Environment(RecentsStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path: [ViewerRoute] = []
    @State private var isSelecting = false
    @State private var isImporting = false
    @State private var activeSheet: RecentsSheet?
    /// The fold-aware column count (27.1+), or `nil` to use the adaptive grid.
    @State private var columnCount: Int?

    // Scene-scoped persistence of the search text and navigation stack.
    @SceneStorage("recents.search") private var searchText = ""
    @SceneStorage("recents.navPath") private var persistedPath: Data?

    /// Minimum tile width, scaled with Dynamic Type so big text doesn't clip —
    /// at accessibility sizes this grows enough to collapse the grid to one
    /// column on a phone (A7).
    @ScaledMetric private var minTileWidth: CGFloat = 158

    // Pre-27.1 column layout: the adaptive grid picks its own count (the I1
    // behaviour). On 27.1+ the grid prefers an even column count when a fold
    // region exists (see `grid`).
    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: minTileWidth, maximum: 240), spacing: 16)]
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Recents")
                .searchable(text: $searchText, prompt: "Search recent files")
                .toolbar { toolbarContent }
                .navigationDestination(for: ViewerRoute.self) { route in
                    // Distinct identity per file, so opening another file while
                    // one is shown (which replaces the route) resets the viewer's
                    // state — chrome, zoom, inspector — instead of reusing it.
                    MetafileViewerScreen(entryID: route.entryID)
                        .id(route.entryID)
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: EMFDocument.readableContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }
        }
        .onOpenURL { url in
            Task { await open(url) }
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
        .task {
            await store.loadIfNeeded()
            restorePath()
        }
        .onChange(of: path) { _, newValue in
            savePath(newValue)
        }
    }

    // MARK: - Navigation restoration (scene-scoped)

    private func restorePath() {
        guard path.isEmpty, let data = persistedPath,
              let routes = try? JSONDecoder().decode([ViewerRoute].self, from: data) else { return }
        // Drop restored routes whose entry no longer exists, so restoration never
        // lands on a viewer for a file that was removed since.
        let valid = routes.filter { store.entry(id: $0.entryID) != nil }
        if valid != path { path = valid }
    }

    private func savePath(_ routes: [ViewerRoute]) {
        persistedPath = try? JSONEncoder().encode(routes)
    }

    // MARK: - Content

    // A stable container type (always a `ZStack`) so the empty → grid switch on
    // the first opened file doesn't change the NavigationStack root's identity.
    // When it did, the `.navigationDestination` re-registered and dropped the
    // just-pushed viewer (push-then-pop; the path kept the route but nothing
    // showed). Branching lives inside the ZStack, which keeps the root stable.
    private var content: some View {
        ZStack {
            if !store.didLoad {
                // Show nothing until the persisted list has loaded, so the empty
                // state never flashes before real recents appear (§h).
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

    // The grid is scrolling content, so it never displaces for the fold; it only
    // prefers an even column count when a division region exists, so the middle
    // gutter can straddle the fold rather than a tile (v3-plan §6 Duo rules;
    // iphone-duo.md Custom grids). The fold/width read is in a `.background`
    // GeometryReader so the `ScrollView` stays the navigation content's direct
    // child — wrapping it in a GeometryReader breaks the NavigationLink push.
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

    /// The column template built from the resolved count; falls back to the
    /// adaptive grid until the width is measured (and on pre-27.1, where there is
    /// no fold to consider).
    private var resolvedColumns: [GridItem] {
        guard let count = columnCount else { return adaptiveColumns }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    private func resolveColumns(_ proxy: GeometryProxy) {
        guard #available(iOS 27.1, *) else { return }  // pre-27.1: keep the adaptive grid
        let count = DuoRegions.gridColumnCount(
            availableWidth: proxy.size.width - 32,  // the grid's horizontal padding
            minTileWidth: minTileWidth,             // scales with Dynamic Type (A7)
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
            // A Button that pushes the route, rather than a NavigationLink —
            // same push, but it works under synthetic taps too (a NavigationLink
            // can swallow them) and keeps the open path in one place. Assigning
            // the single-element path (not append) makes a rapid double tap
            // idempotent — no double push.
            Button {
                path = [ViewerRoute(entryID: entry.id)]
            } label: {
                RecentTileView(entry: entry, isSelecting: false, onRemove: {})
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Toolbar (system-managed)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        openItem
        selectItem
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
    }

    // The prominent action, first in the vertical bar (Duo: back → prominent →
    // rest). `.topBarPinnedTrailing` resists overflow on the outer display;
    // `.primaryAction` is the pre-27 fallback.
    @ToolbarContentBuilder
    private var openItem: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: .topBarPinnedTrailing) { openButton }
                .visibilityPriority(.high)
        } else {
            ToolbarItem(placement: .primaryAction) { openButton }
        }
    }

    // A symbol↔text toggle stays on the horizontal axis on Duo (iOS 27.1+).
    @ToolbarContentBuilder
    private var selectItem: some ToolbarContent {
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
                .axisBehavior(.horizontalOnly)
        } else {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
        }
    }

    // The mockups' blue "Open from Files" — the system's prominent treatment
    // (glass on iOS 26+, bordered prominent before), still a system toolbar item.
    private var openButton: some View {
        Button {
            isImporting = true
        } label: {
            Label("Open from Files", systemImage: "folder")
        }
        .prominentOpenStyle()
    }

    // Distinct symbol per state and the title shown while selecting, so edit
    // mode is unmistakable (the two states previously shared one icon).
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
            // Dismiss any active sheet or the Files importer before navigating,
            // so the new viewer isn't pushed behind a stale modal.
            activeSheet = nil
            isImporting = false
            // Opening a file shows just that file's viewer — replace the stack
            // rather than appending, so repeated opens never pile viewers up (and
            // their keyboard shortcuts never compete).
            path = [ViewerRoute(entryID: id)]
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
    /// The system's prominent button treatment for the "Open from Files"
    /// toolbar action: Liquid Glass prominent on iOS 26+, bordered prominent
    /// before. Kept as a toolbar `Button` so it still migrates to the Duo
    /// vertical bar.
    @ViewBuilder
    func prominentOpenStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
