import CoreSpotlight
import Foundation
import Testing

// F3d unit tests for the Core Spotlight integration: the `RecentsSpotlightBridge` maps each
// recents lifecycle event onto index/delete calls (through a recording fake of the index
// seam), the activity identifier routes back to an entry id (unknown ids ignored), and the
// `RecentsStore` actually fires the lifecycle observer on add/remove/clear/Private change.

@MainActor
@Suite struct RecentsSpotlightTests {

    // A recording fake standing in for CoreSpotlightIndex.
    private actor FakeIndex: DrawingSpotlightIndex {
        var indexed: [[DrawingSpotlightItem]] = []
        var removed: [[String]] = []
        var removedAllCount = 0
        func index(_ items: [DrawingSpotlightItem]) async { indexed.append(items) }
        func removeItems(ids: [String]) async { removed.append(ids) }
        func removeAll() async { removedAllCount += 1 }
    }

    // Mutable settings/entries the bridge reads through its closures.
    private final class Env {
        var enabled = true
        var privateMode = false
        var ids: [UUID] = []
    }

    private func makeBridge(_ env: Env, _ fake: FakeIndex) -> RecentsSpotlightBridge {
        RecentsSpotlightBridge(
            coordinator: DrawingSpotlightCoordinator(index: fake),
            isEnabled: { env.enabled },
            isPrivate: { env.privateMode },
            currentEntryIDs: { env.ids },
            // A huge throttle: the debounced auto-flush never fires within a test, so each
            // test drives `flushNow()` / the awaitable internals deterministically.
            throttle: .seconds(3600),
            buildItem: { id in
                DrawingSpotlightItem(
                    id: id.uuidString, title: "f.emf", contentDescription: "d",
                    textContent: "Hello", contentTypeIdentifier: "com.microsoft.emf")
            }
        )
    }

    // MARK: Bridge mapping

    @Test func addIndexesTheEntry() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        let id = UUID()
        bridge.recentsEntryAddedOrRefreshed(id: id)
        await bridge.flushNow()
        let indexed = await fake.indexed
        #expect(indexed.count == 1)
        #expect(indexed.first?.first?.id == id.uuidString)
    }

    @Test func addIsGatedWhenDisabledOrPrivate() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        env.enabled = false
        bridge.recentsEntryAddedOrRefreshed(id: UUID())
        await bridge.flushNow()
        #expect(await fake.indexed.isEmpty)

        env.enabled = true; env.privateMode = true
        bridge.recentsEntryAddedOrRefreshed(id: UUID())
        await bridge.flushNow()
        #expect(await fake.indexed.isEmpty)
    }

    @Test func removeAndPruneDeleteTheIds() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        let a = UUID(), b = UUID()
        await bridge.removeNow([a])
        await bridge.removeNow([a, b])
        let removed = await fake.removed
        #expect(removed == [[a.uuidString], [a.uuidString, b.uuidString]])
    }

    @Test func clearWipesTheDomain() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        await bridge.clearNow()
        #expect(await fake.removedAllCount == 1)
    }

    @Test func privateOnWipesTheDomain() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        env.privateMode = true
        await bridge.settingsOrPrivateChangedNow()
        #expect(await fake.removedAllCount == 1)
        #expect(await fake.indexed.isEmpty)
    }

    @Test func toggleOffWipesTheDomain() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        env.enabled = false
        await bridge.settingsOrPrivateChangedNow()
        #expect(await fake.removedAllCount == 1)
    }

    @Test func toggleOnResyncsAllEntries() async {
        let fake = FakeIndex(); let env = Env(); let bridge = makeBridge(env, fake)
        let a = UUID(), b = UUID()
        env.ids = [a, b]
        await bridge.settingsOrPrivateChangedNow()   // enabled, not private → re-sync
        let indexed = await fake.indexed
        #expect(indexed.count == 1)
        #expect(Set(indexed.first?.map(\.id) ?? []) == Set([a.uuidString, b.uuidString]))
        #expect(await fake.removedAllCount == 0)
    }

    // MARK: Activity routing

    @Test func activityRoutesToTheEntryId() {
        let id = UUID()
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
        #expect(CoreSpotlightActivity.entryID(from: activity) == id)
    }

    @Test func unknownActivityTypeIsIgnored() {
        let activity = NSUserActivity(activityType: "com.example.other")
        activity.userInfo = [CSSearchableItemActivityIdentifier: UUID().uuidString]
        #expect(CoreSpotlightActivity.entryID(from: activity) == nil)
    }

    @Test func malformedIdentifierIsIgnored() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "not-a-uuid"]
        #expect(CoreSpotlightActivity.entryID(from: activity) == nil)
    }

    // MARK: Store wiring (the store fires the observer)

    private final class RecordingObserver: RecentsLifecycleObserver {
        var added: [UUID] = []
        var removed: [[UUID]] = []
        var clearedCount = 0
        var privateChangedCount = 0
        func recentsEntryAddedOrRefreshed(id: UUID) { added.append(id) }
        func recentsEntriesRemoved(ids: [UUID]) { removed.append(ids) }
        func recentsCleared() { clearedCount += 1 }
        func recentsPrivateModeChanged() { privateChangedCount += 1 }
    }

    @Test func storeFiresLifecycleObserver() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfySpotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)))
        let observer = RecordingObserver()
        store.lifecycleObserver = observer

        let url = dir.appendingPathComponent("a.emf")
        try EmfyTests.minimalEMF().write(to: url)
        let id = try #require(await store.handleOpenedURL(url))
        #expect(observer.added == [id])

        store.remove(id)
        #expect(observer.removed == [[id]])

        store.setPrivate(true)
        #expect(observer.privateChangedCount == 1)
        store.setPrivate(false)
        #expect(observer.privateChangedCount == 2)

        store.clear()
        #expect(observer.clearedCount == 1)
    }
}
