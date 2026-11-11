import Foundation

/// The one-time "opened version" snapshot that powers Revert to Opened Version
/// (v3-plan §11.1, design call E2a-7). On the first save of a file opened in Emfy,
/// the opened bytes are copied into `Application Support/Emfy/Snapshots/<entryID>/`
/// alongside a small sidecar (original file name + format), *before* the file is
/// overwritten. The snapshot is written once and never replaced, so a later save
/// keeps the true opened version; it is pruned when its recents entry is removed or
/// evicted (`RecentsStore.removeSideFiles`), and skipped entirely when the Settings
/// toggle "Keep the opened version for Revert" is off.
///
/// A value type with an injected directory, so tests drive it against a temporary
/// container and the store-bound `DocumentSession` points it at
/// `RecentsStore.Locations.snapshotsDirectory`.
struct RevertSnapshotStore: Sendable {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// The original file's name and format, stored next to the bytes so Revert can
    /// restore under the right name even after the entry's display name changed.
    struct Sidecar: Codable, Equatable, Sendable {
        var originalFileName: String
        var createdAt: Date
    }

    private func entryDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func dataURL(_ id: UUID) -> URL {
        entryDirectory(id).appendingPathComponent("opened.bin")
    }
    private func sidecarURL(_ id: UUID) -> URL {
        entryDirectory(id).appendingPathComponent("info.json")
    }

    /// Whether a snapshot already exists for this entry.
    func hasSnapshot(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: dataURL(id).path)
    }

    /// Writes the opened bytes once. A snapshot already present is left untouched —
    /// so the first save creates exactly one snapshot and a second save never
    /// replaces it (design call E2a-7). Returns whether a new snapshot was written.
    @discardableResult
    func writeIfAbsent(entryID id: UUID, data: Data, originalFileName: String) -> Bool {
        guard !hasSnapshot(for: id) else { return false }
        let dir = entryDirectory(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dataURL(id), options: .atomic)
            let sidecar = Sidecar(originalFileName: originalFileName, createdAt: Date())
            if let json = try? JSONEncoder().encode(sidecar) {
                try? json.write(to: sidecarURL(id), options: .atomic)
            }
            Self.excludeFromBackup(dir)
            return true
        } catch {
            return false
        }
    }

    /// The opened bytes and original file name, or `nil` when no snapshot exists.
    func read(for id: UUID) -> (data: Data, originalFileName: String)? {
        guard let data = try? Data(contentsOf: dataURL(id)) else { return nil }
        let name = (try? Data(contentsOf: sidecarURL(id)))
            .flatMap { try? JSONDecoder().decode(Sidecar.self, from: $0) }?
            .originalFileName ?? id.uuidString
        return (data, name)
    }

    /// Deletes an entry's snapshot (called when the recents entry is removed, cleared
    /// or evicted).
    func prune(entryID id: UUID) {
        try? FileManager.default.removeItem(at: entryDirectory(id))
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
