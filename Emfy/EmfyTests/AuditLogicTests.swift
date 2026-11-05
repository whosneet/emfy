import Foundation
import Photos
import Testing

// C4a unit tests for the audit sweep's pure logic and the store's deferred-deletion
// undo: the cap eviction policy, the removal-confirmation wording selection, the
// failure-reason → actions mapping, the Photos status mapping, and the deferred
// side-file deletion with undo. Compiled into the hostless logic bundle like the
// rest, so they run on macOS and the iOS simulator.

// MARK: - Cap eviction policy (H3)

@Suite struct CapEvictionTests {

    private func entry(_ name: String, daysAgo: Double, received: Bool) -> RecentEntry {
        RecentEntry(
            id: UUID(), displayName: name, formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 1, openedAt: Date().addingTimeInterval(-daysAgo * 86400),
            bookmark: Data([1]), thumbnailFileName: nil, fileIdentity: name,
            importedFileName: received ? "\(name).copy" : nil, reloadToken: nil
        )
    }

    @Test func nothingEvictedWhenUnderOrAtCap() {
        let entries = [entry("a", daysAgo: 1, received: false), entry("b", daysAgo: 2, received: false)]
        #expect(RecentsStore.entriesToEvict(from: entries, max: 2).isEmpty)
        #expect(RecentsStore.entriesToEvict(from: entries, max: 5).isEmpty)
    }

    @Test func evictsOldestNonReceivedFirst() {
        let entries = [
            entry("new", daysAgo: 1, received: false),
            entry("mid", daysAgo: 2, received: false),
            entry("old", daysAgo: 3, received: false),
        ]
        let evicted = RecentsStore.entriesToEvict(from: entries, max: 2).map(\.displayName)
        #expect(evicted == ["old"])   // oldest dropped, cap of 2 keeps the two newest
    }

    @Test func keepsReceivedEvenWhenOlderThanAnEvictableOrdinaryEntry() {
        // A received copy (10 days old) must outlive a newer ordinary file, because
        // Emfy holds its only copy (owner decision).
        let entries = [
            entry("received", daysAgo: 10, received: true),
            entry("ordinaryNew", daysAgo: 1, received: false),
            entry("ordinaryOld", daysAgo: 2, received: false),
        ]
        let evicted = RecentsStore.entriesToEvict(from: entries, max: 2).map(\.displayName)
        #expect(evicted == ["ordinaryOld"])   // the oldest ORDINARY entry, not the older received one
    }

    @Test func evictsReceivedOnlyWhenNoOrdinaryEntryLeftToDrop() {
        let entries = [
            entry("receivedOld", daysAgo: 10, received: true),
            entry("receivedMid", daysAgo: 5, received: true),
            entry("ordinary", daysAgo: 1, received: false),
        ]
        // max 1 → drop 2: the ordinary one first, then the oldest received.
        let evicted = RecentsStore.entriesToEvict(from: entries, max: 1).map(\.displayName)
        #expect(evicted == ["ordinary", "receivedOld"])
    }
}

// MARK: - Removal-confirmation wording (H3, H2)

@Suite struct RemovalConfirmationTests {

    @Test func singleOrdinaryRemovesInstantly() {
        let plan = RemovalConfirmation.plan(forSingleReceived: false)
        #expect(!plan.needsConfirmation)
        #expect(!plan.offersSaveCopy)
    }

    @Test func singleReceivedConfirmsAndOffersSaveCopy() {
        let plan = RemovalConfirmation.plan(forSingleReceived: true)
        #expect(plan.needsConfirmation)
        #expect(plan.offersSaveCopy)
        #expect(!plan.saveCopyIsMultiple)
        #expect(plan.destructiveTitle == "Remove")
        #expect(plan.message.contains("only copy"))
    }

    @Test func clearWithoutReceivedConfirmsWithoutSaveCopy() {
        let plan = RemovalConfirmation.plan(scope: .clear, receivedCount: 0, totalCount: 5)
        #expect(plan.needsConfirmation)
        #expect(!plan.offersSaveCopy)
        #expect(plan.destructiveTitle == "Clear Recents")
        #expect(plan.message.contains("not deleted"))
    }

    @Test func clearWithOneReceivedOffersSingleSaveCopy() {
        let plan = RemovalConfirmation.plan(scope: .clear, receivedCount: 1, totalCount: 4)
        #expect(plan.offersSaveCopy)
        #expect(!plan.saveCopyIsMultiple)
        #expect(plan.message.contains("only copy"))
    }

    @Test func clearWithSeveralReceivedOffersFolderSaveCopy() {
        let plan = RemovalConfirmation.plan(scope: .clear, receivedCount: 3, totalCount: 6)
        #expect(plan.offersSaveCopy)
        #expect(plan.saveCopyIsMultiple)
        #expect(plan.message.contains("those copies"))
    }
}

// MARK: - Failure-reason → actions (H4, A10, M4)

@Suite struct ViewerFailurePresentationTests {

    @Test func notFoundOffersRemoveOnly() {
        #expect(ViewerFailurePresentation.actions(for: .notFound) == [.remove])
        #expect(!ViewerFailurePresentation.offersTryAgain(for: .notFound))
    }

    @Test func transientOffersTryAgainThenRemove() {
        #expect(ViewerFailurePresentation.actions(for: .unavailable) == [.tryAgain, .remove])
        #expect(ViewerFailurePresentation.offersTryAgain(for: .unavailable))
    }

    @Test func unreadableOffersTryAgainTooPerM4() {
        #expect(ViewerFailurePresentation.actions(for: .unreadable) == [.tryAgain, .remove])
        #expect(ViewerFailurePresentation.offersTryAgain(for: .unreadable))
    }

    @Test func eachReasonHasDistinctMessage() {
        let messages = Set([
            ViewerFailurePresentation.message(for: .notFound),
            ViewerFailurePresentation.message(for: .unavailable),
            ViewerFailurePresentation.message(for: .unreadable),
        ])
        #expect(messages.count == 3)
    }
}

// MARK: - Photos status mapping (H7)

@Suite struct PhotoSaveDecisionTests {

    @Test func grantedStatusesProceed() {
        #expect(PhotoSaveDecision.outcome(previousStatus: .notDetermined, resolvedStatus: .authorized) == .proceed)
        #expect(PhotoSaveDecision.outcome(previousStatus: .notDetermined, resolvedStatus: .limited) == .proceed)
        #expect(PhotoSaveDecision.outcome(previousStatus: .authorized, resolvedStatus: .authorized) == .proceed)
    }

    @Test func restrictedIsItsOwnOutcome() {
        #expect(PhotoSaveDecision.outcome(previousStatus: .notDetermined, resolvedStatus: .restricted) == .restricted)
        #expect(PhotoSaveDecision.outcome(previousStatus: .restricted, resolvedStatus: .restricted) == .restricted)
    }

    @Test func freshDeclineIsSilent() {
        // notDetermined → denied means the user just declined the system prompt.
        #expect(PhotoSaveDecision.outcome(previousStatus: .notDetermined, resolvedStatus: .denied) == .deniedSilently)
    }

    @Test func preExistingDenialOffersSettings() {
        #expect(PhotoSaveDecision.outcome(previousStatus: .denied, resolvedStatus: .denied) == .deniedNeedsSettings)
    }
}

// MARK: - Deferred deletion + undo (H3)

@MainActor
@Suite(.serialized)
struct DeferredRemovalTests {

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUndo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(in dir: URL) -> RecentsStore {
        RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        ))
    }

    @discardableResult
    private func addEMF(to store: RecentsStore, in dir: URL, name: String) async -> UUID? {
        let url = dir.appendingPathComponent(name)
        try? EmfyTests.minimalEMF().write(to: url)
        return await store.handleOpenedURL(url)
    }

    @Test func removeDefersSideFileDeletionAndUndoRestoresBoth() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let id = try #require(await addEMF(to: store, in: dir, name: "doc.emf"))
        let entry = try #require(store.entry(id: id))
        // A plain temp file is imported, so it has a side file to protect.
        let importedName = try #require(entry.importedFileName)
        let importedURL = store.locations.importedDirectory.appendingPathComponent(importedName)
        #expect(FileManager.default.fileExists(atPath: importedURL.path))

        store.remove(id)
        #expect(store.entry(id: id) == nil)                                   // out of the list
        #expect(store.pendingRemoval != nil)                                  // but pending undo
        #expect(FileManager.default.fileExists(atPath: importedURL.path))     // side file kept

        store.undoLastRemoval()
        #expect(store.entry(id: id) != nil)                                   // entry back
        #expect(store.pendingRemoval == nil)
        #expect(FileManager.default.fileExists(atPath: importedURL.path))     // file back too
    }

    @Test func committingPendingRemovalDeletesSideFiles() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let id = try #require(await addEMF(to: store, in: dir, name: "doc.emf"))
        let importedName = try #require(store.entry(id: id)?.importedFileName)
        let importedURL = store.locations.importedDirectory.appendingPathComponent(importedName)

        store.remove(id)
        store.commitPendingRemoval()
        #expect(store.pendingRemoval == nil)
        #expect(!FileManager.default.fileExists(atPath: importedURL.path))    // deleted on commit
    }

    @Test func aSecondRemovalCommitsTheFirst() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let id1 = try #require(await addEMF(to: store, in: dir, name: "one.emf"))
        let first = store.locations.importedDirectory
            .appendingPathComponent(try #require(store.entry(id: id1)?.importedFileName))
        let id2 = try #require(await addEMF(to: store, in: dir, name: "two.emf"))

        store.remove(id1)                                                     // pending: one
        store.remove(id2)                                                     // commits one, pending: two
        #expect(!FileManager.default.fileExists(atPath: first.path))          // one's side file gone
        #expect(store.pendingRemoval?.entry.id == id2)
    }

    /// Quitting inside the undo window (the pending removal never commits) must not
    /// leak the removed entry's imported copy and thumbnail: the entry is already out
    /// of the persisted list, so the next launch's orphan sweep reclaims them (H3).
    @Test func removalNotCommittedBeforeQuitIsReclaimedByLaunchSweep() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let locations = RecentsStore.Locations(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        let imported: URL
        let thumbnail: URL
        do {
            let store = RecentsStore(locations: locations)
            let url = dir.appendingPathComponent("gone.emf")
            try EmfyTests.minimalEMF().write(to: url)
            let id = try #require(await store.handleOpenedURL(url))
            let entry = try #require(store.entry(id: id))
            imported = store.locations.importedDirectory.appendingPathComponent(try #require(entry.importedFileName))
            thumbnail = store.locations.thumbnailsDirectory.appendingPathComponent(try #require(entry.thumbnailFileName))
            #expect(FileManager.default.fileExists(atPath: imported.path))

            store.remove(id)                                     // pending; side files deferred
            #expect(store.pendingRemoval != nil)
            #expect(FileManager.default.fileExists(atPath: imported.path))
            // "Quit": drop the store without committing. Await the removal's write so
            // the relaunch below reads the persisted list (which excludes the removed
            // entry) rather than racing the background write.
            await store.waitForPersistenceForTesting()
        }

        // Next launch: a fresh store over the same locations runs the orphan sweep.
        let relaunched = RecentsStore(locations: locations)
        await relaunched.loadIfNeeded()
        #expect(relaunched.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imported.path))    // reclaimed, not leaked
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))   // reclaimed, not leaked
    }
}
