import CoreGraphics
import EMFEdit
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

    /// The editor's undo stack (v3-plan §11.2). Bridged to the editing layer below:
    /// each applied `SceneCommand` registers one `UndoManager` action, so the system
    /// Edit ▸ Undo/Redo menus and the iPad gestures drive `SceneHistory`. Empty while
    /// read-only (no `beginEditing`).
    let undoManager = UndoManager()

    // MARK: - Editing layer (E2a)

    /// Whether the document can be edited. Viewing is unaffected by `.unavailable`
    /// (an import failure or a file with no liftable content opens read-only).
    enum EditingAvailability: Equatable, Sendable {
        case notEditing
        case unavailable
        case editing
    }
    private(set) var editing: EditingAvailability = .notEditing

    /// The edit history, present only while `editing == .editing`. `@ObservationIgnored`
    /// because the viewer re-renders from `editVersion` (reading the scene value on
    /// every observation would copy the whole scene); the view model reads it through
    /// `editedScene` after an `editVersion` change.
    @ObservationIgnored private(set) var history: SceneHistory?

    /// Bumped on every scene mutation (apply/undo/redo), so the viewer's content id
    /// changes and it re-renders the edited scene (design call E2a-3). Observed.
    private(set) var editVersion = 0

    /// Whether there are unsaved edits relative to the last save (or the opened file).
    private(set) var isDirty = false

    /// Whether the scene differs from the opened version at all (saved OR unsaved
    /// edits). Drives the viewer's "draw the edited scene" decision, so a saved-then-
    /// clean document still shows the edits rather than falling back to the original
    /// prepared model (review #1). Set true on the cheap edit path; recomputed against
    /// the opened scene on the infrequent undo/redo. Observed.
    private(set) var hasDivergedFromOpened = false

    /// The baseline the dirty flag recomputes against — the last saved scene, or the
    /// opened scene before any save.
    @ObservationIgnored private var savedScene: Scene?

    /// The scene exactly as opened, so undo/redo can tell whether the document still
    /// differs from it (review #1).
    @ObservationIgnored private var openedScene: Scene?

    /// The opened bytes, captured at `beginEditing`, for the one-time revert snapshot.
    @ObservationIgnored private var openedBytes: Data?

    /// An external disk change arrived while there were unsaved edits (design call
    /// E2a-8): the viewer shows the "changed on disk" banner and the file is NOT
    /// reloaded until the user chooses.
    private(set) var showsExternalChangeBanner = false

    /// The warnings from the most recent successful save, for the warnings UI
    /// (design call E2a-5). Empty when the last save was clean.
    private(set) var lastSaveWarnings: [ExportWarning] = []

    /// A pending "saved with limitations" notice for a non-WMF explicit save that
    /// produced warnings (review #5). Set only on an explicit save; the viewer toasts
    /// then clears it. `nil` for a clean or autosaved save.
    private(set) var pendingSaveNotice: SaveNotice?

    /// When the last `NSFileVersion` was recorded this session, so idle autosaves are
    /// throttled to at most one version per hour (review #4).
    @ObservationIgnored private var lastVersionDate: Date?

    /// The fingerprint of the bytes our last coordinated write put on disk, so a
    /// presenter event our own write triggers is recognised as ours and ignored (E2b
    /// item 2). `nil` until the first save this session.
    @ObservationIgnored private var lastWrittenFingerprint: Int?

    /// A pending WMF/WMZ first-save confirmation (design call E2a-5); the viewer
    /// presents it. `nil` when none is pending.
    private(set) var pendingWMFConfirmation: WMFSaveConfirmation?
    @ObservationIgnored private var wmfSaveConfirmed = false

    /// Whether the one-time revert snapshot has been taken this session.
    @ObservationIgnored private var snapshotTaken = false

    /// The most recent save failure, toasted by the viewer then cleared (design call
    /// E2a-9).
    private(set) var lastSaveError: DocumentSaveError?

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

    // MARK: - Injected editing dependencies (E2a)

    /// Lifts the opened bytes into an editable `Scene` (off the main actor). Returns
    /// `nil` when the file has no liftable content.
    private let importScene: @Sendable (Data) -> Scene?
    /// Writes the serialised document to disk, excluding the session's own presenter
    /// so the write never triggers a self-reload. The store-bound default resolves the
    /// entry's URL and writes through `NSFileCoordinator`; the default here throws, so
    /// a session with no destination fails typed rather than silently.
    private let writeBytes: @MainActor (_ data: Data, _ presenter: DocumentFilePresenter?, _ recordVersion: Bool) async throws -> Void
    /// The one-time opened-version snapshot store, or `nil` when revert snapshots are
    /// unavailable (e.g. a hostless test that doesn't exercise them).
    private let snapshotStore: RevertSnapshotStore?
    /// Whether to keep the opened version for Revert — the Settings toggle (design
    /// call E2a-7). Read at save time so turning it off takes effect immediately.
    private let keepRevertSnapshot: @MainActor () -> Bool
    /// The document's current file name (for the save format and the snapshot name).
    /// `nil` means there is no save destination.
    private let documentFileName: @MainActor () -> String?
    /// The clock, injected so the version-throttle policy is tested deterministically.
    private let now: @Sendable () -> Date
    private let autosave: AutosaveController

    // MARK: - Init

    init(
        entryID: UUID,
        resolve: @escaping @MainActor (UUID) async throws -> Data,
        parse: @escaping @Sendable (Data, RenderOptions) -> LoadedMetafile? = { try? MetafileLoader.load($0, options: $1) },
        watchURLProvider: @escaping @MainActor (UUID) -> URL? = { _ in nil },
        options: RenderOptions = .default,
        importScene: @escaping @Sendable (Data) -> Scene? = { try? SceneImporter.import(data: $0) },
        writeBytes: @escaping @MainActor (_ data: Data, _ presenter: DocumentFilePresenter?, _ recordVersion: Bool) async throws -> Void = { _, _, _ in throw DocumentSaveError.noDestination },
        snapshotStore: RevertSnapshotStore? = nil,
        keepRevertSnapshot: @escaping @MainActor () -> Bool = { true },
        documentFileName: @escaping @MainActor () -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        autosave: AutosaveController = AutosaveController()
    ) {
        self.entryID = entryID
        self.resolve = resolve
        self.parse = parse
        self.watchURLProvider = watchURLProvider
        self.renderOptions = options
        self.importScene = importScene
        self.writeBytes = writeBytes
        self.snapshotStore = snapshotStore
        self.keepRevertSnapshot = keepRevertSnapshot
        self.documentFileName = documentFileName
        self.now = now
        self.autosave = autosave
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
            options: options,
            writeBytes: { [weak store] data, presenter, recordVersion in
                guard let store, let entry = store.entry(id: entryID) else {
                    throw DocumentSaveError.noDestination
                }
                try await Self.writeThroughBookmark(data, bookmark: entry.bookmark, presenter: presenter, recordVersion: recordVersion)
            },
            snapshotStore: RevertSnapshotStore(directory: store.locations.snapshotsDirectory),
            keepRevertSnapshot: { EmfySettings.shared.keepOpenedVersionForRevert },
            documentFileName: { [weak store] in store?.entry(id: entryID)?.displayName }
        )
    }

    /// Resolves an entry's bookmark to its URL (taking the macOS security scope) and
    /// writes `data` there through the coordinated writer, off the main actor. The
    /// security scope is released as soon as the write returns.
    private static func writeThroughBookmark(
        _ data: Data,
        bookmark: Data,
        presenter: DocumentFilePresenter?,
        recordVersion: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: RecentsStore.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try CoordinatedDocumentWriter.write(data, to: url, presenter: presenter, recordVersion: recordVersion)
        }.value
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

    // MARK: - Editing: begin, mutate, undo bridge (E2a)

    /// The scene the viewer should draw once edits have diverged from the opened
    /// version (saved or unsaved), or `nil` while read-only / unedited. Keyed on
    /// `hasDivergedFromOpened`, NOT `isDirty`, so a saved-then-clean document keeps
    /// showing the edits rather than flashing back to the original prepared model
    /// after an autosave (review #1). Read after an `editVersion` change.
    var editedScene: Scene? {
        guard editing == .editing, hasDivergedFromOpened else { return nil }
        return history?.scene
    }

    /// The edited scene's page size, so the viewer can size its render (design call
    /// E2a-3). `nil` while read-only / unedited.
    var editedPageSize: CGSize? { editedScene?.pageSizeDevice }

    /// The scene currently being edited, whether or not it has diverged from the
    /// opened version — the editor canvas draws and hit-tests against this (design
    /// call E2b-2). `nil` while read-only. Read after an `editVersion` change, since
    /// `history` itself is `@ObservationIgnored`.
    var editingScene: Scene? {
        guard editing == .editing else { return nil }
        return history?.scene
    }

    /// The first `n` editable element ids in z-order — the DEBUG screenshot hook's
    /// pre-selection (design call E2b-8).
    func firstEditableIDs(_ count: Int) -> Set<Int> {
        guard count > 0, let scene = editingScene else { return [] }
        return Set(scene.editableElements.prefix(count).map(\.id))
    }

    /// Every editable element id (⌘A Select All). Exposed as a plain id set so the
    /// Mac pane can select all without importing EMFEdit.
    func allEditableIDs() -> Set<Int> {
        guard let scene = editingScene else { return [] }
        return Set(scene.editableElements.map(\.id))
    }

    /// The first editable text element's id, for the DEBUG text screenshots (the
    /// EMFEdit-free pane can't inspect element kinds itself).
    func firstTextElementID() -> Int? {
        editingScene?.editableElements.first { $0.kind == .text }?.id
    }

    /// The string of a text element, or `nil` — used by the DEBUG text-edit hook from
    /// the EMFEdit-free Mac pane.
    func textString(of id: Int) -> String? {
        editingScene?.elements.first { $0.id == id }?.text?.string
    }

    #if DEBUG
    /// Translates the given elements (device units) through the normal mutation path,
    /// so the screenshot hook can prove a committed transform re-renders the canvas
    /// without constructing a `SceneCommand` in the EMFEdit-free pane.
    func debugTranslate(ids: Set<Int>, dx: Double, dy: Double) {
        guard !ids.isEmpty else { return }
        apply(.translate(ids: ids, dx: dx, dy: dy))
    }

    /// Recolours the given elements through the normal mutation path, for the E2c
    /// recolour-and-delete screenshot (the pane can't name `SceneFill`).
    func debugSetFill(ids: Set<Int>, red: Double, green: Double, blue: Double) {
        guard !ids.isEmpty else { return }
        apply(.setFill(ids: ids, SceneFill(color: SceneColor(red: red, green: green, blue: blue), evenOdd: false)))
    }

    /// Cancels any armed autosave, so a DEBUG capture run never writes on its way out.
    func debugCancelAutosave() { autosave.cancel() }
    #endif

    /// Rasterises the edited scene through `SceneRenderer` for the viewer's edit
    /// preview. Exposed here (rather than importing EMFEdit into the Mac pane, where
    /// `ExportFormat` would clash with the app's own) so the pane stays EMFEdit-free.
    func makeEditedSceneImage(scale: CGFloat) -> CGImage? {
        guard let scene = editedScene else { return nil }
        return SceneRenderer.makeImage(scene, scale: scale)
    }

    /// Enters edit mode: imports the opened bytes into an editable `Scene` off the main
    /// actor. An import failure, or a file with no liftable content, leaves the
    /// document read-only (`.unavailable`) and viewing untouched (design call E2a-1).
    /// E2b's canvas calls this; it is idempotent.
    func beginEditing() async {
        guard editing == .notEditing else { return }
        let data: Data
        do {
            data = try await resolve(entryID)
        } catch {
            editing = .unavailable
            return
        }
        let importScene = self.importScene
        let scene = await Task.detached(priority: .userInitiated) { importScene(data) }.value
        guard let scene, !scene.editableElements.isEmpty else {
            editing = .unavailable
            return
        }
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false   // one group per recorded step, deterministically
        history = SceneHistory(scene: scene)
        savedScene = scene
        openedScene = scene
        openedBytes = data
        isDirty = false
        hasDivergedFromOpened = false
        editVersion &+= 1
        editing = .editing
        DocumentEditRegistry.shared.register(self)
    }

    /// Leaves edit mode (design call E2b-1): flushes any pending save, then discards the
    /// in-memory edit state so the viewer falls back to read-only. A no-op when already
    /// read-only; a file that opened `.unavailable` is reset to `.notEditing` so the Edit
    /// toggle reads as off and can be retried.
    func endEditing() async {
        if editing == .unavailable { editing = .notEditing; return }
        guard editing == .editing else { return }
        await flushPendingSave()
        endEditingState()
    }

    /// The single mutation path for the scene (design call E2a-2). Applies `command`
    /// through `SceneHistory`, bridges one `UndoManager` action per recorded step
    /// (coalesced edits share the step they merged into, so a drag is one undo), marks
    /// the document dirty, and arms the autosave. A refused command leaves the scene
    /// and the undo stack untouched. AI edits will route through here too.
    func apply(_ command: SceneCommand, coalescing key: SceneCoalescingKey? = nil) {
        guard editing == .editing, var updated = history else { return }
        let beforeSteps = updated.undoCount
        do {
            try updated.apply(command, coalescing: key)
        } catch {
            return   // SceneEditError: nothing changed
        }
        history = updated
        // A merge (coalescing into the top step) adds no new UndoManager entry — the
        // step's existing registration already reverses the merged result.
        if updated.undoCount > beforeSteps {
            registerSystemUndo(name: updated.undoActionName ?? command.actionName)
        }
        afterMutation(markDirty: true)
    }

    /// Restores the editor's selection after an undo/redo of a delete. Set by the
    /// canvas/pane to the per-window `EditorModel`'s selection setter; `nil` in a
    /// hostless test unless the test wants to observe the restored ids (design call
    /// E2c-4). `@ObservationIgnored` — it is a wiring hook, not observable state.
    @ObservationIgnored var selectionRestore: ((Set<Int>) -> Void)?

    /// Deletes the selected elements as ONE undoable step and clears the selection
    /// (design call E2c-4). Undo restores both the elements (through `SceneHistory`)
    /// and the selection to those ids; redo deletes and clears again. Routes through
    /// `history.apply(.delete)` like every other edit, but registers its own undo so
    /// the selection travels with the elements.
    func deleteSelection(_ ids: Set<Int>) {
        guard editing == .editing, var updated = history, !ids.isEmpty else { return }
        let before = updated.undoCount
        do {
            try updated.apply(.delete(ids: ids))
        } catch {
            return   // SceneEditError: nothing changed (e.g. a locked element)
        }
        history = updated
        if updated.undoCount > before {
            registerDeleteUndo(restored: ids)
        }
        afterMutation(markDirty: true)
        selectionRestore?([])   // the deleted elements are gone; clear the selection
    }

    private func registerDeleteUndo(restored ids: Set<Int>) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.undoDelete(restored: ids) } }
        undoManager.setActionName(Self.undoDisplayName(.delete))
        undoManager.endUndoGrouping()
    }

    /// Reverses a delete: the elements return and the selection snaps back to them.
    func undoDelete(restored ids: Set<Int>) {
        guard var updated = history, updated.canUndo else { return }
        updated.undo()
        history = updated
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.redoDelete(restored: ids) } }
        undoManager.setActionName(Self.undoDisplayName(.delete))
        afterMutation(markDirty: nil)
        selectionRestore?(ids)
    }

    /// Re-applies a delete: the elements go again and the selection clears.
    func redoDelete(restored ids: Set<Int>) {
        guard var updated = history, updated.canRedo else { return }
        updated.redo()
        history = updated
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.undoDelete(restored: ids) } }
        undoManager.setActionName(Self.undoDisplayName(.delete))
        afterMutation(markDirty: nil)
        selectionRestore?([])
    }

    /// Registers one forward undo action with the system `UndoManager`, wrapped in its
    /// own group so each recorded step is exactly one Edit ▸ Undo entry.
    private func registerSystemUndo(name: SceneActionName) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.systemUndo() } }
        undoManager.setActionName(Self.undoDisplayName(name))
        undoManager.endUndoGrouping()
    }

    /// Reverses one step and registers its redo. Invoked by the system Edit ▸ Undo
    /// (and iPad gestures) through the registered action.
    func systemUndo() {
        guard var updated = history, updated.canUndo else { return }
        let name = updated.undoActionName ?? .move
        updated.undo()
        history = updated
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.systemRedo() } }
        undoManager.setActionName(Self.undoDisplayName(name))
        afterMutation(markDirty: nil)
    }

    /// Re-applies one step and registers its undo. Invoked by Edit ▸ Redo.
    func systemRedo() {
        guard var updated = history, updated.canRedo else { return }
        let name = updated.redoActionName ?? .move
        updated.redo()
        history = updated
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.systemUndo() } }
        undoManager.setActionName(Self.undoDisplayName(name))
        afterMutation(markDirty: nil)
    }

    /// Updates the re-render signal and the dirty flag. `markDirty == true` is the
    /// cheap edit hot path; `nil` recomputes against the saved baseline (O(scene),
    /// used by the infrequent undo/redo) so undoing back to the saved state clears
    /// dirty and redoing re-sets it. Arms the autosave whenever the document is dirty.
    private func afterMutation(markDirty: Bool?) {
        editVersion &+= 1
        if let markDirty {
            isDirty = markDirty
            // An edit always diverges from the opened version (cheap hot path).
            if markDirty { hasDivergedFromOpened = true }
        } else {
            // Undo/redo: recompute against both baselines (O(scene), infrequent).
            isDirty = history?.scene != savedScene
            hasDivergedFromOpened = history?.scene != openedScene
        }
        if isDirty {
            autosave.schedule { [weak self] in await self?.performSave(isAutosave: true) }
        }
    }

    /// A plain-English Edit-menu name for a step (the model never hard-codes display
    /// text; this is the app-side mapping of `SceneActionName`).
    static func undoDisplayName(_ name: SceneActionName) -> String {
        switch name {
        case .move: return "Move"
        case .transform: return "Transform"
        case .delete: return "Delete"
        case .insert: return "Insert"
        case .changeFill: return "Change Fill"
        case .changeStroke: return "Change Stroke"
        case .changeOpacity: return "Change Opacity"
        case .changeText: return "Edit Text"
        case .changeFont: return "Change Font"
        case .group(let key): return key
        }
    }

    // MARK: - Editing: save in place (E2a-4, E2a-5)

    /// An explicit save (Mac File ▸ Save, ⌘S). No-op when read-only or clean.
    func save() async {
        await performSave(isAutosave: false)
    }

    /// Exports the current scene in the file's own format and writes it in place. The
    /// first save of a WMF/WMZ document raises the limitations confirmation instead of
    /// writing (design call E2a-5); an autosave never pops that confirmation — it
    /// leaves a WMF dirty until an explicit save or close confirms once.
    private func performSave(isAutosave: Bool) async {
        guard editing == .editing, let current = history else { return }
        guard isDirty else { return }
        guard let fileName = documentFileName() else { lastSaveError = .noDestination; return }
        let format = EditingSaveFormat.format(fileName: fileName, source: current.scene.source.format)

        let result: ExportResult
        do {
            // `SceneExporter.export` is a typed throw of `SceneExportError`.
            result = try SceneExporter.export(current.scene, as: format)
        } catch {
            lastSaveError = .exportFailed(String(describing: error))
            return
        }

        if EditingSaveFormat.isWMFFamily(format), !wmfSaveConfirmed {
            if isAutosave { return }   // never confirm from a silent autosave
            pendingWMFConfirmation = WMFSaveConfirmation(
                format: format,
                categories: SceneExporter.summarize(result.warnings),
                data: result.data,
                warnings: result.warnings
            )
            return
        }

        await commitWrite(data: result.data, warnings: result.warnings, fileName: fileName, scene: current.scene, isAutosave: isAutosave)
    }

    /// Confirms the pending WMF/WMZ save ("Save Anyway"): writes the stashed bytes and
    /// marks the session confirmed, so later saves in this session write without asking.
    func confirmPendingWMFSave() async {
        guard let pending = pendingWMFConfirmation, let fileName = documentFileName() else { return }
        wmfSaveConfirmed = true
        pendingWMFConfirmation = nil
        await commitWrite(data: pending.data, warnings: pending.warnings, fileName: fileName, scene: history?.scene, isAutosave: false)
    }

    /// Dismisses the pending WMF/WMZ confirmation without writing (Cancel). The
    /// document stays dirty.
    func cancelPendingWMFSave() {
        pendingWMFConfirmation = nil
    }

    /// Exports the current scene in `format` without writing to disk — for "Save a
    /// Copy as EMF…" (the third WMF-confirmation action), which the viewer routes to a
    /// file exporter.
    func sceneExportData(as format: EMFEdit.ExportFormat) -> Data? {
        guard let scene = history?.scene else { return nil }
        return (try? SceneExporter.export(scene, as: format))?.data
    }

    /// Takes the one-time revert snapshot (first save, when the toggle is on), then
    /// writes the bytes in place through the coordinated writer, updates the saved
    /// baseline and the warnings, and clears dirty. A write failure is typed and left
    /// for the viewer to toast.
    private func commitWrite(data: Data, warnings: [ExportWarning], fileName: String, scene: Scene?, isAutosave: Bool) async {
        if !snapshotTaken, keepRevertSnapshot(), let snapshotStore, let openedBytes {
            snapshotStore.writeIfAbsent(entryID: entryID, data: openedBytes, originalFileName: fileName)
            snapshotTaken = true
        }
        // Record an NSFileVersion on every explicit save and flush, and at most once
        // per hour for idle autosaves, so the version store doesn't bloat (review #4).
        let record = Self.shouldRecordVersion(isAutosave: isAutosave, lastVersionDate: lastVersionDate, now: now())
        do {
            try await writeBytes(data, presenter, record)
        } catch let error as DocumentSaveError {
            lastSaveError = error
            return
        } catch {
            lastSaveError = .writeFailed(String(describing: error))
            return
        }
        if record { lastVersionDate = now() }
        // Remember the fingerprint of exactly what we wrote, so the presenter event our
        // own write triggers (replaceItemAt swaps the inode) is recognised as ours and
        // never raises the changed-on-disk banner or a reload (E2b item 2).
        lastWrittenFingerprint = Self.fingerprint(of: data)
        savedScene = scene
        isDirty = false
        lastSaveWarnings = warnings
        lastSaveError = nil
        // A non-WMF explicit save that lost fidelity surfaces a notice (review #5); a
        // silent autosave shows nothing, and does not clear a notice already pending.
        if let notice = Self.saveNotice(isAutosave: isAutosave, warnings: warnings) {
            pendingSaveNotice = notice
        }
        autosave.cancel()
    }

    /// Whether to record an `NSFileVersion` for this write (review #4): always for an
    /// explicit save/flush, and for an idle autosave only once the throttle (1 h) has
    /// elapsed since the last recorded version. Pure, for the policy test.
    nonisolated static func shouldRecordVersion(
        isAutosave: Bool, lastVersionDate: Date?, now: Date, throttle: TimeInterval = 3600
    ) -> Bool {
        guard isAutosave else { return true }
        guard let last = lastVersionDate else { return true }
        return now.timeIntervalSince(last) >= throttle
    }

    /// The "saved with limitations" notice for a save, or `nil` (review #5): only an
    /// explicit save with warnings produces one. Pure, for the policy test.
    nonisolated static func saveNotice(isAutosave: Bool, warnings: [ExportWarning]) -> SaveNotice? {
        guard !isAutosave, !warnings.isEmpty else { return nil }
        return SaveNotice(categories: SceneExporter.summarize(warnings))
    }

    /// Clears the save notice after the viewer has toasted it.
    func clearSaveNotice() { pendingSaveNotice = nil }

    /// Clears the last save error after the viewer has toasted it (so the same error
    /// isn't shown twice).
    func clearSaveError() { lastSaveError = nil }

    /// Flushes any pending edit to disk now — called on window close, app background
    /// and quit (design call E2a-6). A no-op when clean or read-only.
    func flushPendingSave() async {
        autosave.cancel()
        guard editing == .editing, isDirty else { return }
        await performSave(isAutosave: true)
    }

    // MARK: - Editing: revert (E2a-7)

    /// Whether Revert to Opened Version is available (an opened-version snapshot exists).
    var canRevertToOpenedVersion: Bool {
        snapshotStore?.hasSnapshot(for: entryID) ?? false
    }

    /// Restores the opened bytes through the same coordinated write, clears the edit
    /// state and undo, and reloads the document (design call E2a-7). Behind a
    /// confirmation in the UI.
    func revertToOpenedVersion() async {
        guard let snapshotStore, let snapshot = snapshotStore.read(for: entryID) else { return }
        do {
            // Record a version of the current (edited) bytes before restoring, so the
            // edits remain recoverable from the system version browser.
            try await writeBytes(snapshot.data, presenter, true)
        } catch let error as DocumentSaveError {
            lastSaveError = error
            return
        } catch {
            lastSaveError = .writeFailed(String(describing: error))
            return
        }
        endEditingState()
        await load()
    }

    /// Discards the in-memory edit state (used by revert and by "Reload" on the
    /// external-change banner).
    private func endEditingState() {
        autosave.cancel()
        undoManager.removeAllActions()
        history = nil
        savedScene = nil
        openedScene = nil
        openedBytes = nil
        isDirty = false
        hasDivergedFromOpened = false
        wmfSaveConfirmed = false
        snapshotTaken = false
        lastVersionDate = nil
        pendingWMFConfirmation = nil
        pendingSaveNotice = nil
        showsExternalChangeBanner = false
        editVersion &+= 1
        editing = .notEditing
        DocumentEditRegistry.shared.unregister(self)
    }

    // MARK: - Editing: external change banner (E2a-8)

    /// Keeps the in-memory edits and dismisses the "changed on disk" banner.
    func keepMyEdits() {
        showsExternalChangeBanner = false
    }

    /// Discards unsaved edits and reloads the on-disk version (behind a confirmation).
    func reloadDiscardingEdits() async {
        endEditingState()
        await reloadNow()
    }

    /// Whether an external disk change should raise the banner rather than reload: only
    /// when there are unsaved edits (design call E2a-8). Pure, for the transition tests.
    nonisolated static func externalChangeShowsBanner(isEditing: Bool, isDirty: Bool) -> Bool {
        isEditing && isDirty
    }

    // MARK: - File-change observation

    private func startWatching() {
        guard let url = watchURLProvider(entryID) else { stopWatching(); return }
        if presenter?.presentedItemURL == url { return }
        presenter?.stop()
        let presenter = DocumentFilePresenter(url: url) { [weak self] in
            Task { @MainActor in self?.externalDiskChangeDetected() }
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
    /// the newest wins (M4). With unsaved edits it never clobbers them — it raises the
    /// "changed on disk" banner instead and leaves the choice to the user (design call
    /// E2a-8). Our own coordinated writes are excluded by the presenter, so a save
    /// never trips this.
    func externalDiskChangeDetected() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await self.handleExternalChange()
        }
    }

    /// Decides what a presenter event means by COMPARING the on-disk bytes, not by
    /// trusting the event (E2b item 2). Our own saves (`lastWrittenFingerprint`) and
    /// attribute-only / no-content changes (`loadedContentFingerprint`) are ignored —
    /// edit mode survives. Only a genuinely different on-disk content raises the banner
    /// (while there are unsaved edits) or ends editing and reloads (while clean).
    /// Exposed for the transition tests.
    func handleExternalChange() async {
        let data: Data
        do { data = try await resolve(entryID) } catch { return }   // transient; keep state
        let fingerprint = Self.fingerprint(of: data)
        if fingerprint == lastWrittenFingerprint || fingerprint == loadedContentFingerprint { return }
        // A real external content change.
        if editing == .editing {
            if isDirty { showsExternalChangeBanner = true; return }
            // Editing but clean: drop the now-stale edit state before reloading, else the
            // next edit would apply to a stale scene and autosave would overwrite the
            // external change (review #2). E2b re-enters editing on the reloaded bytes.
            endEditingState()
        }
        await reloadNow()
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
