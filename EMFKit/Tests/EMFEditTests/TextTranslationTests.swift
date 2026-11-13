import Foundation
import Testing
@testable import EMFEdit

// X2c: the translate-in-place batch mapping — strict decode of the model's translation
// reply and the per-batch reconciliation that rejects unknown/duplicate/missing ids.
// Pure — no model, no window.

@Suite struct TextTranslationTests {

    // MARK: Decode

    @Test func decodesStrictTranslations() throws {
        let json = #"{"translations":[{"id":2,"text":"Bonjour"},{"id":5,"text":"Monde"}]}"#
        let entries = try TextTranslation.decode(fromJSON: json)
        #expect(entries == [TranslationEntry(id: 2, text: "Bonjour"), TranslationEntry(id: 5, text: "Monde")])
    }

    @Test func decodesThroughProseAndFence() throws {
        let json = """
        Here is the JSON you asked for:
        ```json
        {"translations":[{"id":1,"text":"Hallo"}]}
        ```
        """
        let entries = try TextTranslation.decode(fromJSON: json)
        #expect(entries == [TranslationEntry(id: 1, text: "Hallo")])
    }

    @Test func repairsADroppedOpeningQuoteOnAKnownKey() throws {
        // A small model drops the opening quote on `text`: `,text":` → repaired to `,"text":`.
        let json = #"{"translations":[{"id":3,text":"Hola"}]}"#
        let entries = try TextTranslation.decode(fromJSON: json)
        #expect(entries == [TranslationEntry(id: 3, text: "Hola")])
    }

    @Test func nonJSONThrowsNotDecodable() {
        #expect(throws: TranslationBatchProblem.self) {
            _ = try TextTranslation.decode(fromJSON: "I'm sorry, I can't translate that.")
        }
    }

    // MARK: Reconcile

    @Test func reconcilesAllRequestedIDs() throws {
        let entries = [TranslationEntry(id: 2, text: "Bonjour"), TranslationEntry(id: 5, text: "Monde")]
        let result = TextTranslation.reconcile(entries, requested: [2, 5])
        let map = try result.get()
        #expect(map == [2: "Bonjour", 5: "Monde"])
    }

    @Test func rejectsAnUnknownID() {
        let entries = [TranslationEntry(id: 2, text: "Bonjour"), TranslationEntry(id: 99, text: "???")]
        let result = TextTranslation.reconcile(entries, requested: [2, 5])
        #expect(result == .failure(.unknownID(99)))
    }

    @Test func rejectsADuplicateID() {
        let entries = [TranslationEntry(id: 2, text: "Bonjour"), TranslationEntry(id: 2, text: "Salut")]
        let result = TextTranslation.reconcile(entries, requested: [2, 5])
        #expect(result == .failure(.duplicateID(2)))
    }

    @Test func rejectsAMissingID() {
        let entries = [TranslationEntry(id: 2, text: "Bonjour")]
        let result = TextTranslation.reconcile(entries, requested: [2, 5])
        #expect(result == .failure(.missingID(5)))
    }

    @Test func rejectsTextOverTheCap() {
        let long = String(repeating: "a", count: TextTranslation.maxTextLength + 1)
        let entries = [TranslationEntry(id: 2, text: long)]
        let result = TextTranslation.reconcile(entries, requested: [2])
        #expect(result == .failure(.textTooLong(id: 2, length: long.count, limit: TextTranslation.maxTextLength)))
    }
}
