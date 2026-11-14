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

    /// The lifecycle sink that mirrors recents into Spotlight (F3d). The app sets it to a
    /// `RecentsSpotlightBridge`; weak so the store never owns it. `nil` in tests that don't
    /// install one, so the store's behaviour is unchanged without it.
    @ObservationIgnored weak var lifecycleObserver: (any RecentsLifecycleObserver)?

    /// Called when an entry is added, promoted or restored, so the AI title/tags service
    /// (A1b) can (re)generate its metadata in the background. Kept apart from
    /// `lifecycleObserver` (Spotlight) and never fired by `setAITitleTags`, so storing the
    /// result can't re-trigger generation. `nil` in tests and when AI isn't wired.
    @ObservationIgnored var onEntryChanged: ((UUID) -> Void)?

    /// Called to purge privacy-sensitive *derived* caches — the recognised-text (OCR)
    /// caches — on Clear Recents and when leaving Private mode (ST4). Wired by the app
    /// to the OCR service; `nil` in tests and where OCR isn't present, so the store's
    /// behaviour is unchanged without it. The per-entry revert snapshots are pruned by
    /// `removeSideFiles`; this covers the content-keyed caches `removeSideFiles` can't.
    @ObservationIgnored var onPurgeDerivedCaches: (() -> Void)?

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
        entries = loaded.entries.sorted { $0.openedAt > $1.openedAt }
        // Migrate owned drawings out of the legacy hidden, backup-excluded Imported/
        // folder into the backed-up, Files-visible location, and restore backup
        // inclusion for recents.json (ST2). Runs BEFORE the sweep, and the sweep is held
        // back unless migration completed, so the sweep can never delete a copy mid-move.
        // Only a trustworthy (clean) load marks the migration complete: a transiently
        // corrupt or partial store retries next launch, when more owned entries may
        // decode (their legacy copies are kept meanwhile — the sweep is skipped too).
        let migration = migrateOwnedDrawingsIfNeeded(storeTrustworthy: loaded.maySweep)
        if migration.changed { persist() }
        // Complete the launch sweep before signalling the store is loaded, so a
        // cold-launch open (which awaits `loadIfNeeded` before importing its
        // copy) can't have that freshly written copy or thumbnail deleted by a
        // still-running sweep (the C2 race). Skip the sweep entirely when the load was
        // unreadable or partial, so a transient read failure or one bad entry can't wipe every
        // imported/received/New/AI drawing (ST1/C1) — and when the ST2 migration is
        // incomplete, so a half-moved copy is never reclaimed.
        if loaded.maySweep && migration.complete {
            await runLaunchSweep()
        }
        didLoad = true
    }

    // MARK: - ST2 owned-drawings migration

    /// Runs the owned-drawings migration once, idempotently and resumably (ST2):
    /// restores backup inclusion for the support directory (so recents.json is backed
    /// up), moves each owned copy out of the legacy hidden `Imported/` folder into the
    /// backed-up, Files-visible owned-drawings location, and refreshes its bookmark.
    /// Returns whether entries changed (so the caller persists) and whether migration
    /// is COMPLETE (so the caller may run the launch sweep). A marker short-circuits
    /// steady-state launches; a crash before the marker resumes the whole migration,
    /// which is safe because every step is idempotent.
    private func migrateOwnedDrawingsIfNeeded(storeTrustworthy: Bool) -> (changed: Bool, complete: Bool) {
        // Existing installs excluded the support directory from backup; un-excluding it
        // is idempotent, so it runs every launch until the migration marker is written.
        Self.includeInBackup(locations.supportDirectory)
        if FileManager.default.fileExists(atPath: locations.migrationMarkerURL.path) {
            return (false, true)
        }
        let result = Self.migrateOwnedCopies(
            entries: entries,
            from: locations.legacyImportedDirectory,
            to: locations.ownedDrawingsDirectory,
            makeBookmark: { Self.makeBookmark(for: $0) }
        )
        let changed = result.updatedEntries != entries
        if changed { entries = result.updatedEntries }
        guard result.allSucceeded else { return (changed, false) }
        // Mark complete only once every owned copy is at its destination with a fresh
        // bookmark AND the load was trustworthy, so an interrupted or untrustworthy run
        // resumes in full next launch.
        guard storeTrustworthy else { return (changed, false) }
        // The support directory may not exist yet on a clean first launch (nothing has
        // persisted), so create it before writing the marker (and re-assert backup
        // inclusion now that it exists).
        try? FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
        Self.includeInBackup(locations.supportDirectory)
        try? Data().write(to: locations.migrationMarkerURL, options: Self.writeOptions)
        return (changed, true)
    }

    /// The outcome of moving owned copies to the ST2 location.
    struct OwnedMigration: Sendable {
        var updatedEntries: [RecentEntry]
        /// `true` only when every owned copy ended up at its destination with a fresh
        /// bookmark (or was already gone from disk); `false` leaves the marker unwritten
        /// so the next launch resumes.
        var allSucceeded: Bool
        var movedCount: Int
    }

    /// Moves each owned entry's copy from `legacy` to `destination` and refreshes its
    /// bookmark (ST2). Idempotent and crash-safe: a copy already at the destination (an
    /// interrupted earlier run, or a bookmark that wasn't persisted) just has its
    /// bookmark refreshed and any leftover legacy copy removed; a copy still only in
    /// `legacy` is moved destination-first (`moveItem` never deletes the source before
    /// the destination exists). An owned entry whose copy is missing from both is left
    /// untouched (the viewer surfaces `.notFound`). When `legacy == destination`
    /// (macOS) nothing moves. Pure but for the filesystem, so the move/resume logic is
    /// unit-tested with injected directories and bookmarker.
    nonisolated static func migrateOwnedCopies(
        entries: [RecentEntry],
        from legacy: URL,
        to destination: URL,
        makeBookmark: (URL) -> Data?
    ) -> OwnedMigration {
        var updated = entries
        guard legacy.standardizedFileURL != destination.standardizedFileURL else {
            return OwnedMigration(updatedEntries: updated, allSucceeded: true, movedCount: 0)
        }
        let fm = FileManager.default
        var allSucceeded = true
        var moved = 0
        for index in updated.indices {
            guard let name = updated[index].importedFileName else { continue }
            let src = legacy.appendingPathComponent(name)
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                // Already at the destination (possibly from an interrupted run): refresh
                // the bookmark and clear any leftover legacy copy.
                if let bookmark = makeBookmark(dst), !bookmark.isEmpty {
                    updated[index].bookmark = bookmark
                } else {
                    allSucceeded = false
                }
                try? fm.removeItem(at: src)
            } else if fm.fileExists(atPath: src.path) {
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    moved += 1
                    if let bookmark = makeBookmark(dst), !bookmark.isEmpty {
                        updated[index].bookmark = bookmark
                    } else {
                        allSucceeded = false
                    }
                } catch {
                    allSucceeded = false
                }
            }
            // Neither exists → the copy is gone; leave the entry as is.
        }
        return OwnedMigration(updatedEntries: updated, allSucceeded: allSucceeded, movedCount: moved)
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
        // Mirror the add/refresh into Spotlight (F3d). After sortAndCap, so an entry this
        // add evicted (already de-indexed there) is never re-indexed here.
        lifecycleObserver?.recentsEntryAddedOrRefreshed(id: id)
        onEntryChanged?(id)
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
        if !on {
            purgeSessionPrivate()
            // A drawing opened privately may have seeded the content-keyed OCR cache,
            // which `purgeSessionPrivate`'s per-entry side-file deletion can't reach.
            // Purge it when Private mode turns off so nothing recognised privately
            // survives on disk (ST4). The per-entry revert snapshots are already pruned
            // by `purgeSessionPrivate`.
            onPurgeDerivedCaches?()
        }
        // Private on wipes the index; off re-syncs (the bridge decides, F3d).
        lifecycleObserver?.recentsPrivateModeChanged()
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
        // De-index the pruned entries (F3d).
        lifecycleObserver?.recentsEntriesRemoved(ids: evicted.map(\.id))
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
        // De-index immediately (F3d); Undo re-indexes via `undoLastRemoval`.
        lifecycleObserver?.recentsEntriesRemoved(ids: [id])
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
        // Undo restored the entry — re-index it (F3d).
        lifecycleObserver?.recentsEntryAddedOrRefreshed(id: pending.entry.id)
        onEntryChanged?(pending.entry.id)
    }

    // MARK: - AI title and tags (A1b)

    /// Stores on-device AI title/tags for an entry, tagged with the content hash they
    /// were generated from, and refreshes its Spotlight keywords. A no-op for a missing
    /// or session-only Private entry (Private metadata never persists). Does NOT fire
    /// `onEntryChanged`, so storing can't re-trigger generation.
    func setAITitleTags(_ titleTags: DrawingTitleTags, contentHash: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !privateIDs.contains(id) else { return }
        entries[index].aiTitle = titleTags.title.isEmpty ? nil : titleTags.title
        entries[index].aiTags = titleTags.tags.isEmpty ? nil : titleTags.tags
        entries[index].aiContentHash = contentHash
        persist()
        // Refresh the Spotlight item so its keywords pick up the new title/tags (F3d).
        lifecycleObserver?.recentsEntryAddedOrRefreshed(id: id)
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
        // Remove the whole revert-snapshot tree — not just the per-entry folders above,
        // so any orphaned snapshot is swept too (ST4).
        try? FileManager.default.removeItem(at: locations.snapshotsDirectory)
        // Purge the recognised-text caches: Clear Recents should leave no derived text
        // from any cleared drawing on disk (ST4).
        onPurgeDerivedCaches?()
        // Wipe the whole Spotlight domain (F3d).
        lifecycleObserver?.recentsCleared()
    }

    // MARK: - Ordering, cap, persistence

    /// Chooses which entries to drop when the list is over `max` (ST3, owner
    /// decision 14 Nov): only plain file *references* are ever evicted. An "owned"
    /// drawing — one Emfy holds the only copy of (received, New, or AI-generated;
    /// `importedFileName != nil`) — is NEVER evicted by the cap, because dropping it
    /// would destroy the user's only copy. Pinned entries are exempt too (S1a
    /// Library extras). When only owned and/or pinned entries remain, the list is
    /// allowed to sit *above* the cap rather than lose a drawing. The oldest
    /// references go first. Pure, for the cap test.
    nonisolated static func entriesToEvict(from entries: [RecentEntry], max: Int) -> [RecentEntry] {
        let overflow = entries.count - Swift.max(max, 0)
        guard overflow > 0 else { return [] }
        // Only unpinned plain references are candidates; owned drawings are never
        // evicted, so the overflow is taken entirely from references, oldest first.
        let candidates = entries
            .filter { !($0.isPinned ?? false) && $0.importedFileName == nil }
            .sorted { $0.openedAt < $1.openedAt }
        return Array(candidates.prefix(overflow))
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
        // De-index entries this add evicted over the cap (F3d).
        lifecycleObserver?.recentsEntriesRemoved(ids: evicted.map(\.id))
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
            // An owned copy lives in the ST2 owned-drawings location, a Private-mode one
            // in the per-launch temp directory, and a not-yet-migrated one in the legacy
            // Imported/ folder; the name is a UUID, so removing from all three is safe.
            try? FileManager.default.removeItem(at: locations.ownedDrawingsDirectory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: locations.legacyImportedDirectory.appendingPathComponent(name))
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
        #if os(iOS)
        // On iOS the owned-drawings directory is the user-visible Documents folder
        // (exposed via UIFileSharingEnabled, ST2): a file the user added there must
        // never be reclaimed, so Documents is NOT swept. Owned copies are removed
        // explicitly (removeSideFiles) and are never cap-evicted (ST3). Only the legacy
        // hidden Imported/ folder is swept, to clear stragglers after the ST2 move,
        // keeping any copy whose move hasn't completed (never delete during migration).
        sweepDirectory(locations.legacyImportedDirectory, keeping: keepImported, cutoff: startedAt)
        #else
        // On macOS the owned-drawings directory is the app-private Application
        // Support/Imported folder (same as the legacy location) — safe to reclaim
        // orphans, keeping referenced copies.
        sweepDirectory(locations.ownedDrawingsDirectory, keeping: keepImported, cutoff: startedAt)
        #endif
        ExportTemp.sweep(startedAt: startedAt)
        // Reclaim `EmfyNewDrawing-*` import stages a crash or kill left between the write
        // and the store's import (ST5). The import copies the bytes into Imported/, so a
        // pre-cutoff stage is always safe to delete.
        ExportTemp.sweepPrefixed(NewDrawing.tempDirectoryPrefix, startedAt: startedAt)
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

    /// Copies `data` into the owned-drawings directory as `<uuid>.<ext>` and bookmarks
    /// the copy. A Private-mode import goes to the per-launch temporary directory, which
    /// is never backed up and never persists past the session (S-M3); a normal import
    /// goes to the ST2 owned-drawings location (the Documents folder on iOS, Application
    /// Support/Imported on macOS) — backed up, and on iOS visible in Files. Returns the
    /// bookmark and the copy's file name (for later cleanup), or `nil` on failure.
    private nonisolated static func importCopy(data: Data, originalName: String, locations: Locations, isPrivate: Bool) -> (bookmark: Data, fileName: String)? {
        let ext = MetafileFormatLabel.importedExtension(for: originalName)
        let name = UUID().uuidString + "." + ext
        let directory = isPrivate ? locations.privateImportedDirectory : locations.ownedDrawingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(name)
            try data.write(to: fileURL, options: writeOptions)
            guard let bookmark = makeBookmark(for: fileURL), !bookmark.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return (bookmark, name)
        } catch {
            // .private: a file error's message can carry the file name / path (S10).
            log.error("Failed to import a copy: \(error.localizedDescription, privacy: .private)")
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
    /// Protect the store and imported copies at rest on iOS, but keep them readable after the
    /// first unlock so a Shortcuts/App Intent run on a still-locked device doesn't hit a read
    /// failure — which would read as an unreadable store (ST1). `.atomic` on both.
    nonisolated static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    nonisolated static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    // MARK: - Tolerant decode (§d)

    /// The tri-state outcome of a load (ST1). `maySweep` gates the launch sweep: the sweep
    /// deletes every file in Imported/ and EmfyThumbnails/ that no loaded entry references, so
    /// it must run ONLY when the load is complete and trustworthy. A missing store (clean first
    /// launch) and a fully-decoded store are safe; a read failure, an undecodable file, or ANY
    /// dropped entry (C1) leaves it `false`, so a transient failure or a single bad element can
    /// never wipe every received, New and AI-generated drawing.
    struct LoadResult: Sendable {
        let entries: [RecentEntry]
        let maySweep: Bool
    }

    nonisolated static func loadEntries(from locations: Locations) -> LoadResult {
        // A missing store is a clean first launch: nothing is referenced and nothing should be
        // orphaned, so the sweep is safe.
        guard FileManager.default.fileExists(atPath: locations.storeURL.path) else {
            return LoadResult(entries: [], maySweep: true)
        }
        // The file exists but can't be read — a locked device before first unlock, a transient
        // I/O error. We don't know what it references, so NEVER sweep: that would delete every
        // imported/received/New/AI drawing (ST1).
        guard let data = try? Data(contentsOf: locations.storeURL) else {
            log.error("recents.json exists but could not be read; skipping the launch sweep")
            return LoadResult(entries: [], maySweep: false)
        }
        // Decode entry by entry: a single bad element is skipped, not fatal.
        if let wrappers = try? JSONDecoder().decode([FailableEntry].self, from: data) {
            let entries = wrappers.compactMap(\.entry)
            let dropped = wrappers.filter { $0.entry == nil }
            guard dropped.isEmpty else {
                // Some entries failed to decode (C1). Their side files would look orphaned, so
                // skip the sweep this launch rather than delete files a would-be entry needs.
                for bad in dropped {
                    // .private: a decode error can echo field values / paths (S10).
                    log.error("Dropped an undecodable recents entry; skipping the launch sweep: \(bad.decodeError ?? "unknown", privacy: .private)")
                }
                return LoadResult(entries: entries, maySweep: false)
            }
            return LoadResult(entries: entries, maySweep: true)
        }
        // The whole file is undecodable (not even an array): set it aside and start empty, but
        // NEVER sweep — the files it referenced must survive until the user reopens them (ST1).
        try? FileManager.default.removeItem(at: locations.corruptStoreURL)
        try? FileManager.default.moveItem(at: locations.storeURL, to: locations.corruptStoreURL)
        log.error("recents.json was undecodable; renamed to recents.corrupt.json and skipping the launch sweep")
        return LoadResult(entries: [], maySweep: false)
    }

    /// Decodes a `RecentEntry` or, on failure, nothing — so a malformed element
    /// doesn't fail the whole array. Captures the decode error so the drop can be logged (C1).
    private struct FailableEntry: Decodable {
        let entry: RecentEntry?
        let decodeError: String?
        init(from decoder: Decoder) throws {
            do {
                entry = try decoder.singleValueContainer().decode(RecentEntry.self)
                decodeError = nil
            } catch {
                entry = nil
                decodeError = String(describing: error)
            }
        }
    }

    // MARK: - Backup exclusion and image helpers (nonisolated)

    /// Restores backup inclusion for a directory excluded by an earlier build (ST2):
    /// owned drawings and recents.json should be backed up, so the support directory is
    /// no longer excluded. Idempotent — setting the value to `false` is a no-op when it
    /// was never excluded.
    nonisolated static func includeInBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
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

    /// Where the store keeps its files. Application Support/Emfy for recents.json and
    /// (on macOS) owned-drawing copies; the Documents directory for owned drawings on
    /// iOS (ST2); Caches for the regenerable thumbnails.
    struct Locations: Sendable {
        var supportDirectory: URL
        var cachesDirectory: URL
        /// Where a Private-mode ephemeral import is copied — the temporary directory,
        /// never Application Support, so it leaves no persistent copy (S-M3). Defaults
        /// to this launch's `EmfyPrivate-<uuid>/`; tests inject their own.
        var privateImportedDirectory: URL = RecentsStore.privateImportLaunchDirectory
        /// The app's Documents directory — the ST2 home for owned drawings on iOS, so
        /// they are backed up and visible in the Files app under "Emfy". Injected so
        /// tests use a temporary container, never the real one.
        var documentsDirectory: URL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        var storeURL: URL { supportDirectory.appendingPathComponent("recents.json") }
        var corruptStoreURL: URL { supportDirectory.appendingPathComponent("recents.corrupt.json") }
        /// The legacy hidden, backup-excluded home for owned copies, kept as the ST2
        /// migration source (and, on macOS, still the live location).
        var legacyImportedDirectory: URL { supportDirectory.appendingPathComponent("Imported", isDirectory: true) }
        /// The current home for owned drawings — received copies, New and AI-generated
        /// (ST2). iOS: the app's Documents directory, so they are backed up and visible
        /// in Files under "Emfy". macOS: Application Support/Emfy/Imported (unchanged) —
        /// not hidden there and, once backup inclusion is restored, backed up by Time
        /// Machine, so no move is needed.
        var ownedDrawingsDirectory: URL {
            #if os(iOS)
            documentsDirectory
            #else
            legacyImportedDirectory
            #endif
        }
        /// Back-compat alias for the owned-copies directory, now the ST2 location.
        var importedDirectory: URL { ownedDrawingsDirectory }
        var thumbnailsDirectory: URL { cachesDirectory.appendingPathComponent("EmfyThumbnails", isDirectory: true) }
        /// Where the one-time "opened version" revert snapshots live, one subfolder per
        /// entry id (E2a-7). Pruned with the entry (`removeSideFiles`).
        var snapshotsDirectory: URL { supportDirectory.appendingPathComponent("Snapshots", isDirectory: true) }
        /// Written once the ST2 owned-drawings migration completes, so steady-state
        /// launches skip the scan; absent ⇒ (re)run, which is idempotent and resumable.
        var migrationMarkerURL: URL { supportDirectory.appendingPathComponent(".owned-migrated") }

        static var standard: Locations {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Emfy", isDirectory: true)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return Locations(supportDirectory: support, cachesDirectory: caches, documentsDirectory: documents)
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
            // recents.json is backed up now (ST2): no backup exclusion is applied here,
            // and the ST2 migration un-excludes any directory an earlier build excluded.
            let data = try JSONEncoder().encode(entries)
            try data.write(to: locations.storeURL, options: RecentsStore.writeOptions)
        } catch {
            // .private: a file error's message can carry the file name / path (S10).
            RecentsStore.log.error("Failed to persist recents: \(error.localizedDescription, privacy: .private)")
        }
    }
}
