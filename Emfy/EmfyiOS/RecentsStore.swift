import Foundation
import Observation
import UIKit

/// The recents home's source of truth: the remembered files, their persistence,
/// and the open-a-file flow. Lives on the main actor (it drives the grid); all
/// file I/O and rendering run off it in detached tasks and return `Sendable`
/// results.
///
/// Persistence is deliberately simple and crash-safe: the entry list is JSON in
/// Application Support, each thumbnail a PNG in Caches. A corrupt or missing
/// store starts empty — never a crash. Bookmarks that no longer resolve are
/// pruned on use.
@MainActor
@Observable
final class RecentsStore {
    /// One store for the whole app. The app is single-window
    /// (`UIApplicationSupportsMultipleScenes` = false), so there is one scene
    /// against these recents; the shared instance also keeps the data in one
    /// place for the Quick Look extensions later. The navigation path and search
    /// text stay per-scene (`@SceneStorage`); the recents data is app-wide.
    static let shared = RecentsStore()

    /// Remembered files, newest first.
    private(set) var entries: [RecentEntry] = []
    /// A plain-English message for the most recent open failure, shown as an
    /// alert. Cleared when the alert is dismissed.
    var lastErrorMessage: String?

    /// How many recents to keep. Stated cap (primer §8 — bound every list).
    nonisolated static let maxEntries = 50
    /// Thumbnail long-edge cap in pixels — a ~600 px tile is sharp at 2× and
    /// cheap in memory.
    nonisolated static let thumbnailLongEdge = 600

    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var thumbnailCache: [UUID: UIImage] = [:]

    // MARK: - Loading persisted state

    /// Loads the persisted entries once. A missing or corrupt store leaves the
    /// list empty.
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: Self.storeURL()),
              let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.openedAt > $1.openedAt }
    }

    // MARK: - Opening a file

    /// Opens `url` (from the Files picker, a share, or an incoming document),
    /// adds or promotes it in recents, and returns its entry id so the caller
    /// can navigate to the viewer. Returns `nil` and sets `lastErrorMessage`
    /// when the file can't be read.
    func handleOpenedURL(_ url: URL) async -> UUID? {
        // Load the persisted history first: a cold-launch open can arrive before
        // RecentsView's `.task` runs `loadIfNeeded()`, and persisting an
        // empty-then-one-entry list would wipe the real history.
        loadIfNeeded()

        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareAdd(url: url)
        }.value

        guard let prepared else {
            lastErrorMessage = "Emfy couldn’t open “\(url.lastPathComponent)”. The file may be empty, in a format Emfy doesn’t read, or damaged."
            return nil
        }

        let id: UUID
        if let index = entries.firstIndex(where: {
            $0.displayName == prepared.displayName && $0.byteCount == prepared.byteCount
        }) {
            // Promote an existing entry: refresh its bookmark, thumbnail, and time.
            id = entries[index].id
            if let old = entries[index].thumbnailFileName { Self.removeThumbnailFile(old) }
            thumbnailCache[id] = nil
            entries[index].openedAt = prepared.openedAt
            entries[index].bookmark = prepared.bookmark
            entries[index].thumbnailFileName = prepared.thumbnailFileName
            entries[index].formatLabel = prepared.formatLabel
            entries[index].fullFormatName = prepared.fullFormatName
        } else {
            let entry = RecentEntry(
                id: UUID(),
                displayName: prepared.displayName,
                formatLabel: prepared.formatLabel,
                fullFormatName: prepared.fullFormatName,
                byteCount: prepared.byteCount,
                openedAt: prepared.openedAt,
                bookmark: prepared.bookmark,
                thumbnailFileName: prepared.thumbnailFileName
            )
            id = entry.id
            entries.append(entry)
        }

        sortAndCap()
        persist()
        return id
    }

    /// Reads the bytes for an entry by resolving its bookmark off the main
    /// actor. Prunes the entry and throws when it no longer resolves. A stale
    /// bookmark is refreshed in place so the next open resolves cleanly.
    func resolveData(for entry: RecentEntry) async throws -> Data {
        let bookmark = entry.bookmark
        let result = await Task.detached(priority: .userInitiated) {
            Self.resolveBookmark(bookmark)
        }.value
        guard let result else {
            remove(entry.id)
            throw MetafileLoader.UnreadableFile()
        }
        if let refreshed = result.refreshed, !refreshed.isEmpty,
           let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].bookmark = refreshed
            persist()
        }
        return result.data
    }

    func entry(id: UUID) -> RecentEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Thumbnails

    /// The cached thumbnail for an entry, loaded from Caches on first request
    /// and memoised. `nil` when none was rendered.
    func thumbnailImage(for entry: RecentEntry) -> UIImage? {
        if let cached = thumbnailCache[entry.id] { return cached }
        guard let name = entry.thumbnailFileName else { return nil }
        let url = Self.thumbnailsDirectory().appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnailCache[entry.id] = image
        return image
    }

    // MARK: - Removal

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let name = entries[index].thumbnailFileName { Self.removeThumbnailFile(name) }
        thumbnailCache[id] = nil
        entries.remove(at: index)
        persist()
    }

    func clear() {
        for entry in entries {
            if let name = entry.thumbnailFileName { Self.removeThumbnailFile(name) }
        }
        thumbnailCache.removeAll()
        entries.removeAll()
        persist()
    }

    // MARK: - Ordering, cap, persistence

    private func sortAndCap() {
        entries.sort { $0.openedAt > $1.openedAt }
        guard entries.count > Self.maxEntries else { return }
        for entry in entries[Self.maxEntries...] {
            if let name = entry.thumbnailFileName { Self.removeThumbnailFile(name) }
            thumbnailCache[entry.id] = nil
        }
        entries.removeLast(entries.count - Self.maxEntries)
    }

    private func persist() {
        let directory = Self.supportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.storeURL(), options: .atomic)
    }

    // MARK: - Off-main file work (nonisolated)

    /// What `prepareAdd` hands back to the main actor — all `Sendable`.
    private struct PreparedAdd: Sendable {
        let displayName: String
        let formatLabel: String
        let fullFormatName: String
        let byteCount: Int64
        let bookmark: Data
        let thumbnailFileName: String?
        let openedAt: Date
    }

    /// Reads `url` while holding its security scope, confirms it opens through
    /// EMFKit, captures a bookmark, and renders a bounded thumbnail. Returns
    /// `nil` for an unreadable file.
    private nonisolated static func prepareAdd(url: URL) -> PreparedAdd? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Reject here what the viewer could not show, so the user gets a clear
        // alert instead of a broken recents tile. A cheap open/prepare check —
        // no full render — since the thumbnail render below also validates.
        guard MetafileLoader.canOpen(data) else { return nil }

        // A security-scoped bookmark is required to re-open the file later. If it
        // can't be made, reject the add rather than store empty Data (which would
        // resolve to nothing on the next open).
        guard let bookmark = try? url.bookmarkData(), !bookmark.isEmpty else { return nil }
        let names = MetafileFormatLabel.names(for: url.lastPathComponent)

        var thumbnailFileName: String?
        if let png = MetafileLoader.thumbnailPNG(data, maxLongEdge: thumbnailLongEdge) {
            let name = UUID().uuidString + ".png"
            let directory = thumbnailsDirectory()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? png.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil {
                thumbnailFileName = name
            }
        }

        return PreparedAdd(
            displayName: url.lastPathComponent,
            formatLabel: names.short,
            fullFormatName: names.full,
            byteCount: Int64(data.count),
            bookmark: bookmark,
            thumbnailFileName: thumbnailFileName,
            openedAt: Date()
        )
    }

    /// Resolves a bookmark and reads its bytes while scoped. Returns the bytes
    /// and, when the bookmark was stale, a freshly-minted replacement for the
    /// caller to store. `nil` on any failure (a moved, deleted, or
    /// permission-lost file).
    private nonisolated static func resolveBookmark(_ bookmark: Data) -> (data: Data, refreshed: Data?)? {
        guard !bookmark.isEmpty else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let refreshed: Data? = isStale ? try? url.bookmarkData() : nil
        return (data, refreshed)
    }

    // MARK: - Locations (nonisolated)

    private nonisolated static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Emfy", isDirectory: true)
    }

    private nonisolated static func storeURL() -> URL {
        supportDirectory().appendingPathComponent("recents.json")
    }

    private nonisolated static func thumbnailsDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmfyThumbnails", isDirectory: true)
    }

    private nonisolated static func removeThumbnailFile(_ name: String) {
        try? FileManager.default.removeItem(at: thumbnailsDirectory().appendingPathComponent(name))
    }
}
