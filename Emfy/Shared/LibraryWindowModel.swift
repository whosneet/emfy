import Foundation

/// Per-window state held by reference, so the open coordinator's stored selector
/// closure (which outlives a single `body` evaluation) always targets this window's
/// live selection. A plain `@State` can't be captured that way.
///
/// It also OWNS the window's `DocumentSession` (L4/N1): the session used to live in
/// `ViewerDetail` as `@State`, so an iPad size-class change — which swaps the compact
/// `navigationDestination` push for the regular detail column — rebuilt it and lost the
/// edit mode, undo stack and load. Owning it here, keyed by the selected entry, means the
/// compact push and the regular detail render the SAME instance across that swap. The
/// model also guards every file switch so a dirty document gets its save decision before
/// it is torn down (U1): no more silent data loss on back / sidebar switch.
///
/// Every navigation — select, guarded clear, held-decision resolution and external open —
/// runs through ONE serialising task chain (`navigationChain`), re-checking a request
/// generation after each await so a superseded step coalesces away and the LATEST requested
/// target wins (C-1, C-2, R2U4). Removing the open, dirty document is guarded too, so its
/// edits aren't thrown away (R2U3).
///
/// Foundation-only (no SwiftUI), so the navigation guard, the coalescing and the
/// flush-before-load ordering are unit-tested directly, without a window.
@MainActor
@Observable
final class LibraryWindowModel {
    let windowID = UUID()

    /// A file switch / back / deselect the user asked for while the current document still
    /// needed a save decision (U1). While set, the viewer's existing WMF save-choice dialog
    /// (or the R2U2 save-failure alert) is on screen; resolving it (Save Anyway / Don't Save)
    /// proceeds the navigation and Cancel abandons it, restoring the previous selection.
    struct PendingNavigation: Equatable { let target: UUID? }

    /// A requested navigation target. Wraps the `UUID?` so "no request pending" (`nil`) is
    /// distinct from "deselect requested" (`.some(target: nil)`).
    private struct NavRequest: Equatable { let target: UUID? }

    /// The presented selection — the single source of truth for which entry the window's
    /// viewer shows. Written only through the guarded navigation so an unsaved document is
    /// never torn down without the save guard.
    private(set) var selection: UUID?

    /// The selection the sidebar highlight and the compact push should display — moved to the
    /// requested target the instant a guard-free navigation is requested, so a list tap or
    /// system Back doesn't flicker or re-push while the commit runs, and rolled back to
    /// `selection` when a guarded navigation is held or cancelled (A-B/R2N1).
    private(set) var displayedSelection: UUID?

    /// The live session for `selection`, owned here (not in `ViewerDetail`) so both the
    /// compact push and the regular detail render the SAME instance (L4/N1).
    private(set) var session: DocumentSession?

    private(set) var pendingNavigation: PendingNavigation?

    /// Builds a session for an entry id. Set by `LibraryWindow` as soon as the store and
    /// settings are available; `@ObservationIgnored` because it is wiring, not observable
    /// state. A request that arrives before it is set is deferred and replayed once it is
    /// (A-A), so a selection can never commit with no session to show.
    @ObservationIgnored var sessionFactory: ((UUID) -> DocumentSession)? {
        didSet {
            guard sessionFactory != nil, let deferred = deferredRequest else { return }
            deferredRequest = nil
            select(deferred.target)
        }
    }

    /// A navigation requested before `sessionFactory` was set (A-A), replayed by the factory's
    /// `didSet`. Only the latest matters, so a newer deferred request overwrites an older one.
    @ObservationIgnored private var deferredRequest: NavRequest?

    /// Serialises navigations, so an outgoing session's flush always finishes before the
    /// next session for a file loads — closing the "old session flushes in the background
    /// while the new one loads" stale-read race (L4/N1) — and so select, guarded clear, and
    /// held-decision resolution interleave through one queue rather than racing (C-1).
    @ObservationIgnored private var navigationChain: Task<Void, Never>?

    /// The most recently requested navigation target, bumped by every select/open even while a
    /// decision is held, so resolving the hold proceeds to the LATEST target, not a stale one
    /// (R2U4). Paired with `requestGeneration` for coalescing.
    @ObservationIgnored private var requestedTarget: NavRequest?

    /// Monotonic counter bumped by every navigation request. A queued or mid-await step whose
    /// generation no longer matches has been superseded, so it coalesces away rather than
    /// loading a file the user has already navigated past (C-2, R2U4).
    @ObservationIgnored private var requestGeneration = 0

    /// UI entry point (the sidebar/grid selection binding, the iOS back control, external
    /// opens, New Drawing, Spotlight): request showing `target`. Serialised and coalesced.
    func select(_ target: UUID?) {
        guard sessionFactory != nil else { deferredRequest = NavRequest(target: target); return }
        requestGeneration &+= 1
        let generation = requestGeneration
        requestedTarget = NavRequest(target: target)
        // Guard-free navigations show the target at once (A-B); a held/cancelled guarded one
        // rolls this back. While a decision is already held, leave the display on the current
        // document and just record the latest target (R2U4).
        if pendingNavigation == nil { displayedSelection = target }
        enqueue { await $0.resolveLatest(generation: generation) }
    }

    /// Clears the selection WITHOUT the save guard — for reconciling a selection whose entry
    /// has already been removed because the file is genuinely gone (a not-found prune): there
    /// is nothing to save it to (C4a H8). The guarded path (`handleSelectedEntryRemoved`)
    /// covers a still-dirty editing document whose file still exists (R2U3).
    func clearSelection() {
        pendingNavigation = nil
        requestedTarget = nil
        session?.leaveEditingCompletion = nil
        session = nil
        selection = nil
        displayedSelection = nil
    }

    /// The selected entry was removed from Recents (its tile/sidebar Remove here, Clear
    /// Recents, or a removal in another window). Its file may still exist (an in-place edited
    /// document), so flush any unsaved edits to disk before tearing the session down — never
    /// silently discard them (R2U3). Then clear. Serialised through the navigation chain so it
    /// can't race an in-flight switch (C-1).
    func handleSelectedEntryRemoved() {
        enqueue { model in
            if let session = model.session, session.editing == .editing, session.isDirty {
                await session.flushPendingSave()
            }
            model.clearSelection()
        }
    }

    /// Whether removing `id` needs the save guard first: it is the current selection and its
    /// session is a dirty editing document (R2U3). The removal surfaces call this before they
    /// remove, run `guardRemoval` when it is true, and remove only on a true outcome.
    func removalNeedsGuard(_ id: UUID) -> Bool {
        id == selection && session?.editing == .editing && session?.isDirty == true
    }

    /// Runs the save guard for a remove of the open, dirty document (R2U3): ends editing, which
    /// autosaves a clean EMF and returns `true` (remove proceeds), or — for a WMF/WMZ or a save
    /// error — raises the save-choice dialog and returns `false`, so the removal is aborted and
    /// the user resolves the save on the document first. Awaited by the removal surface.
    func guardRemoval(of id: UUID) async -> Bool {
        guard id == selection, let session, session.editing == .editing else { return true }
        await session.endEditing()
        // Still editing ⇒ a decision is required (a dirty WMF confirmation, or a save error):
        // don't remove under the user's feet. A clean EMF save ended editing ⇒ proceed.
        return session.editing != .editing
    }

    /// Enqueues `operation` onto the single navigation chain, after any in-flight step. The
    /// closure receives `self` so a captured generation can be re-checked after each await.
    private func enqueue(_ operation: @escaping @MainActor (LibraryWindowModel) async -> Void) {
        let previous = navigationChain
        navigationChain = Task { @MainActor in
            await previous?.value
            await operation(self)
        }
    }

    /// The guarded core of a navigation, run from the chain. Coalesces to the latest request:
    /// a step whose generation has been superseded skips, and the current step reads the latest
    /// `requestedTarget` so only the most recent destination loads (C-2, R2U4).
    private func resolveLatest(generation: Int) async {
        guard generation == requestGeneration, let request = requestedTarget else { return }
        await resolveSelection(to: request.target)
    }

    /// The guarded core of a navigation (exposed for unit tests). A clean or read-only
    /// document proceeds at once; an editing document is asked to leave edit mode first —
    /// an EMF saves and proceeds, a WMF/WMZ (or a save error) raises its dialog and the switch
    /// is held pending the user's choice.
    func resolveSelection(to target: UUID?) async {
        guard target != selection, pendingNavigation == nil else { return }
        if let current = session, current.editing == .editing {
            await current.endEditing()
            if current.editing == .editing {
                // endEditing kept us in edit mode: a decision is required. A WMF/WMZ
                // confirmation OR a save error can be resolved from the viewer (the WMF dialog
                // or the R2U2 save-failure alert) — hold the switch and let that resolution
                // proceed it. Anything else leaves the user on the document; don't strand a
                // pending navigation that nothing would clear.
                if current.pendingWMFConfirmation != nil || current.lastSaveError != nil {
                    current.leaveEditingCompletion = { [weak self] didLeave in
                        self?.enqueueLeaveResolved(didLeave)
                    }
                    pendingNavigation = PendingNavigation(target: target)
                    // Keep showing the current document behind the dialog (A-B).
                    displayedSelection = selection
                }
                return
            }
        }
        await commitSelection(to: target)
    }

    /// Routes a held-decision resolution through the navigation chain (C-1), so it can't race
    /// a concurrent select/open.
    private func enqueueLeaveResolved(_ didLeave: Bool) {
        enqueue { await $0.handleLeaveResolved(didLeave) }
    }

    /// Resolves a held navigation once the viewer's dialog decides: `didLeave` proceeds the
    /// switch — to the LATEST requested target, since an open/select during the hold may have
    /// moved it (R2U4) — and Cancel (`false`) abandons it, keeping the current selection.
    func handleLeaveResolved(_ didLeave: Bool) async {
        guard let pending = pendingNavigation else { return }
        pendingNavigation = nil
        if didLeave {
            let target = requestedTarget?.target ?? pending.target
            await commitSelection(to: target)
        } else {
            // Cancelled: keep the current document and roll back the optimistic display (A-B).
            requestedTarget = nil
            displayedSelection = selection
        }
    }

    /// Installs the session for `target`, flushing the outgoing one first. Re-checks the request
    /// generation after each await so a navigation the user has since superseded loads nothing
    /// (C-2). Exposed for the flush-before-load ordering test.
    func commitSelection(to target: UUID?) async {
        let generation = requestGeneration
        pendingNavigation = nil
        let previous = session
        guard let target else {
            if let previous { await previous.flushPendingSave() }
            guard generation == requestGeneration else { return }
            session = nil
            selection = nil
            displayedSelection = nil
            return
        }
        if previous?.entryID == target {
            selection = target
            displayedSelection = target
            return
        }
        // Flush the outgoing session BEFORE the new one loads, so a background flush never
        // races the new load (L4/N1).
        if let previous { await previous.flushPendingSave() }
        // A newer request arrived during the flush: let its queued step load instead (C-2).
        guard generation == requestGeneration else { return }
        guard let factory = sessionFactory else { return }   // no factory yet ⇒ don't strand (A-A)
        let new = factory(target)
        session = new
        selection = target
        displayedSelection = target
        await new.load()
        // A freshly-created drawing opens straight into the editor (E3a design call 4).
        if NewDrawing.consumePendingEdit(target) { await new.beginEditing() }
    }
}
