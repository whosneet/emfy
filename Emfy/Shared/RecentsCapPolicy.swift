import Foundation

/// The cap-shrink decision for the recents library (S1a Library › How many
/// recents to keep).
///
/// Given the current entries and a new (smaller) cap, it reports exactly which
/// entries the cap would evict and whether any of them is a received copy — the
/// signal the UI uses to show the "Save a Copy…" confirmation before shrinking
/// (owner §9.3). It reuses `RecentsStore.entriesToEvict` so the preview and the
/// real eviction can never diverge: pinned entries are exempt, the oldest
/// unpinned non-received go first, and a received copy (Emfy's only copy) only
/// when nothing else is left to drop.
enum RecentsCapPolicy {
    struct ShrinkDecision: Equatable, Sendable {
        /// The entries the new cap would drop. Empty when nothing is over the cap.
        let evicted: [RecentEntry]

        /// Whether any evicted entry is a received copy (Emfy holds the only copy
        /// of it), which must be confirmed before it is deleted.
        var dropsReceivedFile: Bool {
            evicted.contains { $0.importedFileName != nil }
        }

        /// The evicted entries that are received copies — the ones a "Save Copies…"
        /// confirmation offers to export before the shrink deletes them.
        var evictedReceived: [RecentEntry] {
            evicted.filter { $0.importedFileName != nil }
        }
    }

    /// What shrinking `entries` to `newCap` would evict.
    static func shrink(_ entries: [RecentEntry], to newCap: Int) -> ShrinkDecision {
        ShrinkDecision(evicted: RecentsStore.entriesToEvict(from: entries, max: newCap))
    }
}
