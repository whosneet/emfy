import Foundation
import Testing

// A1b Part 1: the title/tag sanitiser and caps. The model output is untrusted, so
// titles and tags are stripped of control characters and hard-capped before they are
// stored, shown or indexed.

@Suite struct DrawingAITitleTagsTests {

    @Test func titleIsCappedToSixWords() {
        let out = DrawingTitleTagsSanitizer.sanitizeTitle("One Two Three Four Five Six Seven Eight")
        #expect(out == "One Two Three Four Five Six")
    }

    @Test func titleIsCappedToSixtyCharacters() {
        // Six long words whose joined length exceeds 60 characters.
        let word = String(repeating: "a", count: 20)
        let raw = Array(repeating: word, count: 6).joined(separator: " ")
        let out = DrawingTitleTagsSanitizer.sanitizeTitle(raw)
        #expect(out.count <= DrawingTitleTagsSanitizer.maxTitleCharacters)
    }

    @Test func titleStripsControlCharactersAndCollapsesWhitespace() {
        let out = DrawingTitleTagsSanitizer.sanitizeTitle("Floor\u{0000}  plan\u{200B}\tsketch")
        #expect(out == "Floor plan sketch")
    }

    @Test func titleStripsWrappingQuotes() {
        #expect(DrawingTitleTagsSanitizer.sanitizeTitle("“House Sketch”") == "House Sketch")
        #expect(DrawingTitleTagsSanitizer.sanitizeTitle("\"Invoice\"") == "Invoice")
    }

    @Test func tagsAreLowercasedTrimmedAndDeduplicated() {
        // "diagram" is a meaningless tag (A1c Part 1), so it is dropped; the rest are
        // lowercased, trimmed and de-duplicated.
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["Invoice", "#flowchart", "invoice", "  Logo  "])
        #expect(out == ["invoice", "flowchart", "logo"])
    }

    @Test func tagsAreCappedToFive() {
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["a", "b", "c", "d", "e", "f", "g"])
        #expect(out.count == DrawingTitleTagsSanitizer.maxTags)
        #expect(out == ["a", "b", "c", "d", "e"])
    }

    @Test func eachTagIsCappedToTwentyFourCharacters() {
        let long = String(repeating: "x", count: 40)
        let out = DrawingTitleTagsSanitizer.sanitizeTags([long])
        #expect(out.count == 1)
        #expect(out[0].count <= DrawingTitleTagsSanitizer.maxTagCharacters)
    }

    @Test func tagsStripControlCharacters() {
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["in\u{0007}voice", "map\u{200B}"])
        #expect(out == ["invoice", "map"])
    }

    @Test func emptyAndBlankTagsAreDropped() {
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["", "   ", "#", "valid"])
        #expect(out == ["valid"])
    }

    @Test func sanitizeProducesBoundedResult() {
        let result = DrawingTitleTagsSanitizer.sanitize(
            title: "A Very Long Title That Goes On And On And On Forever Indeed",
            tags: ["One", "TWO", "three", "four", "five", "six"]
        )
        #expect(result.title.split(separator: " ").count <= DrawingTitleTagsSanitizer.maxTitleWords)
        #expect(result.tags.count <= DrawingTitleTagsSanitizer.maxTags)
        #expect(result.tags.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: - A1c Part 1: generic-title rejection

    @Test(arguments: [
        "Vector Drawing", "Vector Drawing Data", "Metafile Image",
        "Untitled Graphic", "DIAGRAM", "image file", "",
    ])
    func genericOnlyTitlesAreRejected(_ title: String) {
        #expect(DrawingTitleTagsSanitizer.isGenericTitle(title))
    }

    @Test(arguments: [
        "Floor Plan Sketch", "Invoice Summary", "Red Sports Car",
        "Quarterly Sales Diagram", "Network Topology",
    ])
    func contentfulTitlesAreKept(_ title: String) {
        #expect(!DrawingTitleTagsSanitizer.isGenericTitle(title))
    }

    @Test func sanitizeEmptiesAGenericTitle() {
        let result = DrawingTitleTagsSanitizer.sanitize(title: "Vector Drawing Data", tags: ["flowchart"])
        #expect(result.title.isEmpty)
    }

    @Test func sanitizeKeepsAContentfulTitle() {
        let result = DrawingTitleTagsSanitizer.sanitize(title: "Office Floor Plan", tags: ["plan"])
        #expect(result.title == "Office Floor Plan")
    }

    // MARK: - A1c Part 1: meaningless-tag filtering

    @Test func meaninglessTagsAreDropped() {
        let out = DrawingTitleTagsSanitizer.sanitizeTags([
            "invoice", "metadata", "embodies", "vector", "drawing",
            "metafile", "image", "data", "file", "diagram", "flowchart",
        ])
        #expect(out == ["invoice", "flowchart"])
    }

    @Test func allMeaninglessTagsProduceNoTags() {
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["metadata", "embodies", "vector", "image"])
        #expect(out.isEmpty)
    }
}
