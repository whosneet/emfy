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
    /// (a share that was interrupted before its own cleanup ran).
    static func sweep() {
        let tmp = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}
