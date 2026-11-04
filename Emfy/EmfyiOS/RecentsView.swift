import SwiftUI

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

    @State private var path: [ViewerRoute] = []
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var isImporting = false
    @State private var activeSheet: RecentsSheet?

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Recents")
                .toolbar { toolbarContent }
                .navigationDestination(for: ViewerRoute.self) { route in
                    MetafileViewerScreen(entryID: route.entryID)
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: EMFDocument.readableContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }
        }
        .searchable(text: $searchText, prompt: "Search recent files")
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
        .task { store.loadIfNeeded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            EmptyRecentsView(openAction: { isImporting = true })
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                section(title: "Today", entries: todayEntries)
                section(title: "Earlier", entries: earlierEntries)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func section(title: String, entries: [RecentEntry]) -> some View {
        if !entries.isEmpty {
            Text(title)
                .font(.title3.weight(.semibold))
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
            NavigationLink(value: ViewerRoute(entryID: entry.id)) {
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
    // rest). `.visibilityPriority(.high)` keeps it in the bar longest when the
    // outer display overflows (iOS 27+).
    @ToolbarContentBuilder
    private var openItem: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: .primaryAction) { openButton }
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

    private var openButton: some View {
        Button {
            isImporting = true
        } label: {
            Label("Open from Files", systemImage: "folder")
        }
    }

    private var selectButton: some View {
        Button {
            withAnimation { isSelecting.toggle() }
        } label: {
            Label(isSelecting ? "Done" : "Select", systemImage: "checkmark.circle")
        }
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
                withAnimation { store.clear() }
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
            path.append(ViewerRoute(entryID: id))
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
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
