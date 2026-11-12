import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Apple Intelligence indexing for DrawingEntity (F4b)
//
// `DrawingEntity` conforms to `IndexedEntity` (macOS 15 / iOS 18+) so Siri and
// Apple Intelligence can find a remembered drawing semantically and offer the
// app's intents (Open / Convert / Get Text) on the result. The conformance is in
// a gated extension at the bottom of this file; everything above it is ungated so
// the attribute-set construction and the entity reconstruction are testable on the
// macOS 14 baseline without a live index.
//
// Integration with F3 Spotlight — the "associate", not "double-index", route:
// the F3 path already indexes one rich `CSSearchableItem` per drawing (full
// extracted + OCR text, thumbnail, content type) in the "recents" domain, keyed by
// the recents-entry UUID. `DrawingEntity.id` is that same UUID. So rather than
// indexing the entity a second time via `CSSearchableIndex.indexAppEntities`,
// `CoreSpotlightIndex` associates the entity with the item it is already indexing
// (`CSSearchableItemAttributeSet.associateAppEntity`, macOS 15 / iOS 18+). One item,
// one index write; the association just links that item to the app entity so the
// system can act on it. Apple documents `associateAppEntity` for exactly this
// "entities you already index with Core Spotlight" case.
//
// Privacy carries over unchanged: association happens inside `CoreSpotlightIndex`,
// which only ever sees items the F3 bridge already gated on Private mode and the
// "Show drawings in Spotlight" toggle, so nothing is linked that wasn't going to be
// indexed anyway.

/// The pure, ungated builder for a drawing's `CSSearchableItemAttributeSet` — the
/// `IndexedEntity` requirement. Kept free of `IndexedEntity` (macOS 15+) so it is
/// unit-testable on the deployment baseline.
enum DrawingEntityAttributes {

    /// The entity's indexed-text cap: a short summary for semantic matching, well
    /// under the 100k the full F3 item carries.
    static let maxSummaryCharacters = 2_000

    /// The content UTI string for a metafile name (mirrors `SpotlightService`'s map,
    /// which is app-target-only and so can't be referenced from this shared file).
    static func contentTypeIdentifier(forFileNamed fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "emf": return "com.microsoft.emf"
        case "wmf": return "com.microsoft.wmf"
        case "emz": return "com.microsoft.emz"
        case "wmz": return "com.microsoft.wmz"
        default: return "public.data"
        }
    }

    /// Builds the attribute set: the file name as title/display name, a
    /// "format · size" subtitle as the content description, and the capped text
    /// summary as full-text content (omitted when there is none). The " · size" is
    /// dropped when no size is known (the association path).
    static func attributeSet(
        name: String,
        contentTypeIdentifier: String,
        formatLabel: String,
        sizeLabel: String,
        textSummary: String?
    ) -> CSSearchableItemAttributeSet {
        let type = UTType(contentTypeIdentifier) ?? .data
        let set = CSSearchableItemAttributeSet(contentType: type)
        set.title = name
        set.displayName = name
        set.contentDescription = sizeLabel.isEmpty ? formatLabel : "\(formatLabel) · \(sizeLabel)"
        if let textSummary, !textSummary.isEmpty {
            set.textContent = DrawingSpotlightBuilder.cap(textSummary, to: maxSummaryCharacters)
        }
        return set
    }
}

/// Reconstructs a `DrawingEntity` from an already-built F3 Spotlight item so
/// `CoreSpotlightIndex` can associate it with the item it is indexing. Pure and
/// ungated. Returns nil when the item's id isn't a UUID (a malformed id is skipped,
/// never crashed). The entity carries the capped text summary from the item; its
/// size is left blank because the item doesn't carry it — the authoritative entity
/// (with size) is re-resolved live by `DrawingEntityQuery` when the system needs it,
/// and a Spotlight result's display comes from the indexed item, not this handle.
enum DrawingEntityIndexing {
    static func entity(forSpotlight item: DrawingSpotlightItem) -> DrawingEntity? {
        guard let id = UUID(uuidString: item.id) else { return nil }
        let summary = item.textContent.isEmpty
            ? nil
            : DrawingSpotlightBuilder.cap(item.textContent, to: DrawingEntityAttributes.maxSummaryCharacters)
        return DrawingEntity(
            id: id,
            name: item.title,
            formatLabel: MetafileFormatLabel.names(for: item.title).short,
            sizeLabel: "",
            thumbnailPath: nil,
            textSummary: summary
        )
    }
}

// MARK: - IndexedEntity conformance (macOS 15 / iOS 18+)

@available(macOS 15, iOS 18, *)
extension DrawingEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        DrawingEntityAttributes.attributeSet(
            name: name,
            contentTypeIdentifier: DrawingEntityAttributes.contentTypeIdentifier(forFileNamed: name),
            formatLabel: formatLabel,
            sizeLabel: sizeLabel,
            textSummary: textSummary
        )
    }
}
