import Foundation
import Testing

// A1b Part 2: the smart-search ranking order and the token-match fallback.

@Suite struct LibrarySearchRankerTests {

    private func entry(_ name: String, title: String? = nil, tags: [String] = []) -> RecentEntry {
        RecentEntry(
            id: UUID(), displayName: name, formatLabel: "EMF", fullFormatName: "Enhanced Metafile",
            byteCount: 1, openedAt: Date(), bookmark: Data(),
            aiTitle: title, aiTags: tags.isEmpty ? nil : tags)
    }

    /// A stub that returns a fixed similarity for a chosen "meaning" word.
    private struct StubScorer: SemanticScorer {
        let meaningWord: String
        let score: Double
        func similarity(_ a: String, _ b: String) -> Double? {
            b.lowercased().contains(meaningWord) ? score : 0.0
        }
    }

    @Test func exactNameRanksAboveTagThenText() {
        let exact = entry("invoice.emf")
        let tagged = entry("march.emf", tags: ["invoice"])
        let texty = entry("notes.emf")
        let result = LibrarySearchRanker.rank(
            entries: [texty, tagged, exact], query: "invoice", aiEnabled: true,
            textFor: { $0 == texty.id ? "the invoice total is due" : nil })
        #expect(result.map(\.displayName) == ["invoice.emf", "march.emf", "notes.emf"])
    }

    @Test func tagMatchSurfacesEntryWhoseNameDoesNotMatch() {
        let a = entry("diagram-1.emf", tags: ["flowchart"])
        let b = entry("photo.emf")
        let result = LibrarySearchRanker.rank(entries: [a, b], query: "flowchart", aiEnabled: true)
        #expect(result.map(\.displayName) == ["diagram-1.emf"])
    }

    @Test func titleMatchRanksHighWhenAIEnabled() {
        let a = entry("p2.emf", title: "Office Floor Plan", tags: ["layout"])
        let result = LibrarySearchRanker.rank(entries: [a], query: "floor plan", aiEnabled: true)
        #expect(result.count == 1)
    }

    @Test func aiOffMatchesOnlyFileName() {
        let a = entry("p2.emf", title: "Office Floor Plan", tags: ["layout"])
        // "layout" is a tag and part of the title, but with AI off only the name matches.
        #expect(LibrarySearchRanker.rank(entries: [a], query: "layout", aiEnabled: false).isEmpty)
        #expect(LibrarySearchRanker.rank(entries: [a], query: "p2", aiEnabled: false).count == 1)
    }

    @Test func emptyQueryReturnsAllUnchanged() {
        let a = entry("a.emf"); let b = entry("b.emf")
        #expect(LibrarySearchRanker.rank(entries: [a, b], query: "   ", aiEnabled: true).map(\.displayName) == ["a.emf", "b.emf"])
    }

    @Test func semanticMatchSurfacesByMeaningNotName() {
        // Query "car" is not in any name/title/tag, but the scorer treats "vehicle" as
        // semantically close, so the vehicle drawing surfaces and the unrelated one doesn't.
        let vehicle = entry("drawing-9.emf", title: "Vehicle Sketch", tags: ["vehicle"])
        let tree = entry("drawing-3.emf", title: "Oak Tree", tags: ["tree"])
        let scorer = StubScorer(meaningWord: "vehicle", score: 0.8)
        let result = LibrarySearchRanker.rank(
            entries: [tree, vehicle], query: "car", aiEnabled: true, scorer: scorer)
        #expect(result.map(\.displayName) == ["drawing-9.emf"])
    }

    @Test func semanticBelowThresholdDoesNotSurface() {
        let a = entry("drawing-9.emf", title: "Vehicle Sketch", tags: ["vehicle"])
        let scorer = StubScorer(meaningWord: "vehicle", score: 0.3)   // below 0.60
        #expect(LibrarySearchRanker.rank(entries: [a], query: "car", aiEnabled: true, scorer: scorer).isEmpty)
    }

    @Test func literalNameBeatsSemanticOnly() {
        let named = entry("car-park.emf")
        let semantic = entry("drawing-9.emf", title: "Vehicle Sketch", tags: ["vehicle"])
        let scorer = StubScorer(meaningWord: "vehicle", score: 0.9)
        let result = LibrarySearchRanker.rank(
            entries: [semantic, named], query: "car", aiEnabled: true, scorer: scorer)
        #expect(result.first?.displayName == "car-park.emf")
    }
}
