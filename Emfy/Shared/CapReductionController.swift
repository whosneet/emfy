import Foundation
import Observation

/// Drives the confirmation shown when lowering "Recents to keep" would drop a file
/// Emfy received and holds the only copy of (S1a-5 Library › Recents to keep). The
/// decision is the pure `RecentsCapPolicy.shrink`; this is the sequence around it:
/// lowering that evicts only ordinary (bookmarked) files applies at once, but one
/// that would delete a received copy raises
/// "Save Copies…" / "Reduce Anyway" / "Cancel" first, so no received file is ever
/// deleted silently.
///
/// The invariant it keeps: the picker (`settings.recentsToKeep`) and the store's cap
/// never drift. Any path that does NOT shrink — Cancel, a dismissal, or a failed /
/// cancelled export — restores the picker to the previous value.
///
/// No SwiftUI here, so the logic is unit-tested directly; the `.capReduction`
/// modifier (CapReduction.swift) hosts the alert and exporter and reads
/// `exportFiles` / `isExporting`.
@MainActor
@Observable
final class CapReductionController {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let newCap: Int
        let oldCap: EmfySettings.RecentsCap
        /// The received copies the shrink would delete, offered for "Save Copies…".
        let affected: [RecentEntry]
    }

    var pending: Pending?

    // Folder-export presentation for "Save Copies…". `exportFiles` (name → bytes) is
    // wrapped into a document by the modifier, so this type stays SwiftUI-free.
    var isExporting = false
    var exportFiles: [String: Data] = [:]
    var exportError: String?
    // The caps carried through the async export, so a success shrinks and a
    // cancel/failure restores the picker.
    @ObservationIgnored private var exportTargetCap: Int?
    @ObservationIgnored private var exportOldCap: EmfySettings.RecentsCap?
    @ObservationIgnored private var exportPrepTask: Task<Void, Never>?

    /// Reacts to a change in the Recents-to-keep setting. A shrink that would drop a
    /// received copy raises the confirmation; raising the cap, or a shrink that only
    /// evicts ordinary files, applies immediately. Session-only Private entries are
    /// excluded from the shrink input, so they never count toward the cap (S1a-5 review).
    func handleChange(from old: EmfySettings.RecentsCap, to new: EmfySettings.RecentsCap, store: RecentsStore) {
        let visible = store.entries.filter { !store.privateIDs.contains($0.id) }
        let decision = RecentsCapPolicy.shrink(visible, to: new.count)
        // Under ST3 the cap never evicts an owned (received/New/AI) copy, so
        // `dropsReceivedFile` is always false and the confirmation/export branch below is
        // unreachable — kept as a safety net should the eviction policy ever change.
        if decision.dropsReceivedFile {
            pending = Pending(newCap: new.count, oldCap: old, affected: decision.evictedReceived)
        } else {
            store.applyCap(new.count)
        }
    }

    /// "Reduce Anyway": shrink now, deleting the received copies.
    func reduceAnyway(store: RecentsStore) {
        guard let pending else { return }
        self.pending = nil
        store.applyCap(pending.newCap)
    }

    /// "Save Copies…": gather the affected received files' bytes, then open the
    /// exporter; the shrink happens only when the export succeeds, and a read failure
    /// restores the picker.
    func saveCopiesThenReduce(store: RecentsStore, settings: EmfySettings) {
        guard let pending else { return }
        let affected = pending.affected
        exportTargetCap = pending.newCap
        exportOldCap = pending.oldCap
        self.pending = nil
        exportPrepTask = Task { @MainActor in
            var files: [String: Data] = [:]
            for entry in affected {
                if let data = try? await store.resolveData(for: entry) {
                    files[uniqueName(entry.displayName, in: files)] = data
                }
            }
            guard !files.isEmpty else {
                exportError = "Emfy couldn’t read these files to save copies."
                restore(settings)
                return
            }
            exportFiles = files
            isExporting = true
        }
    }

    /// The folder exporter finished: shrink when the copies were saved; otherwise
    /// (cancelled or failed) restore the picker so it doesn't show a cap the store
    /// never applied.
    func finishExport(success: Bool, store: RecentsStore, settings: EmfySettings) {
        if success, let cap = exportTargetCap {
            exportTargetCap = nil
            exportOldCap = nil
            store.applyCap(cap)
        } else {
            restore(settings)
        }
    }

    /// Cancel, or any dismissal that didn't choose Reduce / Save — restore the picker
    /// and leave Recents untouched. Guards on `pending`, so a dismissal that follows a
    /// Reduce/Save button (which already cleared `pending`) is a no-op, whatever order
    /// the button action and the binding setter run in.
    func cancel(settings: EmfySettings) {
        guard let pending else { return }
        self.pending = nil
        settings.recentsToKeep = pending.oldCap
    }

    /// The confirmation message, naming how many received copies would go.
    func message(_ pending: Pending) -> String {
        let count = pending.affected.count
        let many = count > 1
        let copies = many ? "\(count) files" : "a file"
        return "Keeping only \(pending.newCap) recent \(pending.newCap == 1 ? "file" : "files") would remove \(copies) that came from Mail, Messages or another app, so Emfy holds the only \(many ? "copies" : "copy"). Save \(many ? "them" : "it") first if you want to keep \(many ? "them" : "it")."
    }

    #if DEBUG
    /// Awaits the "Save Copies…" preparation task (gathering bytes), so a test can
    /// assert the export state deterministically before driving `finishExport`.
    func waitForExportPreparationForTesting() async {
        await exportPrepTask?.value
    }
    #endif

    private func restore(_ settings: EmfySettings) {
        if let old = exportOldCap { settings.recentsToKeep = old }
        exportTargetCap = nil
        exportOldCap = nil
    }

    private func uniqueName(_ name: String, in files: [String: Data]) -> String {
        guard files[name] != nil else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if files[candidate] == nil { return candidate }
            index += 1
        }
    }
}
