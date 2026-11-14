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
/// Foundation-only (no SwiftUI), so the navigation guard and the flush-before-load
/// ordering are unit-tested directly, without a window.
@MainActor
@Observable
final class LibraryWindowModel {
    let windowID = UUID()

    /// A file switch / back / deselect the user asked for while the current document still
    /// needed a save decision (U1). While set, the viewer's existing WMF save-choice dialog
    /// is on screen; resolving it (Save Anyway / Don't Save) proceeds the navigation and
    /// Cancel abandons it, restoring the previous selection.
    struct PendingNavigation: Equatable { let target: UUID? }

    /// The presented selection — the single source of truth for which entry the window
    /// shows. Written only through `select(_:)` / `clearSelection()` so an unsaved document
    /// is never torn down without the save guard.
    private(set) var selection: UUID?

    /// The live session for `selection`, owned here (not in `ViewerDetail`) so both the
    /// compact push and the regular detail render the SAME instance (L4/N1).
    private(set) var session: DocumentSession?

    private(set) var pendingNavigation: PendingNavigation?

    /// Builds a session for an entry id. Set by `LibraryWindow` once the store and settings
    /// are available; `@ObservationIgnored` because it is wiring, not observable state.
    @ObservationIgnored var sessionFactory: ((UUID) -> DocumentSession)?

    /// Serialises navigations, so an outgoing session's flush always finishes before the
    /// next session for a file loads — closing the "old session flushes in the background
    /// while the new one loads" stale-read race (L4/N1).
    @ObservationIgnored private var navigationChain: Task<Void, Never>?

    /// UI entry point (the sidebar/grid selection binding, the iOS back control, external
    /// opens, New Drawing, Spotlight): request showing `target`.
    func select(_ target: UUID?) {
        let previous = navigationChain
        navigationChain = Task { @MainActor in
            await previous?.value
            await resolveSelection(to: target)
        }
    }

    /// Clears the selection WITHOUT the save guard — for reconciling a selection whose
    /// entry has already been removed or pruned (the file is gone; there is nothing to save
    /// to). Used by the store-driven removal reconciliation (C4a H8).
    func clearSelection() {
        pendingNavigation = nil
        session?.leaveEditingCompletion = nil
        session = nil
        selection = nil
    }

    /// The guarded core of a navigation (exposed for unit tests). A clean or read-only
    /// document proceeds at once; an editing document is asked to leave edit mode first —
    /// an EMF saves and proceeds, a WMF/WMZ raises its limitations dialog and the switch is
    /// held pending the user's choice.
    func resolveSelection(to target: UUID?) async {
        guard target != selection, pendingNavigation == nil else { return }
        if let current = session, current.editing == .editing {
            await current.endEditing()
            if current.editing == .editing {
                // endEditing kept us in edit mode: a decision is required. Only a WMF/WMZ
                // confirmation can be resolved from the viewer's dialog — hold the switch and
                // let that resolution proceed it. A plain save error (no dialog) leaves the
                // user on the document with the error toasted, so we do not strand a pending
                // navigation that nothing would clear.
                if current.pendingWMFConfirmation != nil {
                    current.leaveEditingCompletion = { [weak self] didLeave in
                        Task { @MainActor in await self?.handleLeaveResolved(didLeave, target: target) }
                    }
                    pendingNavigation = PendingNavigation(target: target)
                }
                return
            }
        }
        await commitSelection(to: target)
    }

    /// Resolves a held navigation once the viewer's dialog decides: `didLeave` proceeds the
    /// switch, Cancel (`false`) abandons it and keeps the current selection.
    func handleLeaveResolved(_ didLeave: Bool, target: UUID?) async {
        guard pendingNavigation != nil else { return }
        pendingNavigation = nil
        if didLeave { await commitSelection(to: target) }
    }

    /// Installs the session for `target`, flushing the outgoing one first. Exposed for the
    /// flush-before-load ordering test.
    func commitSelection(to target: UUID?) async {
        pendingNavigation = nil
        let previous = session
        guard let target else {
            if let previous { await previous.flushPendingSave() }
            session = nil
            selection = nil
            return
        }
        if previous?.entryID == target {
            selection = target
            return
        }
        // Flush the outgoing session BEFORE the new one loads, so a background flush never
        // races the new load (L4/N1).
        if let previous { await previous.flushPendingSave() }
        let new = sessionFactory?(target)
        session = new
        selection = target
        guard let new else { return }
        await new.load()
        // A freshly-created drawing opens straight into the editor (E3a design call 4).
        if NewDrawing.consumePendingEdit(target) { await new.beginEditing() }
    }
}
