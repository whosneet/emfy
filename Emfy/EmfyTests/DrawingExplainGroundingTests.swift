import EMFRender
import Foundation
import Testing

// A1b Part 3: the explain-what's-missing grounding — the prompt contains ONLY the
// diagnostics data (fenced) and forbids speculation; no drawing content leaks in.
// A1c Part 2: each skipped record is named with a spec-derived purpose.

@Suite struct DrawingExplainGroundingTests {

    private func note(_ summary: String, _ detail: String) -> DiagnosticNote {
        DiagnosticNote(summary: summary, technicalDetail: detail)
    }

    private func diagnostics(renderLog: [EMFRenderLog.Entry]) -> ViewerDiagnostics {
        ViewerDiagnostics(
            kind: .emf, embeddedEMF: .absent, renderLog: renderLog,
            parserDiagnostics: [], frontDoorDiagnostics: [], wasDecompressed: false)
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

    // MARK: - A1c Part 2: named records with spec-derived purposes

    @Test func recordPurposeResolvesEMFNameAndPurpose() {
        let gradient = DrawingRecordPurpose.emf(type: 118)   // EMR_GRADIENTFILL
        #expect(gradient?.name == "EMR_GRADIENTFILL")
        #expect(gradient?.purpose.lowercased().contains("gradient") == true)
        // An undefined type id has no name.
        #expect(DrawingRecordPurpose.emf(type: 9999) == nil)
    }

    @Test func recordPurposeResolvesEMFPlusNameAndPurpose() {
        let fillPath = DrawingRecordPurpose.emfPlus(type: 0x4014)   // EmfPlusFillPath
        #expect(fillPath.name == "EmfPlusFillPath")
        #expect(fillPath.purpose.lowercased().contains("fill") == true)
        // An unknown EMF+ type still names itself by hex, with the generic purpose.
        let unknown = DrawingRecordPurpose.emfPlus(type: 0x40FF)
        #expect(unknown.name == "0x40FF")
        #expect(unknown.purpose == DrawingRecordPurpose.genericEMFPlusPurpose)
    }

    @Test func diagnosticsListNamesEachSkippedRecord() {
        let diag = diagnostics(renderLog: [
            .unimplementedRecord(type: 118, count: 3),   // EMR_GRADIENTFILL
            .emfPlusUnsupportedRecord(type: 0x4014, count: 1),  // EmfPlusFillPath
        ])
        let items = DrawingMissingItems.list(from: diag)
        let joined = items.joined(separator: "\n")
        #expect(joined.contains("EMR_GRADIENTFILL"))
        #expect(joined.lowercased().contains("gradient"))
        #expect(joined.contains("skipped 3 times"))
        #expect(joined.contains("EmfPlusFillPath"))
    }

    @Test func unknownEMFRecordIsReportedByNumber() {
        let diag = diagnostics(renderLog: [.unimplementedRecord(type: 9999, count: 1)])
        let items = DrawingMissingItems.list(from: diag)
        #expect(items.contains { $0.contains("9999") })
    }

    @Test func structuralOnlySkipsGiveNoItems() {
        // Every metafile logs HEADER (1), EOF (14) and often COMMENT (70) as
        // "unimplemented" even though they draw nothing, so a file whose only skipped
        // records are structural must yield an EMPTY list (and therefore no Explain
        // button) — A1c.
        let diag = diagnostics(renderLog: [
            .unimplementedRecord(type: 1, count: 1),    // EMR_HEADER
            .unimplementedRecord(type: 14, count: 1),   // EMR_EOF
            .unimplementedRecord(type: 70, count: 3),   // EMR_COMMENT
        ])
        #expect(DrawingMissingItems.list(from: diag).isEmpty)
    }

    @Test func aVisualSkipAmongStructuralOnesStillLists() {
        // A real drawing-record skip survives even when structural skips are present.
        let diag = diagnostics(renderLog: [
            .unimplementedRecord(type: 14, count: 1),    // EMR_EOF (excluded)
            .unimplementedRecord(type: 118, count: 2),   // EMR_GRADIENTFILL (kept)
        ])
        let items = DrawingMissingItems.list(from: diag)
        #expect(items.count == 1)
        #expect(items[0].contains("EMR_GRADIENTFILL"))
    }

    @Test func stockFontNotesAreNotMissingContent() {
        // A stock-font fallback still draws the text, so it must not appear in the
        // "what's missing" list (parity with couldNotShowNotes filtering).
        let diag = diagnostics(renderLog: [.stockFontUsed(rawValue: 17, count: 2)])
        #expect(DrawingMissingItems.list(from: diag).isEmpty)
    }

    @Test func namedItemsFlowIntoTheFencedPrompt() {
        let diag = diagnostics(renderLog: [.unimplementedRecord(type: 118, count: 1)])
        let items = DrawingMissingItems.list(from: diag)
        let prompt = DrawingAIPrompt.explainMissingPrompt(items: items)
        #expect(prompt.contains("EMR_GRADIENTFILL"))
        // The named record sits inside the data markers.
        let open = prompt.range(of: DrawingAIPrompt.openMarker)!
        let close = prompt.range(of: DrawingAIPrompt.closeMarker)!
        let name = prompt.range(of: "EMR_GRADIENTFILL")!
        #expect(name.lowerBound > open.upperBound && name.upperBound < close.lowerBound)
    }
}
