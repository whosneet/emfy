import Foundation
import Testing

// A2b: the consent-screen content builder and the data-category gate. The sheet's
// "what's sent" list and the recorded grant must come from the same source so they
// can never drift.

@Suite struct AIConsentContentTests {

    private func config(_ host: String = "api.anthropic.com", name: String = "Claude") -> AIProviderConfig {
        AIProviderConfig(kind: .anthropic, displayName: name, baseURL: URL(string: "https://\(host)")!, model: "claude-opus-5-5")
    }

    @Test func drawingDataSheetListsExactCategories() {
        let content = AIConsentSheetContent.make(provider: config(), purpose: .drawingData)
        #expect(content.providerName == "Claude")
        #expect(content.host == "api.anthropic.com")
        #expect(content.sent == [
            AIDataCategory.drawingText.rawValue,
            AIDataCategory.formatAndPage.rawValue,
            AIDataCategory.recordCounts.rawValue,
            AIDataCategory.question.rawValue,
        ])
        // Never-sent list names the file, pictures, other files and the key.
        let never = content.neverSent.joined(separator: " | ").lowercased()
        #expect(never.contains("file itself"))
        #expect(never.contains("pictures"))
        #expect(never.contains("other files"))
        #expect(never.contains("api key"))
    }

    @Test func titlesSheetAddsItsOwnCategory() {
        let content = AIConsentSheetContent.make(provider: config(), purpose: .titles)
        #expect(content.sent.contains(AIDataCategory.titles.rawValue))
        #expect(content.sent.contains(AIDataCategory.drawingText.rawValue))
        // The drawing-data purpose does NOT carry the titling category.
        let drawing = AIConsentSheetContent.make(provider: config(), purpose: .drawingData)
        #expect(!drawing.sent.contains(AIDataCategory.titles.rawValue))
    }

    @Test func grantRecordsThePurposeCategories() {
        let defaults = UserDefaults(suiteName: "consent-" + UUID().uuidString)!
        let store = AIConsentStore(defaults: defaults)
        store.grant("p1", purpose: .drawingData)
        #expect(store.isGranted("p1"))
        #expect(store.hasCategory("p1", .drawingText))
        // Drawing-data consent does NOT grant the titling category.
        #expect(!store.hasCategory("p1", .titles))
        store.grant("p1", purpose: .titles)
        #expect(store.hasCategory("p1", .titles))
    }

    @Test func policyNoteNamesProvider() {
        let content = AIConsentSheetContent.make(provider: config(name: "My Ollama"), purpose: .drawingData)
        #expect(content.policyNote.contains("My Ollama"))
    }
}
