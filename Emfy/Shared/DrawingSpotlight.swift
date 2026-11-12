import Foundation

// MARK: - Spotlight indexing of recents (F3)
//
// The pure, testable core of Spotlight support: the value that describes a
// searchable drawing, the protocol seam the app's Core Spotlight implementation
// conforms to, a builder that caps and composes the indexed text (§8), and a
// coordinator that turns recents lifecycle events into index/de-index calls.
//
// CoreSpotlight itself lives only in the concrete `DrawingSpotlightIndex`
// implementation in the app, so this core — and its tests — need no entitlement
// and no live index.

/// One drawing to index. The unique id is the recents entry id, so opening a
/// Spotlight result (`CSSearchableItemActionType`) maps straight back to the
/// entry. The thumbnail is supplied by the concrete implementation from the
/// recents thumbnail, not carried here.
struct DrawingSpotlightItem: Equatable, Sendable {
    var id: String
    var title: String
    var contentDescription: String
    /// The drawing's extracted text plus OCR picture text, in reading order,
    /// capped at `maxTextCharacters`.
    var textContent: String
    /// The content UTI (e.g. "com.microsoft.emf").
    var contentTypeIdentifier: String
}

/// The index seam. The app's Core Spotlight implementation conforms to this; the
/// coordinator and its tests talk only to the protocol. Calls are async and
/// batched by the implementation at low priority.
protocol DrawingSpotlightIndex: Sendable {
    func index(_ items: [DrawingSpotlightItem]) async
    func removeItems(ids: [String]) async
    func removeAll() async
}

enum DrawingSpotlightBuilder {

    /// Indexed-text cap: 100k characters of extracted + OCR text per drawing.
    static let maxTextCharacters = 100_000

    /// Builds the searchable item for a recents entry. `drawingText` and
    /// `pictureText` are the extractor's runs; they are concatenated in reading
    /// order (drawing first, then OCR) and capped. The description is a short,
    /// human line for the Spotlight result subtitle.
    static func item(
        id: String,
        fileName: String,
        contentTypeIdentifier: String,
        drawingText: [DrawingTextRun],
        pictureText: [DrawingTextRun]
    ) -> DrawingSpotlightItem {
        let all = DrawingTextExtractor.copyAllText(drawingText + pictureText)
        let capped = cap(all, to: maxTextCharacters)
        let description = Self.description(fileName: fileName, drawingRuns: drawingText.count, pictureRuns: pictureText.count)
        return DrawingSpotlightItem(
            id: id,
            title: fileName,
            contentDescription: description,
            textContent: capped,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    /// Truncates to a UTF-16 code-unit budget without splitting a surrogate pair.
    static func cap(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if count + width > limit { break }
            scalars.append(scalar)
            count += width
        }
        return String(scalars)
    }

    private static func description(fileName: String, drawingRuns: Int, pictureRuns: Int) -> String {
        var parts: [String] = []
        if drawingRuns > 0 { parts.append("\(drawingRuns) text \(drawingRuns == 1 ? "run" : "runs")") }
        if pictureRuns > 0 { parts.append("\(pictureRuns) in pictures") }
        return parts.isEmpty ? "Metafile drawing" : "Metafile drawing — " + parts.joined(separator: ", ")
    }
}

/// Decides whether indexing is active, from the Settings toggle and Private mode.
enum DrawingSpotlightPolicy {
    /// New drawings are indexed only when the toggle is on and Private mode is off.
    static func shouldIndex(enabled: Bool, privateMode: Bool) -> Bool {
        enabled && !privateMode
    }

    /// The whole index must be wiped when the toggle is off or Private mode is on.
    static func shouldWipeAll(enabled: Bool, privateMode: Bool) -> Bool {
        !enabled || privateMode
    }
}

/// Turns recents lifecycle events into index/de-index calls on the seam. The app
/// holds one of these and calls it from `RecentsStore`; tests drive it with a
/// recording fake.
final class DrawingSpotlightCoordinator: Sendable {
    private let index: any DrawingSpotlightIndex

    init(index: any DrawingSpotlightIndex) {
        self.index = index
    }

    /// Index or refresh a batch of entries (respecting the settings gate).
    func reindex(_ items: [DrawingSpotlightItem], enabled: Bool, privateMode: Bool) async {
        guard DrawingSpotlightPolicy.shouldIndex(enabled: enabled, privateMode: privateMode) else { return }
        guard !items.isEmpty else { return }
        await index.index(items)
    }

    /// An entry was removed or pruned from recents.
    func entriesRemoved(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await index.removeItems(ids: ids)
    }

    /// Clear Recents ran — wipe the whole index.
    func recentsCleared() async {
        await index.removeAll()
    }

    /// Private mode turned on, or the Spotlight toggle turned off — wipe.
    func indexingDisabledOrPrivate() async {
        await index.removeAll()
    }
}
