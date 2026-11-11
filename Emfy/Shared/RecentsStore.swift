import CoreGraphics
import Foundation
import ImageIO
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Posts a VoiceOver announcement cross-platform, only while VoiceOver is running.
/// A shared helper so `RecentsStore.togglePin` (A-M3) and the Settings diagnostic row
/// (A-L5) announce consistently. Lives here rather than in a SwiftUI file so the
/// logic-test bundle — which compiles `RecentsStore` but not the UI — still resolves
/// it.
enum AccessibilityAnnouncement {
    @MainActor
    static func post(_ message: String) {
        #if os(macOS)
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        #else
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

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

    /// The ids of entries opened during this launch while Private mode was on
    /// (S1a-5). They sit in `entries` for the session but are never persisted,
    /// have no on-disk thumbnail, and vanish when Private mode turns off or the app
    /// quits. Observed so the "Private" section updates as they come and go.
    private(set) var privateIDs: Set<UUID> = []

    /// The live recents cap, synced from `EmfySettings.recentsToKeep` by the app
    /// (S1a-5). Defaults to the historical 50 so the model, its tests, and any code
    /// that doesn't set it behave exactly as before. Used by `sortAndCap` and
    /// `applyCap`.
    @ObservationIgnored var capLimit: Int = maxEntries

    /// Private mode (S1a-5): while on, no recents.json write and no thumbnail PNG
    /// touches the disk; opens become session-only `privateIDs` entries. Set by the
    /// app from `EmfySettings.privateMode`; toggle through `setPrivate`.
    @ObservationIgnored private(set) var isPrivate = false

    /// How many recents to keep. Stated cap (primer §8 — bound every list).
    nonisolated static let maxEntries = 50
    /// Thumbnail long-edge cap in pixels — a ~600 px tile is sharp at 2× and
    /// cheap in memory.
    nonisolated static let thumbnailLongEdge = 600

    /// The prefix of this app's per-launch Private-import staging directories under
    /// the system temporary directory (S-M3). The launch sweep reclaims any left by
    /// a crash or a kill that skipped the quit/background cleanup.
    nonisolated static let privateImportPrefix = "EmfyPrivate-"
    /// This launch's Private-import directory — one per process, under the temporary
    /// directory so a copy of a file opened in Private mode never persists past the
    /// session. Deleted on Mac quit and iOS scene background/termination, and any
    /// straggler is swept on the next launch (S-M3).
    nonisolated static let privateImportLaunchDirectory: URL =
        FileManager.default.temporaryDirectory
            .appendingPathComponent(privateImportPrefix + UUID().uuidString, isDirectory: true)

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
        // Complete the launch sweep before signalling the store is loaded, so a
        // cold-launch open (which awaits `loadIfNeeded` before importing its
        // copy) can't have that freshly written copy or thumbnail deleted by a
        // still-running sweep (the C2 race).
        await runLaunchSweep()
        didLoad = true
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

        if isPrivate { return await handleOpenedURLPrivate(url) }

        let locations = self.locations
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareAdd(url: url, locations: locations)
        }.value

        guard let prepared else {
            lastErrorMessage = "Emfy couldn’t open “\(url.lastPathComponent)”. The file may be empty, in a format Emfy doesn’t read, or damaged."
            return nil
        }

        // Private mode can turn on during the detached prepare. Honour the state as it
        // is now, not when the open began: reclaim the disk copy/thumbnail this
        // non-private prepare wrote and redo the open as a session-only entry, so no
        // persisted write or on-disk thumbnail survives for a file the user now wants
        // private (S-L2).
        if isPrivate {
            deletePreparedSideFiles(prepared)
            return await handleOpenedURLPrivate(url)
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

    // MARK: - Private mode (S1a-5)

    /// Opens a file while Private mode is on: it joins `entries` as a session-only
    /// `privateIDs` entry — a fresh entry every time (never promoting or evicting
    /// persisted history), with its thumbnail held in memory only. Nothing is written
    /// to recents.json and no thumbnail PNG lands on disk; an imported copy (ephemeral
    /// sources) goes to this launch's temporary `EmfyPrivate-*` directory — never
    /// Imported/ — which is deleted on quit/background and swept on the next launch,
    /// and `purgeSessionPrivate` deletes the copy the moment Private mode turns off (S-M3).
    private func handleOpenedURLPrivate(_ url: URL) async -> UUID? {
        let locations = self.locations
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepareAdd(url: url, locations: locations, isPrivate: true)
        }.value
        guard let prepared else {
            lastErrorMessage = "Emfy couldn’t open “\(url.lastPathComponent)”. The file may be empty, in a format Emfy doesn’t read, or damaged."
            return nil
        }
        // Private mode can turn off during the detached prepare — `purgeSessionPrivate`
        // may have already run, so adding this now would leave a session-private entry
        // lingering after Private turned off. Reclaim the temp copy and redo the open
        // as a normal persisted entry instead (S-L2).
        guard isPrivate else {
            deletePreparedSideFiles(prepared)
            return await handleOpenedURL(url)
        }
        let entry = RecentEntry(
            id: UUID(),
            displayName: prepared.displayName,
            formatLabel: prepared.formatLabel,
            fullFormatName: prepared.fullFormatName,
            byteCount: prepared.byteCount,
            openedAt: prepared.openedAt,
            bookmark: prepared.bookmark,
            thumbnailFileName: nil,
            fileIdentity: prepared.fileIdentity,
            importedFileName: prepared.importedFileName,
            reloadToken: UUID()
        )
        if let png = prepared.thumbnailPNGData, let image = Self.decodeCGImage(png) {
            thumbnailCache.insert(image, for: entry.id)
        }
        entries.append(entry)
        entries.sort { $0.openedAt > $1.openedAt }
        privateIDs.insert(entry.id)
        // No sortAndCap, no persist: Private opens never touch disk or evict history.
        return entry.id
    }

    /// Whether an entry is a session-only Private-mode entry (S1a-5).
    func isSessionPrivate(_ id: UUID) -> Bool { privateIDs.contains(id) }

    /// Entries that are not session-private, newest-first order preserved. Surfaces
    /// that must not reveal — or persist a copy of — a Private-mode open use this:
    /// the Mac File ▸ Open Recent menu, its enabled state, and the Clear Recents
    /// counts and Save-a-Copy loop (S-M2). The library itself still shows Private
    /// entries, marked, via `entries`.
    var nonPrivateEntries: [RecentEntry] { entries.filter { !privateIDs.contains($0.id) } }

    /// Turns Private mode on or off (synced from `EmfySettings.privateMode`). Turning
    /// it off drops every session-only entry and reclaims its side files; the persisted
    /// history is untouched throughout.
    func setPrivate(_ on: Bool) {
        guard isPrivate != on else { return }
        isPrivate = on
        if !on { purgeSessionPrivate() }
    }

    /// Drops all session-only Private entries and deletes their in-memory thumbnails
    /// and any imported copy. The persisted list is already correct (Private opens
    /// never wrote to it), so the trailing `persist()` only re-asserts it.
    private func purgeSessionPrivate() {
        guard !privateIDs.isEmpty else { return }
        let ids = privateIDs
        privateIDs = []
        for id in ids where entries.contains(where: { $0.id == id }) {
            if let entry = entries.first(where: { $0.id == id }) { removeSideFiles(for: entry) }
            thumbnailCache.remove(id)
        }
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    // MARK: - Pinning (S1a-5)

    /// Whether an entry is pinned to the top of the library.
    func isPinned(_ id: UUID) -> Bool { entries.first { $0.id == id }?.isPinned ?? false }

    /// Pins or unpins an entry and persists it (`isPinned` in recents.json). Pinned
    /// entries are exempt from the recents cap (see `entriesToEvict`).
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned = pinned
        persist()
    }

    /// Flips an entry's pinned state. The single entry point every surface calls (the
    /// grid tile's UIKit menu and VoiceOver action, the list row, the sidebar row), so
    /// the VoiceOver announcement posted here covers all three consistently (A-M3).
    func togglePin(_ id: UUID) {
        let nowPinned = !isPinned(id)
        setPinned(id, nowPinned)
        if let name = entries.first(where: { $0.id == id })?.baseName {
            AccessibilityAnnouncement.post(nowPinned ? "Pinned \(name)" : "Unpinned \(name)")
        }
    }

    // MARK: - Recents cap (S1a-5)

    /// Applies a new recents cap now, evicting over-cap entries (oldest unpinned
    /// non-received first, received copies last, pinned exempt — `entriesToEvict`)
    /// and deleting their side files, then persisting. Returns what it evicted so the
    /// caller can report it. Session-only Private entries are excluded from the cap
    /// accounting, so they are never counted or evicted (S1a-5 review). The
    /// confirmation before dropping a received copy is the UI's
    /// (`CapReductionController`); this is the commit.
    @discardableResult
    func applyCap(_ newCap: Int) -> [RecentEntry] {
        capLimit = newCap
        let evicted = Self.entriesToEvict(from: entries.filter { !privateIDs.contains($0.id) }, max: newCap)
        guard !evicted.isEmpty else { return [] }
        let ids = Set(evicted.map(\.id))
        for entry in evicted {
            removeSideFiles(for: entry)
            thumbnailCache.remove(entry.id)
        }
        entries.removeAll { ids.contains($0.id) }
        persist()
        return evicted
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
            // The entry is NOT auto-pruned here: doing so while the viewer is loading
            // this very entry would trip the H8 selection reconciliation and dismiss
            // the viewer before its failed(.notFound) state — with its "Remove from
            // Recents" action — could ever show (C4a H8/H4). The viewer surfaces the
            // failure and the user's Remove takes it out; a background prune on a
            // missing file would be indistinguishable from an external removal.
            throw ResolveFailure.notFound
        case .unavailable:
            throw ResolveFailure.unavailable
        }
    }

    func entry(id: UUID) -> RecentEntry? {
        entries.first { $0.id == id }
    }

    #if DEBUG
    /// Seeds `count` *received* EMF entries for UI testing (DEBUG only — excluded
    /// from Release). Each is written to the temporary directory, so `handleOpenedURL`
    /// imports a copy and the entry reads as "received" (Emfy holds the only copy) —
    /// the H3 removal/Save-a-Copy path. Driven by the `EMFY_SEED_RECEIVED` launch env.
    func seedReceivedForUITesting(count: Int) async {
        for index in 0..<count {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("UISample-\(index + 1)-\(UUID().uuidString).emf")
            try? Self.uiTestEMF().write(to: url)
            _ = await handleOpenedURL(url)
        }
    }

    /// Seeds *received* entries from existing files on disk (DEBUG only), for UI
    /// testing and screenshots. Each file's bytes are copied into the temporary
    /// directory first, so `handleOpenedURL` imports its own copy and the entry
    /// reads as "received" — the same path as `seedReceivedForUITesting`. Driven by
    /// the `EMFY_SEED_FILES` launch env (colon-separated absolute paths); the
    /// original file extension is preserved so format detection is unchanged.
    /// Missing or unreadable paths are skipped.
    func seedReceivedFilesForUITesting(paths: [String]) async {
        for path in paths where !path.isEmpty {
            let source = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: source) else { continue }
            // Copy into a unique temporary subdirectory under the file's REAL name, so
            // the seeded entry (and every screenshot) shows the original file name
            // rather than a "UISeed-<UUID>-" prefix.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("UISeed-\(UUID().uuidString)", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            let dest = dir.appendingPathComponent(source.lastPathComponent)
            guard (try? data.write(to: dest)) != nil else { continue }
            _ = await handleOpenedURL(dest)
        }
    }

    /// Drops the in-memory thumbnail cache WITHOUT removing entries or their on-disk
    /// PNGs, to simulate an NSCache eviction under memory pressure for the P4
    /// eviction-reload test (review #3). DEBUG only — not a shipping affordance.
    func evictThumbnailCacheForTesting() {
        thumbnailCache.removeAll()
    }

    /// A minimal but valid EMF (EMR_HEADER + EMR_EOF) for the seed hook.
    nonisolated private static func uiTestEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(1); u32(88)
        i32(0); i32(0); i32(399); i32(299)
        i32(0); i32(0); i32(2117); i32(2117)
        u32(0x464D4520); u32(0x0001_0000); u32(108); u32(2)
        u16(1); u16(0); u32(0); u32(0); u32(0)
        i32(1920); i32(1080); i32(508); i32(286)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }
    #endif

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
        // A session-only Private entry never writes a PNG to disk: regenerate it in
        // memory and keep it off the cache file (S1a-5).
        let allowDiskWrite = !privateIDs.contains(entry.id)

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
            guard allowDiskWrite else { return (image, nil) }
            let name = UUID().uuidString + ".png"
            try? FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
            let wrote = (try? png.write(to: locations.thumbnailsDirectory.appendingPathComponent(name), options: .atomic)) != nil
            return (image, wrote ? name : nil)
        }.value

        guard let result else { return nil }
        thumbnailCache.insert(result.image, for: entry.id)
        if let name = result.regeneratedName, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].thumbnailFileName = name
            // A Caches purge can regenerate many tiles at once; coalesce so a burst
            // of regenerations writes recents.json once, not once per tile (P8).
            persistCoalesced()
        }
        return result.image
    }

    // MARK: - Removal (deferred deletion + undo — C4a H3)

    /// A single removal awaiting its undo window. The entry is already out of
    /// `entries` (so the UI updates at once), but its side files are NOT deleted
    /// yet — Undo restores both, and only the commit on timeout deletes them.
    struct PendingRemoval: Sendable {
        let entry: RecentEntry
        /// The entry's position before removal, so Undo restores it in place.
        let index: Int
    }
    @ObservationIgnored private(set) var pendingRemoval: PendingRemoval?
    @ObservationIgnored private var removalCommitTask: Task<Void, Never>?

    /// How long a single removal can be undone before its side files are deleted.
    nonisolated static let undoWindowSeconds: Double = 5

    /// Whether an entry is a received copy (Emfy holds the only copy of it).
    func isReceived(_ id: UUID) -> Bool {
        entries.first { $0.id == id }?.importedFileName != nil
    }

    /// Removes an entry from the list immediately but defers deleting its side
    /// files until the undo window expires, so `undoLastRemoval()` can restore the
    /// entry *and* its file (C4a H3). Any earlier pending removal is committed first.
    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        commitPendingRemoval()
        let entry = entries[index]
        // Drop the in-memory thumbnail (it regenerates from the kept PNG on undo).
        thumbnailCache.remove(id)
        entries.remove(at: index)
        pendingRemoval = PendingRemoval(entry: entry, index: index)
        persist()
        scheduleCommit()
    }

    /// Restores the most recently removed entry and its file, cancelling the
    /// pending deletion of its side files.
    func undoLastRemoval() {
        guard let pending = pendingRemoval else { return }
        removalCommitTask?.cancel()
        removalCommitTask = nil
        pendingRemoval = nil
        let index = min(max(pending.index, 0), entries.count)
        entries.insert(pending.entry, at: index)
        sortAndCap()
        persist()
    }

    /// Finalises a pending removal now: deletes its side files. Called on timeout,
    /// before a new removal, and before a clear.
    func commitPendingRemoval() {
        guard let pending = pendingRemoval else { return }
        removalCommitTask?.cancel()
        removalCommitTask = nil
        pendingRemoval = nil
        removeSideFiles(for: pending.entry)
    }

    private func scheduleCommit() {
        removalCommitTask?.cancel()
        let window = Self.undoWindowSeconds
        removalCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
        }
    }

    func clear() {
        commitPendingRemoval()
        for entry in entries { removeSideFiles(for: entry) }
        thumbnailCache.removeAll()
        entries.removeAll()
        persist()
    }

    // MARK: - Ordering, cap, persistence

    /// Chooses which entries to drop when the list is over `max` (C4a H3 cap policy,
    /// owner decision): evict the oldest *non-received* entries first, and a received
    /// entry (`importedFileName != nil`, Emfy's only copy) only when no non-received
    /// entry is left to drop. Pinned entries are **exempt** (S1a Library extras), so
    /// they are never candidates — a library heavy with pins can sit above the cap.
    /// Pure, for the cap test. Behaviour is unchanged for data without pins.
    nonisolated static func entriesToEvict(from entries: [RecentEntry], max: Int) -> [RecentEntry] {
        let overflow = entries.count - Swift.max(max, 0)
        guard overflow > 0 else { return [] }
        let candidates = entries.filter { !($0.isPinned ?? false) }
        let oldestFirst = candidates.sorted { $0.openedAt < $1.openedAt }
        let nonReceived = oldestFirst.filter { $0.importedFileName == nil }
        let received = oldestFirst.filter { $0.importedFileName != nil }
        var evict = Array(nonReceived.prefix(overflow))
        if evict.count < overflow {
            evict.append(contentsOf: received.prefix(overflow - evict.count))
        }
        return evict
    }

    private func sortAndCap() {
        entries.sort { $0.openedAt > $1.openedAt }
        // Session-only Private entries never count toward the cap (S1a-5 review).
        let evicted = Self.entriesToEvict(from: entries.filter { !privateIDs.contains($0.id) }, max: capLimit)
        guard !evicted.isEmpty else { return }
        let evictedIDs = Set(evicted.map(\.id))
        for entry in evicted {
            removeSideFiles(for: entry)
            thumbnailCache.remove(entry.id)
        }
        entries.removeAll { evictedIDs.contains($0.id) }
    }

    @ObservationIgnored private var lastPersistTask: Task<Void, Never>?

    private func persist() {
        // Private entries are never written (S1a-5 review): only the persisted,
        // non-private entries are snapshotted. The write ALWAYS runs — a removal, pin
        // or cap change to a persisted entry during Private mode must still reach disk,
        // so a quit mid-session can't leave a dangling entry whose file was deleted.
        let snapshot = entries.filter { !privateIDs.contains($0.id) }
        let locations = self.locations
        let writer = persistence
        // Chain writes so they complete in submission order (the persistence actor
        // alone doesn't order separately-spawned tasks). The last task completing then
        // implies all prior writes did, which a test can await deterministically.
        let previous = lastPersistTask
        lastPersistTask = Task {
            await previous?.value
            await writer.write(snapshot, to: locations)
        }
    }

    #if DEBUG
    /// Awaits the most recently scheduled recents.json write (DEBUG only), so a test
    /// observes persistence deterministically rather than racing the background write.
    func waitForPersistenceForTesting() async {
        await lastPersistTask?.value
    }
    #endif

    @ObservationIgnored private var persistCoalesceTask: Task<Void, Never>?

    /// A debounced persist for high-frequency, non-critical updates — currently the
    /// thumbnail-regeneration path, where many tiles can each update their cached
    /// name after a Caches purge. A short delay collapses the burst into one write;
    /// the name is only a pointer into the regenerable Caches, so a dropped write on
    /// quit just re-regenerates next launch (P8).
    private func persistCoalesced() {
        persistCoalesceTask?.cancel()
        persistCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Deletes an entry's cached thumbnail PNG, its imported copy (§b), and its
    /// one-time revert snapshot (E2a-7), so removing or evicting an entry leaves no
    /// orphaned side files.
    private func removeSideFiles(for entry: RecentEntry) {
        if let name = entry.thumbnailFileName {
            try? FileManager.default.removeItem(at: locations.thumbnailsDirectory.appendingPathComponent(name))
        }
        if let name = entry.importedFileName {
            // A Private-mode import lives in the per-launch temp directory, a normal
            // one in Imported/; the name is a UUID, so removing from both is safe (S-M3).
            try? FileManager.default.removeItem(at: locations.importedDirectory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: locations.privateImportedDirectory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(
            at: locations.snapshotsDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        )
    }

    /// Deletes the disk side files a `prepareAdd` wrote — the thumbnail PNG and the
    /// imported copy (in either import directory) — for the rare case where Private
    /// mode flipped during the detached prepare and the result must be discarded and
    /// redone through the other path (S-L2).
    private func deletePreparedSideFiles(_ prepared: PreparedAdd) {
        if let name = prepared.thumbnailFileName {
            try? FileManager.default.removeItem(at: locations.thumbnailsDirectory.appendingPathComponent(name))
        }
        if let name = prepared.importedFileName {
            try? FileManager.default.removeItem(at: locations.importedDirectory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: locations.privateImportedDirectory.appendingPathComponent(name))
        }
    }

    /// Deletes this launch's Private-import staging directory and everything in it
    /// (S-M3). Called on Mac quit and iOS scene background/termination, so a file
    /// opened in Private mode leaves no copy behind. Idempotent.
    func clearPrivateImports() {
        try? FileManager.default.removeItem(at: locations.privateImportedDirectory)
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

    /// Reclaims orphaned thumbnails, imported copies, and export temp folders off
    /// the main actor, and returns only once the sweep has completed — so a
    /// caller that awaits it (`performLoad`, and therefore `loadIfNeeded`) is
    /// guaranteed the sweep is done before any later write. The cutoff is captured
    /// before the sweep starts, so even a file written by a *concurrent* writer
    /// after that moment is never reclaimed.
    private func runLaunchSweep() async {
        let locations = self.locations
        let keepThumbnails = Set(entries.compactMap(\.thumbnailFileName))
        let keepImported = Set(entries.compactMap(\.importedFileName))
        let startedAt = Date()
        await Task.detached(priority: .utility) {
            Self.sweep(locations: locations, keepThumbnails: keepThumbnails, keepImported: keepImported, startedAt: startedAt)
        }.value
    }

    /// Deletes thumbnails and imported copies no entry references, and any
    /// EmfyExport-* temp folders — but only files last written *before*
    /// `startedAt`, so a file written after the sweep began survives (C2 race).
    nonisolated static func sweep(locations: Locations, keepThumbnails: Set<String>, keepImported: Set<String>, startedAt: Date = Date()) {
        sweepDirectory(locations.thumbnailsDirectory, keeping: keepThumbnails, cutoff: startedAt)
        sweepDirectory(locations.importedDirectory, keeping: keepImported, cutoff: startedAt)
        ExportTemp.sweep(startedAt: startedAt)
        sweepPrivateImports(except: locations.privateImportedDirectory, startedAt: startedAt)
    }

    /// Deletes every `EmfyPrivate-*` staging directory left under the temporary
    /// directory by a previous launch — a crash or a kill that skipped the
    /// quit/background cleanup — but never this launch's own directory, nor one
    /// written at/after `startedAt` (the C2 sweep race) (S-M3).
    private nonisolated static func sweepPrivateImports(except current: URL, startedAt: Date) {
        let tmp = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(privateImportPrefix) {
            let url = tmp.appendingPathComponent(name, isDirectory: true)
            if url.standardizedFileURL == current.standardizedFileURL { continue }
            if ExportTemp.wasWritten(after: startedAt, url) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func sweepDirectory(_ directory: URL, keeping: Set<String>, cutoff: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keeping.contains(name) {
            let url = directory.appendingPathComponent(name)
            // Never reclaim a file written after the sweep began (C2 race).
            if ExportTemp.wasWritten(after: cutoff, url) { continue }
            try? FileManager.default.removeItem(at: url)
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
        /// The rendered thumbnail PNG held in memory, set only for a Private-mode
        /// add (S1a-5) so the tile can show a thumbnail that never touches the disk.
        /// `nil` for a normal add, which writes the PNG and sets `thumbnailFileName`.
        var thumbnailPNGData: Data? = nil
    }

    /// Reads `url` while holding its security scope, confirms it opens through
    /// EMFKit, captures a bookmark, and renders a bounded thumbnail. When the file
    /// arrives somewhere Emfy can't keep accessing it — tmp, an Inbox, or a place
    /// whose scope couldn't be taken (or whose bookmark couldn't be made) — its
    /// bytes are copied into Imported/ and the copy is bookmarked instead (§b).
    /// Returns `nil` for an unreadable file.
    nonisolated static func prepareAdd(url: URL, locations: Locations, isPrivate: Bool = false) -> PreparedAdd? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // A not-yet-downloaded iCloud file would fail the plain read and be reported
        // as "damaged"; give the add path the same download/coordinated-read branch
        // the resolve path has (C4a L3).
        guard let data = readWithICloudFallback(url) else { return nil }
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
            guard let (copyBookmark, copyName) = importCopy(data: data, originalName: url.lastPathComponent, locations: locations, isPrivate: isPrivate) else {
                return nil
            }
            bookmark = copyBookmark
            importedFileName = copyName
        }
        guard let bookmark, !bookmark.isEmpty else { return nil }

        let names = MetafileFormatLabel.names(for: url.lastPathComponent)
        var thumbnailFileName: String?
        var thumbnailPNGData: Data?
        if let png = MetafileLoader.thumbnailPNG(data, maxLongEdge: thumbnailLongEdge) {
            if isPrivate {
                // Private mode: keep the thumbnail in memory only — nothing on disk.
                thumbnailPNGData = png
            } else {
                let name = UUID().uuidString + ".png"
                try? FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
                if (try? png.write(to: locations.thumbnailsDirectory.appendingPathComponent(name), options: .atomic)) != nil {
                    thumbnailFileName = name
                }
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
            openedAt: Date(),
            thumbnailPNGData: thumbnailPNGData
        )
    }

    /// Copies `data` into the import directory as `<uuid>.<ext>` and bookmarks the
    /// copy. A Private-mode import goes to the per-launch temporary directory, which
    /// is never backed up and never persists past the session (S-M3); a normal import
    /// goes to Imported/ and excludes the container from backup. Returns the bookmark
    /// and the copy's file name (for later cleanup), or `nil` on failure.
    private nonisolated static func importCopy(data: Data, originalName: String, locations: Locations, isPrivate: Bool) -> (bookmark: Data, fileName: String)? {
        let ext = MetafileFormatLabel.importedExtension(for: originalName)
        let name = UUID().uuidString + "." + ext
        let directory = isPrivate ? locations.privateImportedDirectory : locations.importedDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !isPrivate { excludeFromBackup(locations.supportDirectory) }
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

    /// Reads `url`, and if the plain read fails because it is a not-yet-downloaded
    /// iCloud placeholder, starts the download and does a coordinated read — the same
    /// fallback `resolveBookmark` uses, so adding such a file doesn't misreport it as
    /// damaged (C4a L3).
    private nonisolated static func readWithICloudFallback(_ url: URL) -> Data? {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { return data }
        if isUbiquitousNotDownloaded(url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return coordinatedRead(url)
        }
        return nil
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

    /// Forces the full decode now, on this background task, so the first draw of a
    /// thumbnail never pays a lazy decode on the main thread (P5). Both helpers run
    /// off the main actor; the options are built locally because `CFDictionary` isn't
    /// `Sendable` for a shared static under Swift 6.
    private nonisolated static func immediateDecodeOptions() -> CFDictionary {
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    }

    nonisolated static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, immediateDecodeOptions())
    }

    nonisolated static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, immediateDecodeOptions())
    }

    // MARK: - Locations

    /// Where the store keeps its files. Application Support/Emfy for recents.json
    /// and imported copies (backed up, excluded from backup per §i); Caches for
    /// the regenerable thumbnails.
    struct Locations: Sendable {
        var supportDirectory: URL
        var cachesDirectory: URL
        /// Where a Private-mode ephemeral import is copied — the temporary directory,
        /// never Application Support, so it leaves no persistent copy (S-M3). Defaults
        /// to this launch's `EmfyPrivate-<uuid>/`; tests inject their own.
        var privateImportedDirectory: URL = RecentsStore.privateImportLaunchDirectory

        var storeURL: URL { supportDirectory.appendingPathComponent("recents.json") }
        var corruptStoreURL: URL { supportDirectory.appendingPathComponent("recents.corrupt.json") }
        var importedDirectory: URL { supportDirectory.appendingPathComponent("Imported", isDirectory: true) }
        var thumbnailsDirectory: URL { cachesDirectory.appendingPathComponent("EmfyThumbnails", isDirectory: true) }
        /// Where the one-time "opened version" revert snapshots live, one subfolder per
        /// entry id (E2a-7). Pruned with the entry (`removeSideFiles`).
        var snapshotsDirectory: URL { supportDirectory.appendingPathComponent("Snapshots", isDirectory: true) }

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
