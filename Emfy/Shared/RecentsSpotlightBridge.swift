import Foundation

// MARK: - Recents → Spotlight bridge (F3d)
//
// `RecentsStore` reports its lifecycle (add/refresh, remove/prune, clear, Private-mode
// change) to a `RecentsLifecycleObserver`; the app sets it to a `RecentsSpotlightBridge`,
// which maps each event onto a `DrawingSpotlightCoordinator` call. The bridge builds the
// searchable item off-main through an injected builder (so EMFKit/Vision stay out of the
// store and out of the bridge's own file), and debounces a burst (the launch sync) so
// indexing never blocks launch. The store never owns or awaits the bridge — Spotlight
// mirroring is best-effort and entirely side-of-stage.

/// The recents lifecycle sink. Held weakly by the store; set by the app to the bridge.
@MainActor
protocol RecentsLifecycleObserver: AnyObject {
    func recentsEntryAddedOrRefreshed(id: UUID)
    func recentsEntriesRemoved(ids: [UUID])
    func recentsCleared()
    /// Private mode turned on or off (the store doesn't know the Spotlight toggle, so the
    /// bridge decides wipe-vs-resync from both).
    func recentsPrivateModeChanged()
}

@MainActor
final class RecentsSpotlightBridge: RecentsLifecycleObserver {
    private let coordinator: DrawingSpotlightCoordinator
    /// Builds the searchable item for an entry id (off-main inside), or `nil` when the entry
    /// is gone or unreadable. Injected so the heavy parse/OCR stays in the app's service.
    private let buildItem: @MainActor (UUID) async -> DrawingSpotlightItem?
    /// The current "Show drawings in Spotlight" setting.
    private let isEnabled: @MainActor () -> Bool
    /// The current Private-mode state.
    private let isPrivate: @MainActor () -> Bool
    /// Every current non-private entry id, for a full re-sync.
    private let currentEntryIDs: @MainActor () -> [UUID]
    /// Debounce before a queued (re)index runs, so a launch sync never blocks. Zero-or-large
    /// values make the queue testable via `flushNow()`.
    private let throttle: Duration

    private var pending: Set<UUID> = []
    private var flushTask: Task<Void, Never>?

    init(
        coordinator: DrawingSpotlightCoordinator,
        isEnabled: @escaping @MainActor () -> Bool,
        isPrivate: @escaping @MainActor () -> Bool,
        currentEntryIDs: @escaping @MainActor () -> [UUID],
        throttle: Duration = .milliseconds(500),
        buildItem: @escaping @MainActor (UUID) async -> DrawingSpotlightItem?
    ) {
        self.coordinator = coordinator
        self.isEnabled = isEnabled
        self.isPrivate = isPrivate
        self.currentEntryIDs = currentEntryIDs
        self.throttle = throttle
        self.buildItem = buildItem
    }

    // MARK: Lifecycle sink (fire-and-forget; the store never awaits these)

    func recentsEntryAddedOrRefreshed(id: UUID) { enqueue([id]) }

    func recentsEntriesRemoved(ids: [UUID]) { Task { await removeNow(ids) } }

    func recentsCleared() { Task { await clearNow() } }

    func recentsPrivateModeChanged() { Task { await settingsOrPrivateChangedNow() } }

    /// Index every current entry (the app-launch sync), throttled.
    func syncAll() { enqueue(currentEntryIDs()) }

    /// The Settings toggle or Private mode changed (fire-and-forget wrapper).
    func settingsOrPrivateChanged() { Task { await settingsOrPrivateChangedNow() } }

    // MARK: Awaitable internals (also the unit-test surface)

    func removeNow(_ ids: [UUID]) async {
        pending.subtract(ids)
        await coordinator.entriesRemoved(ids: ids.map(\.uuidString))
    }

    func clearNow() async {
        pending.removeAll()
        flushTask?.cancel()
        await coordinator.recentsCleared()
    }

    /// Wipe when indexing is off or Private; otherwise re-sync every current entry.
    func settingsOrPrivateChangedNow() async {
        if DrawingSpotlightPolicy.shouldWipeAll(enabled: isEnabled(), privateMode: isPrivate()) {
            pending.removeAll()
            flushTask?.cancel()
            await coordinator.indexingDisabledOrPrivate()
        } else {
            await syncAllNow()
        }
    }

    /// Re-index every current entry now (bypassing the debounce).
    func syncAllNow() async {
        guard DrawingSpotlightPolicy.shouldIndex(enabled: isEnabled(), privateMode: isPrivate()) else { return }
        pending.formUnion(currentEntryIDs())
        await flushNow()
    }

    /// Run any queued (re)index now, bypassing the debounce — the test and immediate-sync hook.
    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    // MARK: Queue

    private func enqueue(_ ids: [UUID]) {
        guard DrawingSpotlightPolicy.shouldIndex(enabled: isEnabled(), privateMode: isPrivate()) else { return }
        guard !ids.isEmpty else { return }
        pending.formUnion(ids)
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let throttle = self.throttle
        flushTask = Task { @MainActor [weak self] in
            if throttle > .zero { try? await Task.sleep(for: throttle) }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        let ids = pending
        pending.removeAll()
        guard !ids.isEmpty else { return }
        guard DrawingSpotlightPolicy.shouldIndex(enabled: isEnabled(), privateMode: isPrivate()) else { return }
        var items: [DrawingSpotlightItem] = []
        for id in ids {
            if let item = await buildItem(id) { items.append(item) }
        }
        await coordinator.reindex(items, enabled: isEnabled(), privateMode: isPrivate())
    }
}
