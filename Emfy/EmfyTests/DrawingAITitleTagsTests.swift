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
        let out = DrawingTitleTagsSanitizer.sanitizeTags(["Diagram", "#flowchart", "diagram", "  Logo  "])
        #expect(out == ["diagram", "flowchart", "logo"])
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
}
