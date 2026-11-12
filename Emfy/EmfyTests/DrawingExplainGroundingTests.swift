import Foundation
import Testing

// A1b Part 3: the explain-what's-missing grounding — the prompt contains ONLY the
// diagnostics data (fenced) and forbids speculation; no drawing content leaks in.

@Suite struct DrawingExplainGroundingTests {

    private func note(_ summary: String, _ detail: String) -> DiagnosticNote {
        DiagnosticNote(summary: summary, technicalDetail: detail)
    }

    @Test func missingItemsPairSummaryWithRecordNameAndDeduplicate() {
        let notes = [
            note("3 drawing instructions were skipped.", "Skipped unsupported record type 70 (3 occurrences)."),
            note("3 drawing instructions were skipped.", "Skipped unsupported record type 70 (3 occurrences)."),
            note("An embedded image was skipped.", "Skipped unsupported embedded bitmap: JPEG (1 occurrence)."),
        ]
        let items = DrawingMissingItems.list(from: notes)
        #expect(items.count == 2)
        #expect(items[0].contains("record type 70"))
        #expect(items[1].contains("JPEG"))
    }

    @Test func missingItemsAreCappedInCountAndLength() {
        let many = (0..<30).map { note("skipped \($0)", String(repeating: "x", count: 500)) }
        let items = DrawingMissingItems.list(from: many)
        #expect(items.count <= DrawingMissingItems.maxItems)
        #expect(items.allSatisfy { $0.count <= DrawingMissingItems.maxItemCharacters })
    }

    @Test func promptContainsOnlyTheFencedDiagnosticsAndForbidsSpeculation() {
        let items = ["An embedded image was skipped. [Skipped unsupported embedded bitmap: JPEG]"]
        let prompt = DrawingAIPrompt.explainMissingPrompt(items: items)
        // The item is present, fenced.
        #expect(prompt.contains(DrawingAIPrompt.openMarker))
        #expect(prompt.contains(DrawingAIPrompt.closeMarker))
        #expect(prompt.contains("JPEG"))
        // The item sits inside the data markers.
        let open = prompt.range(of: DrawingAIPrompt.openMarker)!
        let close = prompt.range(of: DrawingAIPrompt.closeMarker)!
        let jpeg = prompt.range(of: "JPEG")!
        #expect(jpeg.lowerBound > open.upperBound && jpeg.upperBound < close.lowerBound)
        // The instruction forbids guessing at the drawing's content.
        #expect(prompt.lowercased().contains("do not guess"))
    }

    @Test func promptCarriesNoContentBeyondTheItems() {
        // A sanitised, bounded item list — nothing from the drawing's own text should
        // appear. The prompt is the instruction plus exactly the fenced items.
        let items = ["only this item"]
        let prompt = DrawingAIPrompt.explainMissingPrompt(items: items)
        #expect(prompt.contains("only this item"))
        #expect(!prompt.contains("<drawing-content>only")) // items are newline-listed, fenced cleanly
    }
}
