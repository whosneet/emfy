import Foundation

/// The per-reason recovery actions and wording a viewer offers for a failed load
/// (C4a H4, A10, M4). Pure and shared so the Mac pane and the iOS screen present
/// the same actions and the same message for each `DocumentSession.FailureReason`,
/// and so the mapping is unit-tested without a view.
enum ViewerFailurePresentation {
    /// A recovery the failed state offers.
    enum Action: Equatable, Hashable, Sendable {
        /// Re-attempt the load (`DocumentSession.load()`).
        case tryAgain
        /// Remove the entry from Recents and dismiss the viewer.
        case remove
    }

    /// The actions for a reason, in display order (primary first).
    ///
    /// - `.notFound`: the store already pruned the entry, so only Remove is useful.
    /// - `.unavailable`: a transient failure (offline, locked, not-yet-downloaded) —
    ///   Try Again, plus Remove to give up.
    /// - `.unreadable`: the bytes resolved but didn't parse. M4 keeps the watcher on
    ///   and offers Try Again too, because a file still being written can read as
    ///   unreadable and recover once the write completes.
    static func actions(for reason: DocumentSession.FailureReason) -> [Action] {
        switch reason {
        case .notFound:
            return [.remove]
        case .unavailable, .unreadable:
            return [.tryAgain, .remove]
        }
    }

    /// Whether the reason offers Try Again.
    static func offersTryAgain(for reason: DocumentSession.FailureReason) -> Bool {
        actions(for: reason).contains(.tryAgain)
    }

    /// The plain-language explanation shown under "Can't show this file". Shared
    /// wording (ported from the Mac's `failureMessage`, H4).
    static func message(for reason: DocumentSession.FailureReason) -> String {
        switch reason {
        case .unavailable:
            return "Emfy couldn’t read this file right now. It may be offline, or on a drive that isn’t connected."
        case .notFound:
            return "This file has moved or been deleted, so Emfy can’t open it."
        case .unreadable:
            return "Emfy opened this file but couldn’t read it as a metafile. It may be empty or damaged."
        }
    }
}
