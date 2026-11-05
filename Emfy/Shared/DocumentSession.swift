import EMFRender
import Foundation

/// The per-window document host (v3-plan §11.2). It owns one open metafile's
/// lifecycle for a library window: the recents entry it shows, the typed load
/// state, the prepared/rendered model and its diagnostics, an `UndoManager` slot
/// for the editor that lands in a later phase, and an `NSFilePresenter` that
/// reloads the file when it changes on disk. Read-only in C3a — nothing here
/// writes.
///
/// Data resolution and parsing are injected so the load-state machine is tested
/// without real files or a window; the window-facing initialiser binds them to
/// the shared `RecentsStore`. One session per open document per window, so each
/// window owns its own selection and undo stack.
@MainActor
@Observable
final class DocumentSession {
    /// The recents entry this session shows. Resolved through the store each load
    /// so a promoted/refreshed bookmark is always honoured.
    let entryID: UUID

    /// Why a load failed. Each maps to a distinct recovery the viewer offers
    /// (v3-plan §9.1 "failed-state actions").
    enum FailureReason: Equatable, Sendable {
        /// Definitively gone — the store has already pruned the entry. The viewer
        /// offers Remove from Recents (the entry is dismissed).
        case notFound
        /// Transient — offline, locked, or a not-yet-downloaded iCloud item. The
        /// entry is kept; the viewer offers Try Again.
        case unavailable
        /// The bytes resolved but EMFKit could not parse them at all. The viewer
        /// offers Remove from Recents.
        case unreadable
    }

    /// The load lifecycle. `loaded` carries the prepared, re-renderable model; the
    /// tiled viewers draw from `LoadedMetafile.prepared`, never a stored bitmap.
    enum LoadState {
        case idle
        case loading
        case loaded(LoadedMetafile)
        case failed(FailureReason)

        /// A payload-free projection, so tests assert transitions without needing
        /// to synthesise a `LoadedMetafile`.
        enum Kind: Equatable, Sendable {
            case idle, loading, loaded
            case failedNotFound, failedUnavailable, failedUnreadable
        }

        var kind: Kind {
            switch self {
            case .idle: return .idle
            case .loading: return .loading
            case .loaded: return .loaded
            case .failed(.notFound): return .failedNotFound
            case .failed(.unavailable): return .failedUnavailable
            case .failed(.unreadable): return .failedUnreadable
            }
        }
    }

    private(set) var state: LoadState = .idle

    /// The editor's undo stack (v3-plan §11.2). Present now, exercised when the
    /// editor lands; read-only playback never registers an undo action, so this
    /// stays empty in C3a.
    let undoManager = UndoManager()

    // MARK: - Injected dependencies

    /// Resolves the entry's bytes. The store-bound binding throws
    /// `RecentsStore.ResolveFailure`; a missing entry throws `.notFound`.
    private let resolve: @MainActor (UUID) async throws -> Data
    /// Parses bytes into the display model off the main actor. `nil` means the
    /// bytes resolved but could not be parsed (`.unreadable`).
    private let parse: @Sendable (Data) -> LoadedMetafile?
    /// The on-disk URL to watch for changes, or `nil` when it can't be resolved
    /// (an imported copy still resolves; only a dead bookmark returns nil).
    private let watchURLProvider: @MainActor (UUID) -> URL?

    @ObservationIgnored private var presenter: DocumentFilePresenter?

    // MARK: - Init

    init(
        entryID: UUID,
        resolve: @escaping @MainActor (UUID) async throws -> Data,
        parse: @escaping @Sendable (Data) -> LoadedMetafile? = { try? MetafileLoader.load($0) },
        watchURLProvider: @escaping @MainActor (UUID) -> URL? = { _ in nil }
    ) {
        self.entryID = entryID
        self.resolve = resolve
        self.parse = parse
        self.watchURLProvider = watchURLProvider
    }

    /// The window-facing initialiser: binds resolution, parsing, and the watch URL
    /// to the shared recents store.
    convenience init(entryID: UUID, store: RecentsStore) {
        self.init(
            entryID: entryID,
            resolve: { [weak store] id in
                guard let store, let entry = store.entry(id: id) else {
                    throw RecentsStore.ResolveFailure.notFound
                }
                return try await store.resolveData(for: entry)
            },
            watchURLProvider: { [weak store] id in
                guard let store, let entry = store.entry(id: id) else { return nil }
                var isStale = false
                return try? URL(
                    resolvingBookmarkData: entry.bookmark,
                    options: RecentsStore.bookmarkResolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
        )
    }

    deinit {
        // The presenter is `@unchecked Sendable`, so a nonisolated deinit may
        // unregister it; stop watching so the file coordinator drops the session.
        presenter?.stop()
    }

    // MARK: - Derived

    var loaded: LoadedMetafile? {
        if case .loaded(let model) = state { return model }
        return nil
    }

    // MARK: - Loading

    /// Resolves and parses the document, driving the state machine. Safe to call
    /// repeatedly (Try Again, a disk change): each call restarts from `.loading`.
    func load() async {
        state = .loading
        let data: Data
        do {
            data = try await resolve(entryID)
        } catch {
            state = .failed(Self.failureReason(for: error))
            stopWatching()
            return
        }

        // Parse off the main actor; the result is Sendable.
        let parse = self.parse
        let model = await Task.detached(priority: .userInitiated) { parse(data) }.value

        if let model {
            state = .loaded(model)
            startWatching()
        } else {
            state = .failed(.unreadable)
            stopWatching()
        }
    }

    /// Maps a resolve error to a failure reason. Only `RecentsStore.ResolveFailure`
    /// is definitive; any other error is treated as transient so the user can
    /// retry. Pure, for the transition tests.
    static func failureReason(for error: Error) -> FailureReason {
        if let resolveFailure = error as? RecentsStore.ResolveFailure {
            switch resolveFailure {
            case .notFound: return .notFound
            case .unavailable: return .unavailable
            }
        }
        return .unavailable
    }

    // MARK: - File-change observation

    private func startWatching() {
        guard let url = watchURLProvider(entryID) else { stopWatching(); return }
        if presenter?.presentedItemURL == url { return }
        presenter?.stop()
        let presenter = DocumentFilePresenter(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDiskChange() }
        }
        presenter.start()
        self.presenter = presenter
    }

    private func stopWatching() {
        presenter?.stop()
        presenter = nil
    }

    /// Read-only reload on an external change. When the editor lands this gains a
    /// dirty-state check before clobbering unsaved edits (v3-plan §11.2 hook).
    private func reloadFromDiskChange() {
        Task { await load() }
    }
}

/// A minimal `NSFilePresenter` that invokes a callback when the watched file
/// changes or moves on disk. `@unchecked Sendable` because the file coordinator
/// calls its methods on the presenter's own operation queue; it holds only an
/// immutable URL, the queue, and a `@Sendable` callback that hops to the main
/// actor, so that access is safe.
final class DocumentFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void
    private var started = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        guard started else { return }
        started = false
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() { onChange() }

    func presentedSubitemDidChange(at url: URL) { onChange() }

    func presentedItemDidMove(to newURL: URL) { onChange() }
}
