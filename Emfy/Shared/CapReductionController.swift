import Foundation
import Observation

/// Applies a change to "Recents to keep" (S1a-5 Library › Recents to keep).
///
/// Under ST3 (f18399e) the cap never evicts an owned (received / New / AI) copy —
/// `RecentsStore.applyCap` keeps those regardless of the limit — so lowering the cap can
/// only drop ordinary (bookmarked) files, which Emfy doesn't hold the only copy of. The
/// old "Save Copies… / Reduce Anyway / Cancel" confirmation (and its folder exporter) could
/// therefore never fire, so it has been removed; the change now applies at once.
@MainActor
@Observable
final class CapReductionController {
    /// Reacts to a change in the Recents-to-keep setting by committing the new cap. ST3
    /// guarantees no owned copy is ever deleted, so there is nothing to confirm first.
    func handleChange(from old: EmfySettings.RecentsCap, to new: EmfySettings.RecentsCap, store: RecentsStore) {
        store.applyCap(new.count)
    }
}
