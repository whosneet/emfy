import EMFRender
import Foundation

// MARK: - Spotlight service (F3d)
//
// The app-side owner of Spotlight mirroring: it builds the `RecentsSpotlightBridge` over a
// `CoreSpotlightIndex`, installs it as `RecentsStore`'s lifecycle observer, and supplies the
// item builder — the only place that pulls in EMFKit and Vision. Item building runs off the
// main actor at background priority (parse → text extract → OCR → thumbnail), so neither a
// recents add nor the launch sync blocks the UI.

@MainActor
final class SpotlightService {
    static let shared = SpotlightService()

    private var bridge: RecentsSpotlightBridge?
    private weak var store: RecentsStore?
    private weak var settings: EmfySettings?
    private var didSyncOnLaunch = false

    private init() {}

    /// Installs the bridge as the store's lifecycle observer (idempotent). Called once at app
    /// start, before any open can add an entry.
    func activate(store: RecentsStore, settings: EmfySettings) {
        guard bridge == nil else { return }
        self.store = store
        self.settings = settings
        let coordinator = DrawingSpotlightCoordinator(index: CoreSpotlightIndex())
        let bridge = RecentsSpotlightBridge(
            coordinator: coordinator,
            isEnabled: { settings.showDrawingsInSpotlight },
            isPrivate: { store.isPrivate },
            currentEntryIDs: { store.nonPrivateEntries.map(\.id) },
            buildItem: { [weak self] id in await self?.buildItem(for: id) ?? nil }
        )
        self.bridge = bridge
        store.lifecycleObserver = bridge
    }

    /// Index the recents already on disk, once per launch, throttled so launch never blocks.
    /// Called from the library window's `.task` after the store has loaded.
    func syncOnLaunch() {
        guard !didSyncOnLaunch else { return }
        didSyncOnLaunch = true
        bridge?.syncAll()
    }

    /// The "Show drawings in Spotlight" setting changed: the bridge wipes or re-syncs.
    func settingsChanged() {
        bridge?.settingsOrPrivateChanged()
    }

    // MARK: - Item building (off-main)

    /// Builds the searchable item for a recents entry: resolves its bytes, extracts drawing
    /// text (plus picture OCR when enabled) and attaches the cached thumbnail — all at
    /// background priority off the main actor. `nil` for a session-private, missing or
    /// unreadable entry, so it is simply not indexed.
    private func buildItem(for id: UUID) async -> DrawingSpotlightItem? {
        guard let store, let settings,
              let entry = store.entry(id: id), !store.isSessionPrivate(id) else { return nil }
        let bookmark = entry.bookmark
        let fileName = entry.displayName
        let contentType = Self.contentTypeIdentifier(for: fileName)
        let thumbnailURL = entry.thumbnailFileName.map {
            store.locations.thumbnailsDirectory.appendingPathComponent($0)
        }
        let ocrEnabled = settings.recognizeTextInPictures
        let options = settings.renderOptions
        let idString = id.uuidString
        // AI title/tags become Spotlight keywords, but only while AI is on and Private
        // mode is off — otherwise stored AI metadata is ignored (A1b).
        let aiKeywords: [String] = (settings.useOnDeviceAI && !store.isPrivate)
            ? (entry.aiTitleTags.map { [$0.title] + $0.tags } ?? [])
            : []

        return await Task.detached(priority: .background) { () -> DrawingSpotlightItem? in
            guard case .success(let data, _) = RecentsStore.resolveBookmark(bookmark),
                  let loaded = try? MetafileLoader.load(data, options: options) else { return nil }
            let observation = MetafileRenderer.observe(loaded.prepared, options: options)
            let drawingRuns = DrawingTextExtractor.extract(from: observation)
            var pictureRuns: [DrawingTextRun] = []
            if ocrEnabled {
                let pictures = DrawingPictureEnumerator.pictures(from: observation)
                pictureRuns = await DrawingOCRService.shared.recognize(pictures: pictures)
            }
            let thumbnail = thumbnailURL.flatMap { try? Data(contentsOf: $0) }
            var item = DrawingSpotlightBuilder.item(
                id: idString,
                fileName: fileName,
                contentTypeIdentifier: contentType,
                drawingText: drawingRuns,
                pictureText: pictureRuns
            )
            item.thumbnailData = thumbnail
            item.keywords = aiKeywords.filter { !$0.isEmpty }
            return item
        }.value
    }

    /// The content UTI for a metafile name, so a Spotlight result carries the right type.
    /// `nonisolated` so the off-main item builder can call it.
    nonisolated static func contentTypeIdentifier(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "emf": return "com.microsoft.emf"
        case "wmf": return "com.microsoft.wmf"
        case "emz": return "com.microsoft.emz"
        case "wmz": return "com.microsoft.wmz"
        default: return "public.data"
        }
    }
}
