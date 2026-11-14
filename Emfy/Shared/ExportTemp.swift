import Foundation

/// The temporary directory Emfy stages a shared/exported file in, named so the
/// recents launch sweep can recognise and reclaim stragglers (§e, §j). One place
/// owns the prefix, so the writer and the sweeper never drift.
enum ExportTemp {
    /// Every export temp directory starts with this, under the system temporary
    /// directory, e.g. `…/EmfyExport-<uuid>/`.
    static let prefix = "EmfyExport-"

    /// A fresh, uniquely-named temporary directory for one export.
    static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    }

    /// Deletes every `EmfyExport-*` directory left in the temporary directory
    /// (a share that was interrupted before its own cleanup ran) — but never one
    /// written at/after `startedAt`, so a share sheet staged during a reload isn't
    /// reclaimed out from under it (the C2 sweep race).
    static func sweep(startedAt: Date = Date()) {
        sweepPrefixed(prefix, startedAt: startedAt)
    }

    /// Deletes every directory under the temporary directory whose name starts with
    /// `prefix` (one Emfy staging family — exports, or `EmfyNewDrawing-*` import
    /// stages — ST5), skipping any written at/after `startedAt` so a stage still in
    /// use isn't reclaimed (the C2 sweep race). Shared by the recents launch sweep.
    static func sweepPrefixed(_ prefix: String, startedAt: Date = Date()) {
        let tmp = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let url = tmp.appendingPathComponent(name)
            if wasWritten(after: startedAt, url) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether `url` was created or last modified at/after `cutoff` — i.e. written
    /// after a sweep began, so the sweep must not reclaim it. Shared by the
    /// recents launch sweep and the export-temp sweep. An item whose dates can't
    /// be read is treated as fresh and kept (a sweep never deletes what it can't
    /// date).
    static func wasWritten(after cutoff: Date, _ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) else {
            return true
        }
        guard let newest = [values.contentModificationDate, values.creationDate].compactMap({ $0 }).max() else {
            return true
        }
        return newest >= cutoff
    }
}
