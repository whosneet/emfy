import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing

// The shared library sources (RecentsStore, RecentEntry, MetafileLoader,
// MetafileDiagnostics, ExportTaskRunner, ExportTemp, EMFExport) are compiled
// directly into this logic-test bundle — see the report for why a hosted bundle
// couldn't be used on the sandboxed macOS app. The types are therefore in this
// module, so no `import Emfy` is needed.

/// C2 unit tests for the shared library model and the plain-language
/// diagnostics. Multiplatform: builds and runs on macOS and the iOS simulator.
/// The suite is serialised — several tests touch the shared temporary directory
/// (the export-temp sweep), and serialising keeps them from racing each other.
/// Every test uses a throwaway directory, never the real container.
@Suite(.serialized)
struct EmfyTests {

    // MARK: - Helpers

    /// A fresh, isolated temp directory for one test.
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    private func makeStore(in dir: URL) -> RecentsStore {
        RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
            documentsDirectory: dir.appendingPathComponent("Documents", isDirectory: true)
        ))
    }

    /// Writes a minimal but valid EMF (EMR_HEADER + EMR_EOF) so EMFKit opens and
    /// prepares it — enough to exercise the add/thumbnail flow.
    @discardableResult
    private func writeEMF(to dir: URL, name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? EmfyTests.minimalEMF().write(to: url)
        return url
    }

    static func minimalEMF(width: Int32 = 100, height: Int32 = 100) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        // EMR_HEADER (88-byte base variant)
        u32(1); u32(88)
        i32(0); i32(0); i32(width - 1); i32(height - 1)     // rclBounds (inclusive-inclusive)
        i32(0); i32(0); i32(2117); i32(2117)                // rclFrame (.01 mm)
        u32(0x464D4520)                                     // dSignature " EMF"
        u32(0x0001_0000)                                    // nVersion
        u32(108)                                            // nBytes (total)
        u32(2)                                              // nRecords
        u16(1); u16(0)                                      // nHandles, sReserved
        u32(0); u32(0)                                      // nDescription, offDescription
        u32(0)                                              // nPalEntries
        i32(1920); i32(1080)                                // szlDevice
        i32(508); i32(286)                                  // szlMillimeters
        // EMR_EOF (20 bytes)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    private func isNotFound(_ outcome: RecentsStore.ResolveOutcome) -> Bool {
        if case .notFound = outcome { return true }; return false
    }

    private func isUnavailable(_ outcome: RecentsStore.ResolveOutcome) -> Bool {
        if case .unavailable = outcome { return true }; return false
    }

    // MARK: - §a Typed resolve classification

    @Test func classifyReadFailureSeparatesGoneFromTransient() {
        #expect(isNotFound(RecentsStore.classifyReadFailure(CocoaError(.fileReadNoSuchFile))))
        #expect(isNotFound(RecentsStore.classifyReadFailure(CocoaError(.fileNoSuchFile))))
        #expect(isNotFound(RecentsStore.classifyReadFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))))
        #expect(isUnavailable(RecentsStore.classifyReadFailure(CocoaError(.fileReadNoPermission))))
        #expect(isUnavailable(RecentsStore.classifyReadFailure(CocoaError(.fileReadUnknown))))
    }

    @Test func resolveBookmarkGarbageOrEmptyIsNotFound() {
        #expect(isNotFound(RecentsStore.resolveBookmark(Data())))
        #expect(isNotFound(RecentsStore.resolveBookmark(Data([9, 9, 9, 9]))))
    }

    @Test func resolveBookmarkDeletedFileIsNotFound() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("gone.emf")
        try Data([1, 2, 3]).write(to: fileURL)
        let bookmark = try #require(RecentsStore.makeBookmark(for: fileURL))
        try FileManager.default.removeItem(at: fileURL)
        #expect(isNotFound(RecentsStore.resolveBookmark(bookmark)))
    }

    @Test func resolveBookmarkUnreadableFileIsUnavailable() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("locked.emf")
        try Data([1, 2, 3]).write(to: fileURL)
        let bookmark = try #require(RecentsStore.makeBookmark(for: fileURL))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        #expect(isUnavailable(RecentsStore.resolveBookmark(bookmark)))
    }

    // MARK: - §a Resolve classifies but no longer auto-prunes (C4a H8/H4)

    @MainActor
    @Test func resolveClassifiesFailuresAndKeepsTheEntry() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let src = writeEMF(to: dir, name: "doc.emf")
        let id = try #require(await store.handleOpenedURL(src))
        #expect(store.entries.count == 1)
        let entry = try #require(store.entry(id: id))
        // A plain temp file can't take a security scope, so it's imported (§b).
        let importedName = try #require(entry.importedFileName)
        let importedURL = store.locations.importedDirectory.appendingPathComponent(importedName)

        // Transient failure keeps the entry.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: importedURL.path)
        await #expect(throws: RecentsStore.ResolveFailure.unavailable) {
            _ = try await store.resolveData(for: entry)
        }
        #expect(store.entries.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: importedURL.path)

        // A definitive not-found now also keeps the entry — the viewer shows the
        // failed state and the user's Remove takes it out, so the viewer isn't
        // dismissed out from under them by an auto-prune (C4a H8/H4).
        try FileManager.default.removeItem(at: importedURL)
        await #expect(throws: RecentsStore.ResolveFailure.notFound) {
            _ = try await store.resolveData(for: entry)
        }
        #expect(store.entries.count == 1)
    }

    // MARK: - §b Import a copy of ephemeral files, remove it with the entry

    @MainActor
    @Test func ephemeralFileIsImportedAndCleanedUp() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let src = writeEMF(to: dir, name: "inbox.emf")
        let id = try #require(await store.handleOpenedURL(src))
        let entry = try #require(store.entry(id: id))
        let importedName = try #require(entry.importedFileName)
        let importedURL = store.locations.importedDirectory.appendingPathComponent(importedName)
        #expect(FileManager.default.fileExists(atPath: importedURL.path))

        store.remove(id)
        // C4a H3 defers side-file deletion until the undo window expires; it is kept
        // until the pending removal commits (here, driven directly).
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        store.commitPendingRemoval()
        #expect(!FileManager.default.fileExists(atPath: importedURL.path))
    }

    @Test func ephemeralLocationDetection() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x.emf")
        #expect(RecentsStore.isEphemeralLocation(tmp))
        let inbox = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/AB/Documents/Inbox/x.emf")
        #expect(RecentsStore.isEphemeralLocation(inbox))
    }

    // MARK: - §c Identity de-dupe + reload token

    @MainActor
    @Test func reopeningSameFileDeduplicatesAndRefreshesToken() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let src = writeEMF(to: dir, name: "same.emf")

        let id1 = try #require(await store.handleOpenedURL(src))
        let token1 = try #require(store.entry(id: id1)?.reloadToken)
        let id2 = try #require(await store.handleOpenedURL(src))
        let token2 = try #require(store.entry(id: id1)?.reloadToken)

        #expect(id1 == id2)                 // promoted, not duplicated
        #expect(store.entries.count == 1)
        #expect(token1 != token2)           // content reload token changes on reopen

        let other = writeEMF(to: dir, name: "other.emf")
        let id3 = try #require(await store.handleOpenedURL(other))
        #expect(id3 != id1)
        #expect(store.entries.count == 2)
    }

    // MARK: - §d Tolerant decode + corrupt rename

    @Test func decodeSkipsBadEntriesAndKeepsGood() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)

        let good = RecentEntry(
            id: UUID(), displayName: "a.emf", formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 10, openedAt: Date(), bookmark: Data([1, 2, 3]), thumbnailFileName: nil,
            fileIdentity: "/x/a.emf", importedFileName: nil, reloadToken: UUID()
        )
        let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let array: [Any] = [goodObject, ["nonsense": true]]
        try JSONSerialization.data(withJSONObject: array).write(to: locations.storeURL)

        let loaded = RecentsStore.loadEntries(from: locations)
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.displayName == "a.emf")
        #expect(!FileManager.default.fileExists(atPath: locations.corruptStoreURL.path))
        // C1: a dropped (undecodable) entry disables the launch sweep, so its would-be side
        // files aren't wiped as orphans.
        #expect(!loaded.maySweep)
    }

    @Test func undecodableStoreIsRenamedAside() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
        try Data("this is not json {".utf8).write(to: locations.storeURL)

        let loaded = RecentsStore.loadEntries(from: locations)
        #expect(loaded.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: locations.corruptStoreURL.path))
        #expect(!FileManager.default.fileExists(atPath: locations.storeURL.path))
        // ST1: an undecodable store disables the launch sweep, so no imported/received file is
        // wiped before the user can reopen it.
        #expect(!loaded.maySweep)
    }

    @Test func missingStoreStartsEmptyWithoutCorruptFile() {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        let loaded = RecentsStore.loadEntries(from: locations)
        #expect(loaded.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.corruptStoreURL.path))
        // A clean first launch (no store) is safe to sweep.
        #expect(loaded.maySweep)
    }

    // ST1: a load that reads cleanly and decodes every entry may sweep orphans.
    @Test func fullyDecodedStoreMaySweep() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
        let good = RecentEntry(
            id: UUID(), displayName: "a.emf", formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 10, openedAt: Date(), bookmark: Data([1, 2, 3]), thumbnailFileName: nil,
            fileIdentity: "/x/a.emf", importedFileName: nil, reloadToken: UUID()
        )
        try JSONEncoder().encode([good]).write(to: locations.storeURL)
        let loaded = RecentsStore.loadEntries(from: locations)
        #expect(loaded.entries.count == 1)
        #expect(loaded.maySweep)
    }

    // ST1: an undecodable recents.json must NOT trigger the sweep, so the Imported copies it
    // referenced survive the launch (a transient corruption can't wipe every received drawing).
    @MainActor
    @Test func corruptStoreKeepsImportedFilesAcrossLoad() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        try FileManager.default.createDirectory(at: store.locations.importedDirectory, withIntermediateDirectories: true)
        let kept = store.locations.importedDirectory.appendingPathComponent("received.emf")
        try Data([1, 2, 3]).write(to: kept)
        // A corrupt store that loses every entry reference.
        try FileManager.default.createDirectory(at: store.locations.supportDirectory, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: store.locations.storeURL)

        await store.loadIfNeeded()

        #expect(store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.path))   // the received copy survived
    }

    // C1: one undecodable entry alongside good ones must NOT trigger the sweep, so the dropped
    // entry's would-be files survive.
    @MainActor
    @Test func partialDecodeKeepsImportedFilesAcrossLoad() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        try FileManager.default.createDirectory(at: store.locations.importedDirectory, withIntermediateDirectories: true)
        let orphanish = store.locations.importedDirectory.appendingPathComponent("would-be.emf")
        try Data([9]).write(to: orphanish)

        try FileManager.default.createDirectory(at: store.locations.supportDirectory, withIntermediateDirectories: true)
        let good = RecentEntry(
            id: UUID(), displayName: "a.emf", formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 10, openedAt: Date(), bookmark: Data([1, 2, 3]), thumbnailFileName: nil,
            fileIdentity: "/x/a.emf", importedFileName: nil, reloadToken: UUID()
        )
        let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let array: [Any] = [goodObject, ["nonsense": true]]
        try JSONSerialization.data(withJSONObject: array).write(to: store.locations.storeURL)

        await store.loadIfNeeded()

        #expect(store.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: orphanish.path))   // sweep skipped (C1)
    }

    // ST4: Clear Recents purges the derived caches and the whole revert-snapshot tree,
    // so no recognised text or opened-version snapshot survives a clear.
    @MainActor
    @Test func clearPurgesSnapshotsAndDerivedCaches() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        var purged = false
        store.onPurgeDerivedCaches = { purged = true }
        // A stray snapshot folder (as an edited drawing would leave).
        let snap = store.locations.snapshotsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data([1]).write(to: snap.appendingPathComponent("opened.bin"))

        store.clear()

        #expect(purged)
        #expect(!FileManager.default.fileExists(atPath: store.locations.snapshotsDirectory.path))
    }

    // ST4: leaving Private mode purges the derived (OCR) caches, so text recognised
    // from a privately-opened drawing leaves no on-disk trace.
    @MainActor
    @Test func leavingPrivateModePurgesDerivedCaches() {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        var purgeCount = 0
        store.onPurgeDerivedCaches = { purgeCount += 1 }
        store.setPrivate(true)
        #expect(purgeCount == 0)        // entering Private doesn't purge
        store.setPrivate(false)
        #expect(purgeCount == 1)        // leaving Private purges once
    }

    // MARK: - ST2 owned-drawings migration

    private func ownedEntry(_ importedName: String, bookmark: Data = Data([0])) -> RecentEntry {
        RecentEntry(
            id: UUID(), displayName: "d.emf", formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 3, openedAt: Date(), bookmark: bookmark, thumbnailFileName: nil,
            fileIdentity: "/x/d.emf", importedFileName: importedName, reloadToken: UUID()
        )
    }

    /// A bookmarker standing in for the platform's real one, so the migration's
    /// move/rebookmark logic is tested without a security-scoped bookmark (which a
    /// test process can't create for an arbitrary file).
    private func pathBookmark(_ url: URL) -> Data? { Data(url.standardizedFileURL.path.utf8) }

    // ST2: an owned copy in the legacy folder is moved to the destination and its
    // bookmark refreshed.
    @Test func migrationMovesOwnedCopyAndRefreshesBookmark() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let legacy = dir.appendingPathComponent("Imported", isDirectory: true)
        let dest = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).emf"
        try Data([1, 2, 3]).write(to: legacy.appendingPathComponent(name))
        let entry = ownedEntry(name, bookmark: Data([9]))

        let result = RecentsStore.migrateOwnedCopies(entries: [entry], from: legacy, to: dest, makeBookmark: pathBookmark)

        #expect(result.movedCount == 1)
        #expect(result.allSucceeded)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent(name).path))   // source gone
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path))      // at destination
        #expect(result.updatedEntries[0].bookmark == pathBookmark(dest.appendingPathComponent(name))) // rebookmarked
    }

    // ST2: running the migration twice is a no-op the second time (idempotent).
    @Test func migrationIsIdempotent() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let legacy = dir.appendingPathComponent("Imported", isDirectory: true)
        let dest = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).emf"
        try Data([1]).write(to: legacy.appendingPathComponent(name))

        let first = RecentsStore.migrateOwnedCopies(entries: [ownedEntry(name)], from: legacy, to: dest, makeBookmark: pathBookmark)
        let second = RecentsStore.migrateOwnedCopies(entries: first.updatedEntries, from: legacy, to: dest, makeBookmark: pathBookmark)

        #expect(first.movedCount == 1)
        #expect(second.movedCount == 0)        // nothing left to move
        #expect(second.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path))
    }

    // ST2: crash-safety — a copy already at the destination (moved, but the bookmark
    // wasn't persisted before a crash) has its bookmark refreshed on resume, and any
    // leftover legacy copy is cleared.
    @Test func migrationResumesAfterAnInterruptedMove() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let legacy = dir.appendingPathComponent("Imported", isDirectory: true)
        let dest = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).emf"
        // The file already moved; a stale legacy leftover also exists; the entry's
        // bookmark still points at the old location (the crash was before persist).
        try Data([2]).write(to: dest.appendingPathComponent(name))
        try Data([2]).write(to: legacy.appendingPathComponent(name))
        let entry = ownedEntry(name, bookmark: Data([9]))

        let result = RecentsStore.migrateOwnedCopies(entries: [entry], from: legacy, to: dest, makeBookmark: pathBookmark)

        #expect(result.movedCount == 0)        // nothing newly moved
        #expect(result.allSucceeded)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent(name).path))   // leftover cleared
        #expect(result.updatedEntries[0].bookmark == pathBookmark(dest.appendingPathComponent(name))) // bookmark fixed
    }

    // ST2: a failed bookmark leaves the migration INCOMPLETE (not all succeeded), so
    // the store won't write its marker and will resume next launch.
    @Test func migrationReportsFailureWhenBookmarkingFails() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let legacy = dir.appendingPathComponent("Imported", isDirectory: true)
        let dest = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).emf"
        try Data([1]).write(to: legacy.appendingPathComponent(name))

        let result = RecentsStore.migrateOwnedCopies(entries: [ownedEntry(name)], from: legacy, to: dest, makeBookmark: { _ in nil })

        #expect(!result.allSucceeded)   // bookmarking failed ⇒ incomplete ⇒ resume later
    }

    // ST2: the sweep never deletes a referenced copy whose move hasn't completed —
    // a legacy copy still named in keepImported survives (no delete during migration).
    @Test func sweepKeepsAReferencedInFlightLegacyCopy() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
            documentsDirectory: dir.appendingPathComponent("Documents", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.legacyImportedDirectory, withIntermediateDirectories: true)
        let referenced = "referenced.emf"
        let orphan = "orphan.emf"
        try Data([1]).write(to: locations.legacyImportedDirectory.appendingPathComponent(referenced))
        try Data([1]).write(to: locations.legacyImportedDirectory.appendingPathComponent(orphan))

        RecentsStore.sweep(locations: locations, keepThumbnails: [], keepImported: [referenced])

        #expect(FileManager.default.fileExists(atPath: locations.legacyImportedDirectory.appendingPathComponent(referenced).path))
        #expect(!FileManager.default.fileExists(atPath: locations.legacyImportedDirectory.appendingPathComponent(orphan).path))
    }

    // ST2: after loadIfNeeded the migration marker is written and the support directory
    // is no longer excluded from backup (recents.json is backed up).
    @MainActor
    @Test func loadRunsMigrationAndRestoresBackupInclusion() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        _ = writeEMF(to: dir, name: "m.emf")
        _ = await store.handleOpenedURL(dir.appendingPathComponent("m.emf"))

        #expect(FileManager.default.fileExists(atPath: store.locations.migrationMarkerURL.path))
        let excluded = try store.locations.supportDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded != true)   // not excluded ⇒ backed up (ST2)
    }

    // ST1: a normal, fully-decoded load still sweeps genuine orphans.
    @MainActor
    @Test func normalLoadStillSweepsOrphans() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        // The swept owned-copies directory is the legacy Imported/ on iOS (Documents is
        // never swept, ST2) and Application Support/Imported on macOS — both the
        // `legacyImportedDirectory` here.
        try FileManager.default.createDirectory(at: store.locations.legacyImportedDirectory, withIntermediateDirectories: true)
        let orphan = store.locations.legacyImportedDirectory.appendingPathComponent("orphan.emf")
        try Data([0]).write(to: orphan)
        // No store file ⇒ a clean, sweep-eligible load with nothing referenced.

        await store.loadIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))   // the orphan was swept
    }

    // MARK: - §e Launch sweep of orphans + export temp

    @Test func launchSweepRemovesOrphansButKeepsReferenced() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.legacyImportedDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: locations.thumbnailsDirectory.appendingPathComponent("keep.png"))
        try Data([0]).write(to: locations.thumbnailsDirectory.appendingPathComponent("orphan.png"))
        try Data([0]).write(to: locations.legacyImportedDirectory.appendingPathComponent("keep.emf"))
        try Data([0]).write(to: locations.legacyImportedDirectory.appendingPathComponent("orphan.emf"))
        let exportDir = ExportTemp.makeDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        RecentsStore.sweep(locations: locations, keepThumbnails: ["keep.png"], keepImported: ["keep.emf"])

        #expect(FileManager.default.fileExists(atPath: locations.thumbnailsDirectory.appendingPathComponent("keep.png").path))
        #expect(!FileManager.default.fileExists(atPath: locations.thumbnailsDirectory.appendingPathComponent("orphan.png").path))
        #expect(FileManager.default.fileExists(atPath: locations.legacyImportedDirectory.appendingPathComponent("keep.emf").path))
        #expect(!FileManager.default.fileExists(atPath: locations.legacyImportedDirectory.appendingPathComponent("orphan.emf").path))
        #expect(!FileManager.default.fileExists(atPath: exportDir.path))
    }

    /// The C2 cold-launch race, made deterministic: a file written *after* the
    /// sweep started (like an imported copy or thumbnail from a cold-launch open
    /// that races the still-running sweep) must survive, while an older orphan is
    /// still reclaimed. Driven by explicit file dates and an explicit cutoff, so
    /// it never depends on timing.
    @Test func launchSweepKeepsFilesWrittenAfterItStarted() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: locations.thumbnailsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.legacyImportedDirectory, withIntermediateDirectories: true)

        let orphan = locations.legacyImportedDirectory.appendingPathComponent("orphan.emf")
        let freshImport = locations.legacyImportedDirectory.appendingPathComponent("fresh.emf")
        let freshThumb = locations.thumbnailsDirectory.appendingPathComponent("fresh.png")
        try Data([0]).write(to: orphan)
        try Data([0]).write(to: freshImport)
        try Data([0]).write(to: freshThumb)

        // Capture the cutoff after the files exist (so their real creation dates
        // are older than it), then stamp the two "fresh" files as written after.
        let cutoff = Date()
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-3600)], ofItemAtPath: orphan.path)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(3600)], ofItemAtPath: freshImport.path)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(3600)], ofItemAtPath: freshThumb.path)

        // Nothing is in the keep-set: survival is decided purely by write time.
        RecentsStore.sweep(locations: locations, keepThumbnails: [], keepImported: [], startedAt: cutoff)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))        // old orphan reclaimed
        #expect(FileManager.default.fileExists(atPath: freshImport.path))   // written after start: kept
        #expect(FileManager.default.fileExists(atPath: freshThumb.path))    // written after start: kept
    }

    // MARK: - §j Export temp cleanup

    @Test func exportTempSweepRemovesOnlyEmfyExportDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
        let export = ExportTemp.makeDirectory()
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let other = tmp.appendingPathComponent("KeepMe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        ExportTemp.sweep()

        #expect(!FileManager.default.fileExists(atPath: export.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    // ST5: the launch sweep reclaims a stale `EmfyNewDrawing-*` import stage (left by a
    // crash between the write and the store's import), but never a fresher one.
    @Test func launchSweepReclaimsNewDrawingTempStages() throws {
        let tmp = FileManager.default.temporaryDirectory
        let stale = tmp.appendingPathComponent(NewDrawing.tempDirectoryPrefix + UUID().uuidString, isDirectory: true)
        let fresh = tmp.appendingPathComponent(NewDrawing.tempDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh); try? FileManager.default.removeItem(at: stale) }

        let cutoff = Date()
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(3600)], ofItemAtPath: fresh.path)

        ExportTemp.sweepPrefixed(NewDrawing.tempDirectoryPrefix, startedAt: cutoff)

        #expect(!FileManager.default.fileExists(atPath: stale.path))   // pre-cutoff stage reclaimed
        #expect(FileManager.default.fileExists(atPath: fresh.path))    // post-cutoff stage kept (sweep race)
    }

    // MARK: - §f/§g Thumbnail cache eviction

    @MainActor
    @Test func thumbnailCacheEvictsOnRemoveAndClear() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let id = try #require(await store.handleOpenedURL(writeEMF(to: dir, name: "thumb.emf")))
        let entry = try #require(store.entry(id: id))

        #expect(await store.loadThumbnail(for: entry) != nil)   // renders + caches
        #expect(store.cachedThumbnail(for: entry) != nil)

        store.remove(id)
        #expect(store.cachedThumbnail(for: entry) == nil)       // evicted with the entry

        let id2 = try #require(await store.handleOpenedURL(writeEMF(to: dir, name: "thumb2.emf")))
        let entry2 = try #require(store.entry(id: id2))
        _ = await store.loadThumbnail(for: entry2)
        #expect(store.cachedThumbnail(for: entry2) != nil)
        store.clear()
        #expect(store.cachedThumbnail(for: entry2) == nil)      // cleared
    }

    /// After an in-memory eviction while the entry is still present (its on-disk PNG
    /// intact), the cache reads nil — the trigger that flips the tile's task
    /// `needsLoad` — and `loadThumbnail` repopulates it from disk, so the tile reloads
    /// instead of staying blank (review #3).
    @MainActor
    @Test func thumbnailReloadsAfterInMemoryEviction() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let id = try #require(await store.handleOpenedURL(writeEMF(to: dir, name: "evict.emf")))
        let entry = try #require(store.entry(id: id))

        _ = try #require(await store.loadThumbnail(for: entry))   // renders + caches
        #expect(store.cachedThumbnail(for: entry) != nil)

        store.evictThumbnailCacheForTesting()                     // simulate NSCache eviction
        #expect(store.cachedThumbnail(for: entry) == nil)         // task would see nil -> needsLoad flips
        #expect(store.entry(id: id) != nil)                       // entry (and its PNG) still there

        #expect(await store.loadThumbnail(for: entry) != nil)     // reloads from the kept PNG
        #expect(store.cachedThumbnail(for: entry) != nil)         // repopulated, tile no longer blank
    }

    @MainActor
    @Test func thumbnailRegeneratesWhenCachePurged() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = makeStore(in: dir)
        let id = try #require(await store.handleOpenedURL(writeEMF(to: dir, name: "regen.emf")))
        _ = try #require(store.entry(id: id))
        // Simulate Caches being purged: delete the cached PNG and drop the memory cache.
        try FileManager.default.removeItem(at: store.locations.thumbnailsDirectory)
        store.clear()   // wipes memory cache (entry stays via re-add below)

        let readd = try #require(await store.handleOpenedURL(writeEMF(to: dir, name: "regen.emf")))
        let entry2 = try #require(store.entry(id: readd))
        try? FileManager.default.removeItem(at: store.locations.thumbnailsDirectory)   // purge again
        // loadThumbnail must regenerate from the file even with no cached PNG.
        #expect(await store.loadThumbnail(for: entry2) != nil)
    }

    // MARK: - §k Export runner cancellation / single-in-flight

    @MainActor
    @Test func runnerSupersedesFirstRunWithSecond() async {
        let runner = ExportTaskRunner()
        var firstDelivered = false
        var secondValue = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runner.run(
                setBusy: { _ in },
                render: { () -> Int in
                    for _ in 0..<60 where !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                    return 1
                },
                done: { _ in firstDelivered = true }
            )
            runner.run(
                setBusy: { _ in },
                render: { 2 },
                done: { value in secondValue = value; cont.resume() }
            )
        }
        #expect(secondValue == 2)
        #expect(!firstDelivered)   // the superseded (cancelled) first render never delivers
    }

    @MainActor
    @Test func runnerKeepsAtMostOneRenderInFlight() async {
        let runner = ExportTaskRunner()
        let probe = ConcurrencyProbe()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runner.run(
                setBusy: { _ in },
                render: { () -> Int in
                    probe.enter(); defer { probe.leave() }
                    for _ in 0..<30 where !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                    return 1
                },
                done: { _ in }
            )
            runner.run(
                setBusy: { _ in },
                render: { () -> Int in
                    probe.enter(); defer { probe.leave() }
                    Thread.sleep(forTimeInterval: 0.02)
                    return 2
                },
                done: { _ in cont.resume() }
            )
        }
        #expect(probe.maxConcurrent <= 1)   // the two renders never overlap
        #expect(probe.everRan)
    }

    // MARK: - Diagnostics text (§3)

    @Test func unimplementedRecordNoteMatchesBriefExample() {
        let note = EMFRenderLog.Entry.unimplementedRecord(type: 70, count: 3).note
        #expect(note.summary == "3 drawing instructions of a kind Emfy doesn't support yet were skipped.")
        #expect(note.technicalDetail == "Skipped unsupported record type 70 (3 occurrences).")
    }

    @Test func emptyFontNameReadsNaturally() {
        let note = EMFRenderLog.Entry.fontSubstituted(requested: "", used: "Helvetica", count: 1).note
        #expect(note.technicalDetail == "Used Helvetica instead of an unnamed unavailable font (1 occurrence).")
        #expect(!note.technicalDetail.contains("font  "))   // no stranded double space
        // The summary names NO substitute font — the replacement may be a user-chosen
        // family, which must not reach the copyable diagnostic report (S-L4).
        #expect(!note.summary.contains("Helvetica"))
        #expect(note.summary == "A font the file asked for wasn't available, so Emfy used a substitute instead (1 occurrence).")
    }

    @Test func namedFontSubstitutionWording() {
        let note = EMFRenderLog.Entry.fontSubstituted(requested: "Arial", used: "Helvetica", count: 2).note
        #expect(note.technicalDetail == "Used Helvetica instead of unavailable font Arial (2 occurrences).")
    }

    @Test func couldNotShowFiltersAdvisoryNotes() {
        let diagnostics = ViewerDiagnostics(
            kind: .emf,
            embeddedEMF: .notApplicable,
            renderLog: [.stockFontUsed(rawValue: 1, count: 1), .unimplementedRecord(type: 70, count: 1)],
            parserDiagnostics: [.recordCountMismatch(headerSays: 5, walked: 4)],
            frontDoorDiagnostics: [],
            wasDecompressed: false
        )
        let summaries = diagnostics.couldNotShowNotes.map(\.summary)
        #expect(summaries.contains { $0.contains("doesn't support yet") })   // kept
        #expect(!summaries.contains { $0.contains("built-in font") })        // stock-font fallback filtered
        #expect(!summaries.contains { $0.contains("record count") })         // count mismatch filtered
        // Render Details is unfiltered.
        #expect(diagnostics.allParserNotes.count == 1)
        #expect(diagnostics.allRenderNotes.count == 2)
    }

    @Test func eachNoteCarriesSummaryAndTechnicalDetail() {
        let note = EMFRenderLog.Entry.unsupportedBrushStyle(rawStyle: 9).note
        #expect(!note.summary.isEmpty)
        #expect(!note.technicalDetail.isEmpty)
        #expect(note.summary != note.technicalDetail)
    }
}

// MARK: - C4b pure helpers (P3 size/meta line, P7 grid partition, P6 notes-at-load, D1 grouping)

@Suite struct C4bHelperTests {

    private func entry(
        name: String = "doc.emf",
        format: String = "EMF",
        fullName: String = "Enhanced Metafile",
        bytes: Int64 = 20_480,
        openedAt: Date
    ) -> RecentEntry {
        RecentEntry(
            id: UUID(), displayName: name, formatLabel: format, fullFormatName: fullName,
            byteCount: bytes, openedAt: openedAt, bookmark: Data([1]), thumbnailFileName: nil,
            fileIdentity: name, importedFileName: nil, reloadToken: nil
        )
    }

    // P3 — one size / meta-line helper, replacing the four former copies.

    @Test func sizeLabelAndMetaLineToday() {
        let now = Date()
        let e = entry(openedAt: now)
        #expect(!e.sizeLabel.isEmpty)
        let line = e.metaLine(now: now)
        #expect(line.hasPrefix("EMF · "))
        #expect(line.hasSuffix(e.sizeLabel))            // today → size at the tail
        #expect(e.metaSecond(now: now) == e.sizeLabel)
        #expect(e.formatSizeSubtitle == "Enhanced Metafile · \(e.sizeLabel)")
    }

    @Test func metaLineEarlierShowsDateNotSize() {
        let now = Date()
        let earlier = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let e = entry(openedAt: earlier)
        let line = e.metaLine(now: now)
        #expect(line.hasPrefix("EMF · "))
        #expect(!line.hasSuffix(e.sizeLabel))           // earlier → date, not size
        #expect(e.metaSecond(now: now) != e.sizeLabel)
    }

    // P7 — single-pass today/earlier partition.

    @Test func partitionSplitsTodayAndEarlierInOrder() {
        let now = Date()
        let t1 = entry(name: "t1", openedAt: now)
        let t2 = entry(name: "t2", openedAt: Calendar.current.startOfDay(for: now).addingTimeInterval(3600))
        let old = entry(name: "old", openedAt: Calendar.current.date(byAdding: .day, value: -2, to: now)!)
        let partition = RecentEntry.partitionedByDay([t1, old, t2], now: now)
        #expect(partition.today.map(\.displayName) == ["t1", "t2"])   // input order kept
        #expect(partition.earlier.map(\.displayName) == ["old"])
    }

    @Test func partitionEmptyIsEmpty() {
        let partition = RecentEntry.partitionedByDay([], now: Date())
        #expect(partition.today.isEmpty)
        #expect(partition.earlier.isEmpty)
    }

    // D1 — identically-worded "unsupported record" rows merge into one summed row.

    @Test func coalescesTwoIdenticallyWordedUnsupportedRows() {
        let notes = ViewerDiagnostics.coalescedRenderNotes([
            .unimplementedRecord(type: 70, count: 3),
            .unimplementedRecord(type: 80, count: 1),
        ])
        #expect(notes.count == 1)
        #expect(notes.first?.summary == "4 drawing instructions of a kind Emfy doesn't support yet were skipped.")
        // The per-type technical detail is preserved under the merged row.
        #expect(notes.first?.technicalDetail.contains("70") == true)
        #expect(notes.first?.technicalDetail.contains("80") == true)
    }

    @Test func singleUnsupportedRowIsUnchanged() {
        let notes = ViewerDiagnostics.coalescedRenderNotes([.unimplementedRecord(type: 70, count: 3)])
        #expect(notes.count == 1)
        #expect(notes.first?.summary == "3 drawing instructions of a kind Emfy doesn't support yet were skipped.")
        #expect(notes.first?.technicalDetail == "Skipped unsupported record type 70 (3 occurrences).")
    }

    @Test func coalescingKeepsOtherNotesAndOrder() {
        let notes = ViewerDiagnostics.coalescedRenderNotes([
            .unimplementedRecord(type: 70, count: 1),
            .malformedRecord(type: 99),
            .unimplementedRecord(type: 71, count: 1),
        ])
        #expect(notes.count == 2)                                     // merged + the malformed note
        #expect(notes.first?.summary == "2 drawing instructions of a kind Emfy doesn't support yet were skipped.")
        #expect(notes.last?.summary.contains("damaged") == true)
    }

    @Test func couldNotShowMergesTheTwoRows() {
        let diagnostics = ViewerDiagnostics(
            kind: .emf, embeddedEMF: .notApplicable,
            renderLog: [.unimplementedRecord(type: 70, count: 3), .unimplementedRecord(type: 80, count: 1)],
            parserDiagnostics: [], frontDoorDiagnostics: [], wasDecompressed: false
        )
        let unsupported = diagnostics.couldNotShowNotes.filter { $0.summary.contains("doesn't support yet") }
        #expect(unsupported.count == 1)
        #expect(unsupported.first?.summary.contains("4 drawing instructions") == true)
    }

    // P6 — the "couldn't show" notes and partial-support message are computed once at
    // load, and must equal the live diagnostics values.

    @Test func loadedMetafilePrecomputesDiagnosticsNotes() throws {
        let loaded = try MetafileLoader.load(EmfyTests.minimalEMF())
        #expect(loaded.couldNotShowNotes == loaded.diagnostics.couldNotShowNotes)
        #expect(loaded.partialSupportMessage == loaded.diagnostics.partialSupportMessage)
    }
}

/// A lock-guarded concurrency counter for the runner test. Synchronous so it can
/// be called from the runner's non-async render closure.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxConcurrent = 0
    private(set) var everRan = false

    func enter() {
        lock.lock(); defer { lock.unlock() }
        active += 1
        everRan = true
        maxConcurrent = max(maxConcurrent, active)
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }
}
