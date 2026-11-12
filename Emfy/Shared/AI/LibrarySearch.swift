import Foundation
import NaturalLanguage

// MARK: - Smart library search (A1b Part 2)
//
// When on-device AI is on, the library search field matches not just the file name
// but the AI title, the AI tags, the extracted drawing text (already indexed for
// Spotlight) and OCR picture text, and surfaces semantically-related drawings via
// on-device NaturalLanguage sentence embeddings. NO network, and NO model call per
// keystroke — `NLEmbedding` is a static lookup, and the UI debounces. With AI off the
// search falls back to plain file-name matching, exactly as before.
//
// The ranker is pure (seams for the text lookup and the semantic scorer), so the tiers
// and ordering are unit-tested without a store, an index or a live embedding.

/// A semantic-similarity seam: 0…1 (1 = identical meaning), or `nil` when embeddings
/// aren't available. A protocol so tests use a stub and the app uses `NLEmbedding`.
/// Used synchronously from the main-actor search, so it isn't `Sendable` (`NLEmbedding`
/// itself isn't).
protocol SemanticScorer {
    func similarity(_ a: String, _ b: String) -> Double?
}

/// On-device sentence-embedding similarity (`NLEmbedding.sentenceEmbedding`). Built
/// once (not per keystroke); `similarity` is a cheap cosine lookup. Falls back to
/// `nil` when the OS has no sentence embedding for the language.
struct NLSemanticScorer: SemanticScorer {
    private let embedding: NLEmbedding?

    init(language: NLLanguage = .english) {
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    /// Whether an embedding is available (else the ranker uses literal matching only).
    var isAvailable: Bool { embedding != nil }

    func similarity(_ a: String, _ b: String) -> Double? {
        guard let embedding else { return nil }
        let distance = embedding.distance(between: a, and: b, distanceType: .cosine)
        guard distance.isFinite else { return nil }
        // NLEmbedding cosine distance is 0 (identical) … 2 (opposite) → similarity 0…1.
        return max(0, 1 - distance / 2)
    }
}

/// The app's single sentence-embedding scorer, built once on first use (the embedding
/// load is not cheap, and must not repeat per keystroke). Main-actor, since the search
/// that uses it is main-actor and `NLEmbedding` isn't `Sendable`.
@MainActor
enum LibrarySearchScorer {
    static let shared = NLSemanticScorer()
}

/// The pure ranker. Scores each entry, drops non-matches, and returns the entries in
/// descending score order (stable for ties, so the newest-first input order is kept).
enum LibrarySearchRanker {
    // Score tiers (brief: exact name/title first, then tags, then text).
    static let nameExact = 1000.0
    static let titleExact = 900.0
    static let namePrefix = 820.0
    static let nameContains = 760.0
    static let titleContains = 640.0
    static let tagExact = 560.0
    static let tagContains = 500.0
    static let textContains = 360.0

    /// A semantic-only match is scaled by this weight (so it sits below a literal tag
    /// match but still surfaces), and must clear `semanticThreshold` to appear at all.
    static let semanticWeight = 240.0
    static let semanticThreshold = 0.60

    /// Ranks `entries` for `query`. With `aiEnabled == false` only the file name is
    /// matched (legacy behaviour). `textFor` supplies an entry's extracted + OCR text
    /// when cached (else `nil`); `scorer` adds semantic matching when available.
    static func rank(
        entries: [RecentEntry],
        query: String,
        aiEnabled: Bool,
        textFor: (UUID) -> String? = { _ in nil },
        scorer: SemanticScorer? = nil
    ) -> [RecentEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.lowercased()

        var scored: [(entry: RecentEntry, score: Double, order: Int)] = []
        for (index, entry) in entries.enumerated() {
            var score = fieldScore(entry: entry, needle: needle, aiEnabled: aiEnabled, textFor: textFor)
            if aiEnabled, let scorer {
                let haystack = ([entry.aiTitle ?? ""] + (entry.aiTags ?? [])).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !haystack.isEmpty, let similarity = scorer.similarity(trimmed, haystack),
                   similarity >= semanticThreshold {
                    score = max(score, semanticWeight * similarity)
                }
            }
            if score > 0 { scored.append((entry, score, index)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map(\.entry)
    }

    /// The best literal field score for one entry (0 when nothing matches).
    static func fieldScore(
        entry: RecentEntry,
        needle: String,
        aiEnabled: Bool,
        textFor: (UUID) -> String?
    ) -> Double {
        let name = entry.displayName.lowercased()
        let base = entry.baseName.lowercased()
        if name == needle || base == needle { return nameExact }

        var best = 0.0
        if name.hasPrefix(needle) || base.hasPrefix(needle) { best = max(best, namePrefix) }
        if name.contains(needle) { best = max(best, nameContains) }

        // The enriched fields (title, tags, text) only matter while AI display is on.
        guard aiEnabled else { return best }

        if let aiTitle = entry.aiTitle, !aiTitle.isEmpty {
            let title = aiTitle.lowercased()
            if title == needle { return titleExact }
            if title.contains(needle) { best = max(best, titleContains) }
        }
        for tag in entry.aiTags ?? [] {
            let tag = tag.lowercased()
            if tag == needle { best = max(best, tagExact) }
            else if tag.contains(needle) { best = max(best, tagContains) }
        }
        if let text = textFor(entry.id)?.lowercased(), !text.isEmpty, text.contains(needle) {
            best = max(best, textContains)
        }
        return best
    }
}

// MARK: - In-memory searchable-text index

/// A small, bounded main-actor cache of each entry's extracted + OCR text, filled as a
/// by-product of Spotlight item building (F3) so smart search can match drawing/OCR
/// text without re-parsing. Best-effort: a miss simply means text matching is skipped
/// for that entry until it is next indexed.
@MainActor
final class LibrarySearchIndex {
    static let shared = LibrarySearchIndex()

    private var text: [UUID: String] = [:]
    private var order: [UUID] = []
    /// Cap the cache so a large library can't grow it without bound.
    static let maxEntries = 200
    /// Cap each entry's cached text (full-text is for Spotlight; search needs far less).
    static let maxTextCharacters = 20_000

    private init() {}

    func set(_ id: UUID, text newText: String) {
        let capped = String(newText.prefix(Self.maxTextCharacters))
        if text[id] == nil { order.append(id) }
        text[id] = capped
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            text.removeValue(forKey: oldest)
        }
    }

    func text(for id: UUID) -> String? { text[id] }

    func removeAll() {
        text.removeAll()
        order.removeAll()
    }
}
