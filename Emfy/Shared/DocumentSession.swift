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
        /// Definitively gone — the file can't be resolved. The entry is kept so the
        /// viewer can show this state and offer Remove from Recents, which the user
        /// taps to take it out (the store no longer auto-prunes; C4a H8/H4).
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

    /// Increments whenever a *new* loaded model is installed into `state` — but not
    /// on an identical-content reload, which is skipped. Lets the keep-loaded
    /// behaviour be asserted without comparing non-identifiable model values (M4).
    @ObservationIgnored private(set) var modelInstallCount = 0

    /// A fingerprint of the bytes behind the current loaded model, so an external
    /// change that yields identical content is a no-op and the zoom survives (M4).
    @ObservationIgnored private var loadedContentFingerprint: Int?

    /// A content identity for the loaded model, used as the viewer's `.id(...)` so a
    /// *changed*-content reload rebuilds the tiled view (new drawing), while an
    /// identical reload keeps the same id and preserves the zoom (M4). Stable within
    /// a run; changes only when the installed model's bytes change. Read during a
    /// `body` pass that already observes `state`, which changes in lockstep with it.
    var loadedContentID: Int { loadedContentFingerprint ?? 0 }

    /// Bumped on every load/reload; a result from a stale generation is discarded,
    /// so the latest load wins even if an earlier one finishes later (M4).
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var reloadDebounce: Task<Void, Never>?

    /// The editor's undo stack (v3-plan §11.2). Present now, exercised when the
    /// editor lands; read-only playback never registers an undo action, so this
    /// stays empty in C3a.
    let undoManager = UndoManager()

    // MARK: - Injected dependencies

    /// Resolves the entry's bytes. The store-bound binding throws
    /// `RecentsStore.ResolveFailure`; a missing entry throws `.notFound`.
    private let resolve: @MainActor (UUID) async throws -> Data
    /// Parses bytes into the display model off the main actor, honouring the
    /// Rendering options (the WMF embedded-EMF choice changes the content; the
    /// render-time options shape the captured diagnostics). `nil` means the bytes
    /// resolved but could not be parsed (`.unreadable`).
    private let parse: @Sendable (Data, RenderOptions) -> LoadedMetafile?
    /// The on-disk URL to watch for changes, or `nil` when it can't be resolved
    /// (an imported copy still resolves; only a dead bookmark returns nil).
    private let watchURLProvider: @MainActor (UUID) -> URL?

    /// The Rendering options this session prepares and renders with (S1b). Set at
    /// construction from the current settings and updated live via
    /// `applyRenderOptions`. `@ObservationIgnored` because the viewer drives redraws
    /// from the settings directly; the session uses it only to re-prepare.
    @ObservationIgnored private(set) var renderOptions: RenderOptions

    @ObservationIgnored private var presenter: DocumentFilePresenter?

    // MARK: - Init

    init(
        entryID: UUID,
        resolve: @escaping @MainActor (UUID) async throws -> Data,
        parse: @escaping @Sendable (Data, RenderOptions) -> LoadedMetafile? = { try? MetafileLoader.load($0, options: $1) },
        watchURLProvider: @escaping @MainActor (UUID) -> URL? = { _ in nil },
        options: RenderOptions = .default
    ) {
        self.entryID = entryID
        self.resolve = resolve
        self.parse = parse
        self.watchURLProvider = watchURLProvider
        self.renderOptions = options
    }

    /// The window-facing initialiser: binds resolution, parsing, and the watch URL
    /// to the shared recents store. `options` seeds the first prepare so the opening
    /// render already honours the current Rendering settings.
    convenience init(entryID: UUID, store: RecentsStore, options: RenderOptions = .default) {
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
            },
            options: options
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

    /// User-initiated load (first open, Try Again): shows the loading state, then
    /// resolves and parses. Safe to call repeatedly; the latest call wins (M4).
    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        await runLoad(generation: generation, keepingCurrent: false)
    }

    /// The keep-loaded reload (M4): the current rendered model stays on screen until
    /// a new parse succeeds, so a disk change never flashes the loading state or
    /// resets the zoom. Identical content is a no-op; a transient read failure or a
    /// mid-write unreadable file keeps the current model and keeps watching. Exposed
    /// (not private) so the serialisation and keep-loaded behaviour are unit-tested
    /// directly, without the debounce timer.
    func reloadNow() async {
        loadGeneration &+= 1
        await runLoad(generation: loadGeneration, keepingCurrent: true)
    }

    private func runLoad(generation: Int, keepingCurrent: Bool) async {
        let hadModel = loaded != nil
        let data: Data
        do {
            data = try await resolve(entryID)
        } catch {
            guard generation == loadGeneration else { return }
            let reason = Self.failureReason(for: error)
            // During a keep-current reload, a transient failure must not tear down a
            // good render; keep showing it and keep watching so it recovers (M4).
            if keepingCurrent, hadModel, reason != .notFound { return }
            state = .failed(reason)
            // Keep watching for everything but a pruned, definitively-gone file (M4).
            if reason == .notFound { stopWatching() } else { startWatching() }
            return
        }

        // Identical content: skip the parse and the model swap entirely, so the zoom
        // and pan survive a spurious or attribute-only change (M4).
        let fingerprint = Self.fingerprint(of: data)
        if keepingCurrent, hadModel, fingerprint == loadedContentFingerprint {
            guard generation == loadGeneration else { return }
            startWatching()
            return
        }

        // Parse off the main actor; the result is Sendable.
        let parse = self.parse
        let options = renderOptions
        let model = await Task.detached(priority: .userInitiated) { parse(data, options) }.value
        guard generation == loadGeneration else { return }   // a newer load superseded this

        if let model {
            loadedContentFingerprint = fingerprint
            modelInstallCount &+= 1
            state = .loaded(model)
            startWatching()
        } else if keepingCurrent, hadModel {
            // A mid-write partial file reads as unreadable; keep the last good model
            // on screen and keep watching so the completed write recovers (M4).
            startWatching()
        } else {
            loadedContentFingerprint = nil
            state = .failed(.unreadable)
            startWatching()   // keep watching after .unreadable (M4)
        }
    }

    // MARK: - Rendering options (S1b)

    /// Applies new Rendering options and, when they change what a prepare produces
    /// or what the diagnostics say, re-prepares the open file — keeping the current
    /// render on screen until the new one is ready, so there is no loading flash and
    /// the bytes (hence the content fingerprint) are unchanged. Antialiasing is
    /// render-time only and changes neither the prepared content nor the
    /// diagnostics, so it is applied by the viewer's live redraw and skips the
    /// re-prepare. A prepare-affecting change (the WMF embedded-EMF choice) yields a
    /// new `prepared`; the viewer rebuilds its tiles from it through its content
    /// identity, which tracks that choice.
    func applyRenderOptions(_ newOptions: RenderOptions) {
        let old = renderOptions
        guard newOptions != old else { return }
        renderOptions = newOptions
        guard loaded != nil, Self.needsReprepare(from: old, to: newOptions) else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        Task { @MainActor in await reprepare(generation: generation, options: newOptions) }
    }

    /// Whether a change from `old` to `new` options needs a re-prepare: the WMF
    /// embedded-EMF choice changes the content, and the EMF+ arbitration and font
    /// table change the captured render log (the banner and the could-not-show
    /// list). Antialiasing alone does neither, so it never forces a re-prepare.
    static func needsReprepare(from old: RenderOptions, to new: RenderOptions) -> Bool {
        old.useEmbeddedEMF != new.useEmbeddedEMF
            || old.emfPlusArbitration != new.emfPlusArbitration
            || old.fontSubstitutions != new.fontSubstitutions
    }

    /// Re-parses the open file's bytes with `options`, installing the new model
    /// while the old one stays on screen. A transient resolve failure or an
    /// unreadable re-parse keeps the current render (never a flash or a blank). The
    /// content fingerprint is left untouched because the bytes are the same, so the
    /// viewer preserves the zoom for a same-size re-prepare.
    private func reprepare(generation: Int, options: RenderOptions) async {
        let data: Data
        do {
            data = try await resolve(entryID)
        } catch {
            return   // keep the current render; a later change can retry
        }
        guard generation == loadGeneration else { return }
        let parse = self.parse
        let model = await Task.detached(priority: .userInitiated) { parse(data, options) }.value
        guard generation == loadGeneration, let model else { return }
        modelInstallCount &+= 1
        state = .loaded(model)
        startWatching()
    }

    /// A cheap content fingerprint (a seeded hash of the bytes). Stable within one
    /// process run — all the identical-content comparison needs (M4).
    private static func fingerprint(of data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data)
        return hasher.finalize()
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

    /// An external disk change: debounced (~300 ms) and generation-guarded, so a
    /// burst of `presentedItemDidChange` callbacks runs one keep-loaded reload and
    /// the newest wins (M4). When the editor lands this gains a dirty-state check
    /// before clobbering unsaved edits (v3-plan §11.2 hook).
    private func reloadFromDiskChange() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reloadNow()
        }
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
