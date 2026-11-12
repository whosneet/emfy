import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Core Spotlight index (F3d)
//
// The concrete `DrawingSpotlightIndex` backed by `CSSearchableIndex.default()`. It mirrors
// recents into the "recents" domain so a Spotlight hit maps back to a recents entry id via
// `onContinueUserActivity`. The pure core (`DrawingSpotlightCoordinator` + the policy +
// the item builder) decides WHAT to index; this type only turns items into
// `CSSearchableItem`s and talks to the system index. Each method is a no-op when indexing
// isn't available, and swallows index errors (a failed Spotlight write must never surface).

struct CoreSpotlightIndex: DrawingSpotlightIndex {
    /// The one domain every indexed drawing lives in, so a wipe (Clear Recents, Private mode,
    /// toggle off) can delete the whole set in one call.
    static let domainIdentifier = "recents"

    /// The system default searchable index. A fresh handle per call keeps this type a plain
    /// `Sendable` value with no stored (non-Sendable) `CSSearchableIndex`.
    private var index: CSSearchableIndex { .default() }

    func index(_ items: [DrawingSpotlightItem]) async {
        guard CSSearchableIndex.isIndexingAvailable(), !items.isEmpty else { return }
        let searchable = items.map { Self.searchableItem($0) }
        try? await index.indexSearchableItems(searchable)
    }

    func removeItems(ids: [String]) async {
        guard CSSearchableIndex.isIndexingAvailable(), !ids.isEmpty else { return }
        try? await index.deleteSearchableItems(withIdentifiers: ids)
    }

    func removeAll() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
    }

    /// Builds the `CSSearchableItem` for a drawing: the file name as the title, the short
    /// description as the subtitle, the extracted + OCR text as full-text content, the file's
    /// content type, and the recents thumbnail when one is carried on the item.
    static func searchableItem(_ item: DrawingSpotlightItem) -> CSSearchableItem {
        let type = UTType(item.contentTypeIdentifier) ?? .data
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = item.title
        attributes.displayName = item.title
        attributes.contentDescription = item.contentDescription
        attributes.textContent = item.textContent
        if !item.keywords.isEmpty {
            attributes.keywords = item.keywords
        }
        if let thumbnail = item.thumbnailData {
            attributes.thumbnailData = thumbnail
        }
        // F4b: on macOS 15 / iOS 18+, link this single indexed item to its App Intents
        // entity so Siri / Apple Intelligence can act on the result — associating rather
        // than indexing the entity a second time (DrawingEntityIndexing.swift).
        if #available(macOS 15, iOS 18, *), let entity = DrawingEntityIndexing.entity(forSpotlight: item) {
            attributes.associateAppEntity(entity)
        }
        return CSSearchableItem(
            uniqueIdentifier: item.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}

// MARK: - Opening a Spotlight result

/// Maps a `CSSearchableItemActionType` user activity back to the recents entry id it
/// identifies (F3d). The app routes the result into the library window (Mac) or the viewer
/// (iOS); an unknown or malformed identifier yields `nil` and is ignored gracefully.
enum CoreSpotlightActivity {
    /// The entry id for a Spotlight-result activity, or `nil` when the activity isn't a
    /// Spotlight result or carries no decodable identifier.
    static func entryID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }
        return UUID(uuidString: raw)
    }
}
