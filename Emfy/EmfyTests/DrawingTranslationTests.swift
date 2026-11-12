import Foundation
import Testing

// F3d unit tests for the pure Translate text selection (`DrawingTranslation`): the current
// Find match wins over all text, the fallback to all text, and word-boundary truncation.

@Suite struct DrawingTranslationTests {

    @Test func currentFindMatchWinsOverAllText() {
        let text = DrawingTranslation.text(currentMatch: "Invoice total", allText: "The whole document body")
        #expect(text == "Invoice total")
    }

    @Test func fallsBackToAllTextWhenNoMatch() {
        #expect(DrawingTranslation.text(currentMatch: nil, allText: "All drawing text") == "All drawing text")
    }

    @Test func fallsBackToAllTextWhenMatchIsBlank() {
        #expect(DrawingTranslation.text(currentMatch: "   \n ", allText: "All drawing text") == "All drawing text")
    }

    @Test func shortTextIsUntouched() {
        #expect(DrawingTranslation.truncate("Hello world", to: 4000) == "Hello world")
    }

    @Test func truncatesAtAWordBoundary() {
        // 1000 words of "word " = 5000 chars; a 4000-char cap must not split the final word.
        let long = Array(repeating: "word", count: 1000).joined(separator: " ")
        let truncated = DrawingTranslation.truncate(long, to: DrawingTranslation.maxCharacters)
        #expect(truncated.count <= DrawingTranslation.maxCharacters)
        #expect(!truncated.hasSuffix("wor"))      // never a split word
        #expect(truncated.hasSuffix("word"))
        #expect(!truncated.hasSuffix(" "))         // trailing whitespace trimmed
    }

    @Test func hardCutsWhenNoWhitespaceToBreakOn() {
        let solid = String(repeating: "a", count: 5000)
        let truncated = DrawingTranslation.truncate(solid, to: 4000)
        #expect(truncated.count == 4000)
    }
}
