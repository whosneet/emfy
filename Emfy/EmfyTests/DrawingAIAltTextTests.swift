import Foundation
import Testing

// A1a: the VoiceOver alt-text cache key and fallback label. Pure logic plus the
// main-actor store's cache behaviour — no live model needed.

@Suite struct DrawingAIAltTextTests {

    @Test func fallbackLabelUsesTheFileName() {
        #expect(DrawingAltText.fallbackLabel(fileName: "invoice.emf") == "Drawing, invoice.emf")
        #expect(DrawingAltText.fallbackLabel(fileName: "  ") == "Drawing")
        #expect(DrawingAltText.fallbackLabel(fileName: "") == "Drawing")
    }

    // F5: untrusted model alt text is sanitised and capped before it becomes a label.
    @Test func cleanStripsScaffoldingAndCapsLength() {
        // Echoed grounding scaffolding is removed.
        let leaked = "<drawing-content>secret data</drawing-content>A plain page of text."
        #expect(DrawingAltText.clean(leaked) == "A plain page of text.")

        // A runaway reply is capped to ~200 characters with an ellipsis, on a word break.
        let long = String(repeating: "word ", count: 100)   // 500 chars
        let cleaned = DrawingAltText.clean(long)
        #expect(cleaned.count <= DrawingAltText.maxLength + 1)   // +1 for the ellipsis
        #expect(cleaned.hasSuffix("…"))
        #expect(!cleaned.contains("  "))   // no dangling partial word/space

        // A short, clean sentence is returned unchanged.
        #expect(DrawingAltText.clean("A blue circle.") == "A blue circle.")
    }

    @MainActor
    @Test func storeCachesByContentIdAndFallsBack() {
        let store = DrawingAltTextStore()
        #expect(store.cached(for: 1) == nil)
        // Before generation, the label is the fallback.
        #expect(store.label(for: 1, fileName: "a.emf") == "Drawing, a.emf")

        store.store("A blue circle on a white page.", for: 1)
        #expect(store.cached(for: 1) == "A blue circle on a white page.")
        #expect(store.label(for: 1, fileName: "a.emf") == "A blue circle on a white page.")
        // A different drawing still falls back.
        #expect(store.label(for: 2, fileName: "b.emf") == "Drawing, b.emf")
    }

    @MainActor
    @Test func storeIgnoresBlankAltTextAndTrims() {
        let store = DrawingAltTextStore()
        store.store("   \n ", for: 7)
        #expect(store.cached(for: 7) == nil)
        store.store("  Trimmed sentence.  ", for: 7)
        #expect(store.cached(for: 7) == "Trimmed sentence.")
    }

    @MainActor
    @Test func storeEvictsOldestPastTheCap() {
        let store = DrawingAltTextStore()
        for i in 0 ... DrawingAltTextStore.maxEntries {
            store.store("alt \(i)", for: i)
        }
        // The very first entry was evicted; the latest is kept.
        #expect(store.cached(for: 0) == nil)
        #expect(store.cached(for: DrawingAltTextStore.maxEntries) == "alt \(DrawingAltTextStore.maxEntries)")
    }
}
