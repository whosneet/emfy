import CoreGraphics
import Foundation
import ImageIO
import Observation
import os

/// The recents home's source of truth: the remembered files, their persistence,
/// and the open-a-file flow. One cross-platform model (C2) compiled for macOS
/// and iOS; the only platform differences are the bookmark's security scope and
/// the store file's data protection. Lives on the main actor (it drives the
/// grid); all file I/O, bookmark resolution, and rendering run off it in detached
/// tasks and return `Sendable` results.
///
/// Persistence is deliberately simple and crash-safe: the entry list is JSON in
/// Application Support, each thumbnail a PNG in Caches. A corrupt store is set
/// aside (never crashes); a bad single entry is skipped. Bookmarks are pruned
/// only when the file is *definitively* gone — a file that is merely offline or
/// not-yet-downloaded is kept so the viewer can offer Try Again.
@MainActor
@Observable
final class RecentsStore {
    /// One store for the whole app.
    static let shared = RecentsStore()

    /// Remembered files, newest first.
    private(set) var entries: [RecentEntry] = []
    /// `true` once the persisted list has been loaded, so the UI can show nothing
    /// (not the empty state) until then — no first-frame "No recent files" flash.
    private(set) var didLoad = false
    /// A plain-English message for the most recent open failure, shown as an
    /// alert. Cleared when the alert is dismissed.
    var lastErrorMessage: String?

    /// How many recents to keep. Stated cap (primer §8 — bound every list).
    nonisolated static let maxEntries = 50
    /// Thumbnail long-edge cap in pixels — a ~600 px tile is sharp at 2× and
    /// cheap in memory.
    nonisolated static let thumbnailLongEdge = 600

    /// Where recents.json, the thumbnail cache, and imported copies live.
    /// Injectable so tests use a temporary container, never the real one.
    let locations: Locations

    @ObservationIgnored private let thumbnailCache = ThumbnailCache()
    @ObservationIgnored private let persistence = RecentsPersistence()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    nonisolated static let log = Logger(subsystem: "com.avneetsingh.emfy", category: "recents")

    init(locations: Locations = .standard) {
        self.locations = locations
    }

    // MARK: - Loading persisted state

    /// Loads the persisted entries once, off the main actor, then runs the launch
    /// sweep. Concurrent callers (the view's `.task` and a cold-launch open) share
    /// one load. A missing store leaves the list empty; an undecodable store is
    /// renamed aside and the list starts empty; individual bad entries are skipped.
    func loadIfNeeded() async {
        if let loadTask { await loadTask.value; return }
        guard !didLoad else { return }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        let locations = self.locations
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadEntries(from: locations)
        }.value
        entries = loaded.sorted { $0.openedAt > $1.openedAt }
        didLoad = true
        scheduleLaunchSweep()
    }

    // MARK: - Opening a file

    /// Opens `url` (from the Files picker, a share, or an incoming document),
    /// adds or promotes it in recents, and returns its entry id so the caller can
    /// navigate to the viewer. Returns `nil` and sets `lastErrorMessage` when the
    /// file can't be read.
    func handleOpenedURL(_ url: URL) async -> UUID? {
        // Load the persisted history first: a cold-launch open can arrive before
        // the view's `.task` runs `loadIfNeeded()`, and persisting an
        // empty-then-one-entry list would wipe the real history.
        await loadIfNeeded()

        let locations = self.locations
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareAdd(url: url, locations: locations)
        }.value

        guard let prepared else {
            lastErrorMessage = "Emfy couldn’t open “\(url.lastPathComponent)”. The file may be empty, in a format Emfy doesn’t read, or damaged."
            return nil
        }

        let token = UUID()
        let id: UUID
        if let index = entries.firstIndex(where: { matches($0, prepared) }) {
            // Promote an existing entry: refresh its bookmark, thumbnail, identity,
            // imported copy, and time. Reclaim the old thumbnail and imported copy
            // if they were replaced.
            id = entries[index].id
            replaceSideFiles(old: entries[index], newThumbnail: prepared.thumbnailFileName, newImported: prepared.importedFileName)
            thumbnailCache.remove(id)
            entries[index].openedAt = prepared.openedAt
            entries[index].bookmark = prepared.bookmark
            entries[index].thumbnailFileName = prepared.thumbnailFileName
            entries[index].importedFileName = prepared.importedFileName
            entries[index].fileIdentity = prepared.fileIdentity
            entries[index].formatLabel = prepared.formatLabel
            entries[index].fullFormatName = prepared.fullFormatName
            entries[index].byteCount = prepared.byteCount
            entries[index].reloadToken = token
        } else {
            let entry = RecentEntry(
                id: UUID(),
                displayName: prepared.displayName,
                formatLabel: prepared.formatLabel,
                fullFormatName: prepared.fullFormatName,
                byteCount: prepared.byteCount,
                openedAt: prepared.openedAt,
                bookmark: prepared.bookmark,
                thumbnailFileName: prepared.thumbnailFileName,
                fileIdentity: prepared.fileIdentity,
                importedFileName: prepared.importedFileName,
                reloadToken: token
            )
            id = entry.id
            entries.append(entry)
        }

        sortAndCap()
        persist()
        return id
    }

    /// Whether a stored entry is the same file as a freshly prepared add. Prefers
    /// durable file identity (§c); falls back to display name + byte size only
    /// when identity is unavailable on either side.
    private func matches(_ entry: RecentEntry, _ prepared: PreparedAdd) -> Bool {
        if let a = entry.fileIdentity, let b = prepared.fileIdentity, !a.isEmpty, !b.isEmpty {
            return a == b
        }
        return entry.displayName == prepared.displayName && entry.byteCount == prepared.byteCount
    }

    // MARK: - Resolving an entry's bytes

    /// The classified outcome of reading an entry. `.notFound` is definitive (the
    /// file is gone or the bookmark can't be resolved) and prunes; `.unavailable`
    /// is transient (offline, not-yet-downloaded, locked, provider error) and is
    /// kept so the viewer can offer Try Again.
    enum ResolveFailure: Error, Equatable, Sendable {
        case notFound
        case unavailable
    }

    /// Reads the bytes for an entry by resolving its bookmark off the main actor.
    /// Prunes the entry and throws `.notFound` only when the file is definitively
    /// gone; throws `.unavailable` (without pruning) for a transient failure. A
    /// stale bookmark is refreshed in place.
    func resolveData(for entry: RecentEntry) async throws -> Data {
        let bookmark = entry.bookmark
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.resolveBookmark(bookmark)
        }.value
        switch outcome {
        case .success(let data, let refreshed):
            if let refreshed, !refreshed.isEmpty,
               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].bookmark = refreshed
                persist()
            }
            return data
        case .notFound:
            remove(entry.id)
            throw ResolveFailure.notFound
        case .unavailable:
            throw ResolveFailure.unavailable
        }
    }

    func entry(id: UUID) -> RecentEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Thumbnails

    /// The already-cached thumbnail for an entry, or `nil` when it isn't in memory
    /// yet. Synchronous and cheap — the grid shows it immediately, then calls
    /// `loadThumbnail(for:)` to fill a miss.
    func cachedThumbnail(for entry: RecentEntry) -> CGImage? {
        thumbnailCache.image(for: entry.id)
    }

    /// The thumbnail for an entry: the in-memory cache, else the cached PNG from
    /// Caches, else a fresh render if Caches was purged (§f, off the main actor).
    /// A regenerated PNG is written back and its name recorded so it persists.
    func loadThumbnail(for entry: RecentEntry) async -> CGImage? {
        if let cached = thumbnailCache.image(for: entry.id) { return cached }

        let locations = self.locations
        let bookmark = entry.bookmark
        let longEdge = Self.thumbnailLongEdge
        let existingName = entry.thumbnailFileName

        let result = await Task.detached(priority: .utility) { () -> (image: CGImage, regeneratedName: String?)? in
            // 1. The cached PNG on disk.
            if let name = existingName,
               let image = Self.loadCGImage(locations.thumbnailsDirectory.appendingPathComponent(name)) {
                return (image, nil)
            }
            // 2. Caches was purged — regenerate from the file itself.
            guard case .success(let data, _) = Self.resolveBookmark(bookmark),
                  let png = MetafileLoader.thumbnailPNG(data, maxLongEdge: longEdge),
                  let image = Self.decodeCGImage(png) else {
                return nil
            }
            let name = UUID().uuidString + ".png"
            try? FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
            let wrote = (try? png.write(to: locations.thumbnailsDirectory.appendingPathComponent(name), options: .atomic)) != nil
            return (image, wrote ? name : nil)
        }.value

        guard let result else { return nil }
        thumbnailCache.insert(result.image, for: entry.id)
        if let name = result.regeneratedName, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].thumbnailFileName = name
            persist()
        }
        return result.image
    }

    // MARK: - Removal

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeSideFiles(for: entries[index])
        thumbnailCache.remove(id)
        entries.remove(at: index)
        persist()
    }

    func clear() {
        for entry in entries { removeSideFiles(for: entry) }
        thumbnailCache.removeAll()
        entries.removeAll()
        persist()
    }

    // MARK: - Ordering, cap, persistence

    private func sortAndCap() {
        entries.sort { $0.openedAt > $1.openedAt }
        guard entries.count > Self.maxEntries else { return }
        for entry in entries[Self.maxEntries...] {
            removeSideFiles(for: entry)
            thumbnailCache.remove(entry.id)
        }
        entries.removeLast(entries.count - Self.maxEntries)
    }

    private func persist() {
        // Snapshot on the main actor, then write on a background actor (§h).
        let snapshot = entries
        let locations = self.locations
        let writer = persistence
        Task { await writer.write(snapshot, to: locations) }
    }

    /// Deletes an entry's cached thumbnail PNG and its imported copy (§b).
    private func removeSideFiles(for entry: RecentEntry) {
        if let name = entry.thumbnailFileName {
            try? FileManager.default.removeItem(at: locations.thumbnailsDirectory.appendingPathComponent(name))
        }
        if let name = entry.importedFileName {
            try? FileManager.default.removeItem(at: locations.importedDirectory.appendingPathComponent(name))
        }
    }

    /// On promotion, deletes an entry's old side files only when they were
    /// replaced, so the entry keeps referencing live files.
    private func replaceSideFiles(old: RecentEntry, newThumbnail: String?, newImported: String?) {
        if let name = old.thumbnailFileName, name != newThumbnail {
            try? FileManager.default.removeItem(at: locations.thumbnailsDirectory.appendingPathComponent(name))
        }
        if let name = old.importedFileName, name != newImported {
            try? FileManager.default.removeItem(at: locations.importedDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Launch sweep (§e)

    /// Deletes thumbnails and imported copies no entry references, and any
    /// EmfyExport-* temp folders, off the main actor.
    private func scheduleLaunchSweep() {
        let locations = self.locations
        let thumbnails = Set(entries.compactMap(\.thumbnailFileName))
        let imported = Set(entries.compactMap(\.importedFileName))
        Task.detached(priority: .background) {
            Self.sweep(locations: locations, keepThumbnails: thumbnails, keepImported: imported)
        }
    }

    nonisolated static func sweep(locations: Locations, keepThumbnails: Set<String>, keepImported: Set<String>) {
        sweepDirectory(locations.thumbnailsDirectory, keeping: keepThumbnails)
        sweepDirectory(locations.importedDirectory, keeping: keepImported)
        ExportTemp.sweep()
    }

    private nonisolated static func sweepDirectory(_ directory: URL, keeping: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keeping.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Off-main file work (nonisolated)

    /// What `prepareAdd` hands back to the main actor — all `Sendable`.
    struct PreparedAdd: Sendable {
        let displayName: String
        let formatLabel: String
        let fullFormatName: String
        let byteCount: Int64
        let bookmark: Data
        let thumbnailFileName: String?
        let importedFileName: String?
        let fileIdentity: String?
        let openedAt: Date
    }

    /// Reads `url` while holding its security scope, confirms it opens through
    /// EMFKit, captures a bookmark, and renders a bounded thumbnail. When the file
    /// arrives somewhere Emfy can't keep accessing it — tmp, an Inbox, or a place
    /// whose scope couldn't be taken (or whose bookmark couldn't be made) — its
    /// bytes are copied into Imported/ and the copy is bookmarked instead (§b).
    /// Returns `nil` for an unreadable file.
    nonisolated static func prepareAdd(url: URL, locations: Locations) -> PreparedAdd? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Reject here what the viewer could not show, so the user gets a clear
        // alert instead of a broken recents tile. A cheap open/prepare check.
        guard MetafileLoader.canOpen(data) else { return nil }

        // Identity is the original file's standardised path, so reopening it (even
        // via a different scoped URL, or after it was imported) promotes the same
        // entry rather than adding a duplicate.
        let identity = url.standardizedFileURL.path
        let fileIdentity = identity.isEmpty ? nil : identity

        // Decide whether to keep a bookmark to the original, or copy the bytes in.
        var bookmark: Data?
        var importedFileName: String?
        if scoped && !isEphemeralLocation(url) {
            bookmark = makeBookmark(for: url)
        }
        if bookmark == nil || bookmark?.isEmpty == true {
            // Scope couldn't be taken, the file is in a disappearing place, or the
            // bookmark couldn't be made: copy the bytes into our container.
            guard let (copyBookmark, copyName) = importCopy(data: data, originalName: url.lastPathComponent, locations: locations) else {
                return nil
            }
            bookmark = copyBookmark
            importedFileName = copyName
        }
        guard let bookmark, !bookmark.isEmpty else { return nil }

        let names = MetafileFormatLabel.names(for: url.lastPathComponent)
        var thumbnailFileName: String?
        if let png = MetafileLoader.thumbnailPNG(data, maxLongEdge: thumbnailLongEdge) {
            let name = UUID().uuidString + ".png"
            try? FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
            if (try? png.write(to: locations.thumbnailsDirectory.appendingPathComponent(name), options: .atomic)) != nil {
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
            importedFileName: importedFileName,
            fileIdentity: fileIdentity,
            openedAt: Date()
        )
    }

    /// Copies `data` into Imported/<uuid>.<ext> and bookmarks the copy. Returns the
    /// bookmark and the copy's file name (for later cleanup), or `nil` on failure.
    private nonisolated static func importCopy(data: Data, originalName: String, locations: Locations) -> (bookmark: Data, fileName: String)? {
        let ext = MetafileFormatLabel.importedExtension(for: originalName)
        let name = UUID().uuidString + "." + ext
        let directory = locations.importedDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(locations.supportDirectory)
            let fileURL = directory.appendingPathComponent(name)
            try data.write(to: fileURL, options: writeOptions)
            guard let bookmark = makeBookmark(for: fileURL), !bookmark.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return (bookmark, name)
        } catch {
            log.error("Failed to import a copy: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether `url` is somewhere files appear transiently — the temporary
    /// directory or an Inbox the system drops copies into — so the original
    /// shouldn't be bookmarked for later.
    nonisolated static func isEphemeralLocation(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if path.hasPrefix(tmp) { return true }
        if path.contains("/tmp/") { return true }
        if standardized.pathComponents.contains("Inbox") { return true }
        return false
    }

    // MARK: - Bookmark resolution and classification (nonisolated)

    enum ResolveOutcome: Sendable {
        case success(data: Data, refreshedBookmark: Data?)
        case notFound
        case unavailable
    }

    /// Resolves a bookmark and reads its bytes while scoped, classifying any
    /// failure. A bookmark that can't be resolved to a URL is treated as gone
    /// (`.notFound`); a read failure is classified — a missing file is `.notFound`,
    /// an undownloaded iCloud placeholder is downloaded and retried, and anything
    /// else (offline, locked, provider error) is `.unavailable`.
    nonisolated static func resolveBookmark(_ bookmark: Data) -> ResolveOutcome {
        guard !bookmark.isEmpty else { return .notFound }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // No URL at all: the target is gone or the bookmark is invalid.
            return .notFound
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let refreshed = isStale ? makeBookmark(for: url) : nil
            return .success(data: data, refreshedBookmark: refreshed)
        } catch {
            // An undownloaded iCloud item: start the download / coordinate a read.
            if isUbiquitousNotDownloaded(url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                if let data = coordinatedRead(url) {
                    let refreshed = isStale ? makeBookmark(for: url) : nil
                    return .success(data: data, refreshedBookmark: refreshed)
                }
                return .unavailable
            }
            return classifyReadFailure(error)
        }
    }

    /// Creates a bookmark with the platform's options (app-scoped, security-scoped
    /// on macOS; a plain data bookmark on iOS). One helper so creation and
    /// resolution always use matching options.
    nonisolated static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Classifies a read failure: a missing file prunes (`.notFound`); anything
    /// else is transient (`.unavailable`). Exposed for tests.
    nonisolated static func classifyReadFailure(_ error: Error) -> ResolveOutcome {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoSuchFile.rawValue || nsError.code == CocoaError.fileNoSuchFile.rawValue {
            return .notFound
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return .notFound
        }
        return .unavailable
    }

    private nonisolated static func isUbiquitousNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    private nonisolated static func coordinatedRead(_ url: URL) -> Data? {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            data = try? Data(contentsOf: readURL, options: .mappedIfSafe)
        }
        return data
    }

    // MARK: - Platform differences (§1)

    #if os(macOS)
    /// macOS files are user-selected outside the sandbox container, so recents
    /// use app-scoped, security-scoped bookmarks (needs the
    /// `files.bookmarks.app-scope` entitlement).
    nonisolated static let usesSecurityScope = true
    nonisolated static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    nonisolated static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    /// iOS bookmarks resolve in place without an explicit security scope (the
    /// behaviour Emfy shipped in I1).
    nonisolated static let usesSecurityScope = false
    nonisolated static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    nonisolated static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    #if os(iOS)
    /// Protect the store and imported copies at rest on iOS; `.atomic` on both.
    nonisolated static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    nonisolated static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    // MARK: - Tolerant decode (§d)

    nonisolated static func loadEntries(from locations: Locations) -> [RecentEntry] {
        guard let data = try? Data(contentsOf: locations.storeURL) else { return [] }
        // Decode entry by entry: a single bad element is skipped, not fatal.
        if let wrappers = try? JSONDecoder().decode([FailableEntry].self, from: data) {
            return wrappers.compactMap(\.entry)
        }
        // The whole file is undecodable (not even an array): set it aside and
        // start empty, rather than discard it silently or crash.
        try? FileManager.default.removeItem(at: locations.corruptStoreURL)
        try? FileManager.default.moveItem(at: locations.storeURL, to: locations.corruptStoreURL)
        log.error("recents.json was undecodable; renamed to recents.corrupt.json")
        return []
    }

    /// Decodes a `RecentEntry` or, on failure, nothing — so a malformed element
    /// doesn't fail the whole array.
    private struct FailableEntry: Decodable {
        let entry: RecentEntry?
        init(from decoder: Decoder) throws {
            entry = try? decoder.singleValueContainer().decode(RecentEntry.self)
        }
    }

    // MARK: - Backup exclusion and image helpers (nonisolated)

    /// Keeps the recents store and imported copies out of device backups (§i).
    /// Application Support is backed up by default, unlike Caches.
    nonisolated static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    nonisolated static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Locations

    /// Where the store keeps its files. Application Support/Emfy for recents.json
    /// and imported copies (backed up, excluded from backup per §i); Caches for
    /// the regenerable thumbnails.
    struct Locations: Sendable {
        var supportDirectory: URL
        var cachesDirectory: URL

        var storeURL: URL { supportDirectory.appendingPathComponent("recents.json") }
        var corruptStoreURL: URL { supportDirectory.appendingPathComponent("recents.corrupt.json") }
        var importedDirectory: URL { supportDirectory.appendingPathComponent("Imported", isDirectory: true) }
        var thumbnailsDirectory: URL { cachesDirectory.appendingPathComponent("EmfyThumbnails", isDirectory: true) }

        static var standard: Locations {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Emfy", isDirectory: true)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return Locations(supportDirectory: support, cachesDirectory: caches)
        }
    }
}

/// An NSCache-backed thumbnail cache with count and cost limits (§g), replacing
/// the plain dictionary. The cost is each image's pixel-buffer size, so the cache
/// drops its largest/least-used images first under memory pressure.
private final class ThumbnailCache {
    private let cache = NSCache<NSUUID, Entry>()

    init() {
        cache.countLimit = 80                       // ≥ the 50-entry recents cap, with headroom
        cache.totalCostLimit = 48 * 1024 * 1024     // ~48 MB of decoded thumbnails
    }

    func image(for id: UUID) -> CGImage? {
        cache.object(forKey: id as NSUUID)?.image
    }

    func insert(_ image: CGImage, for id: UUID) {
        cache.setObject(Entry(image), forKey: id as NSUUID, cost: image.width * image.height * 4)
    }

    func remove(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// NSCache values must be objects; CGImage boxes cleanly in this final class.
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}

/// Serialises recents.json writes off the main actor (§h): the store snapshots
/// its entries and hands the snapshot here, so a burst of changes writes in order
/// without blocking the UI. Persist failures are logged, never swallowed (§d).
private actor RecentsPersistence {
    func write(_ entries: [RecentEntry], to locations: RecentsStore.Locations) {
        do {
            try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
            RecentsStore.excludeFromBackup(locations.supportDirectory)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: locations.storeURL, options: RecentsStore.writeOptions)
        } catch {
            RecentsStore.log.error("Failed to persist recents: \(error.localizedDescription, privacy: .public)")
        }
    }
}
