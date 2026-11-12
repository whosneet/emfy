import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing

/// The viewer Records segment (F5b): the pure filter, the drawing-record jump,
/// the summary cache key, the EMF+ step-through gating and the DC-panel
/// formatting. All pure/main-actor logic, no view.
@Suite struct RecordInspectorModelTests {

    private func ref(_ index: Int, _ name: String) -> RecordRef {
        RecordRef(index: index, typeName: name, offset: index * 8, size: 8,
                  isEMFPlusCarrier: false, emfPlusRecordCount: 0)
    }

    private var sampleRefs: [RecordRef] {
        [
            ref(0, "EMR_HEADER"),
            ref(1, "EMR_CREATEBRUSHINDIRECT"),
            ref(2, "EMR_SELECTOBJECT"),
            ref(3, "EMR_RECTANGLE"),
            ref(4, "EMR_EOF"),
        ]
    }

    // MARK: - Filter

    @Test("An empty filter shows every row")
    func filterEmptyShowsAll() {
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "") == [0, 1, 2, 3, 4])
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "   ") == [0, 1, 2, 3, 4])
    }

    @Test("The filter matches the type name, case-insensitively")
    func filterMatchesTypeName() {
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "rectangle") == [3])
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "SELECT") == [2])
        // A substring match spans every type name that contains it ("INDIRECT"
        // and "RECTANGLE" both contain "rect").
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "rect") == [1, 3])
        #expect(RecordInspectorLogic.filteredIndices(sampleRefs, query: "zzz").isEmpty)
    }

    // MARK: - Drawing-record jump

    @Test("The drawing-record jump steps to the next/previous drawing index")
    func drawingJump() {
        let drawing = [3, 6, 9]
        #expect(RecordInspectorLogic.adjacentDrawingIndex(after: 4, drawingIndices: drawing, forward: true) == 6)
        #expect(RecordInspectorLogic.adjacentDrawingIndex(after: 6, drawingIndices: drawing, forward: true) == 9)
        #expect(RecordInspectorLogic.adjacentDrawingIndex(after: 6, drawingIndices: drawing, forward: false) == 3)
        #expect(RecordInspectorLogic.adjacentDrawingIndex(after: 9, drawingIndices: drawing, forward: true) == nil)
        #expect(RecordInspectorLogic.adjacentDrawingIndex(after: 3, drawingIndices: drawing, forward: false) == nil)
    }

    // MARK: - Cache key

    @Test("The summary cache key is the content fingerprint")
    func cacheKey() {
        #expect(RecordInspectorLogic.summaryCacheKey(contentID: 42) == 42)
        #expect(RecordInspectorLogic.summaryCacheKey(contentID: 42) == RecordInspectorLogic.summaryCacheKey(contentID: 42))
        #expect(RecordInspectorLogic.summaryCacheKey(contentID: 7) != RecordInspectorLogic.summaryCacheKey(contentID: 8))
    }

    @Test("Summaries are built once per content and then served from the cache")
    @MainActor func summaryCached() {
        let model = RecordInspectorModel()
        model.setContent(refs: sampleRefs, drawingIndices: [3], supportsPartial: true, isEMF: true, contentID: 1)
        var builds = 0
        let first = model.summary(at: 3) { _ in builds += 1; return "(10,10)–(40,40)" }
        let second = model.summary(at: 3) { _ in builds += 1; return "SHOULD NOT REBUILD" }
        #expect(first == "(10,10)–(40,40)")
        #expect(second == "(10,10)–(40,40)")
        #expect(builds == 1)
    }

    // MARK: - EMF+ / WMF step gating

    @Test("Stepping is gated to a steppable EMF with more than one record")
    @MainActor func stepGating() {
        let steppable = RecordInspectorModel()
        steppable.setContent(refs: sampleRefs, drawingIndices: [3], supportsPartial: true, isEMF: true, contentID: 1)
        #expect(steppable.canStep)
        #expect(steppable.selectedIndex == 4)           // starts on the last record (full drawing)
        #expect(steppable.positionText == "5 / 5")

        let emfPlus = RecordInspectorModel()
        emfPlus.setContent(refs: sampleRefs, drawingIndices: [], supportsPartial: false, isEMF: true, contentID: 2)
        #expect(!emfPlus.canStep)                        // EMF+ drawing: scrubber disabled

        let wmf = RecordInspectorModel()
        wmf.setContent(refs: sampleRefs, drawingIndices: [], supportsPartial: false, isEMF: false, contentID: 3)
        #expect(!wmf.canStep)
        #expect(RecordInspectorLogic.emfPlusStepNote.contains("EMF+"))
    }

    @Test("Navigation clamps to the record range")
    @MainActor func navigationClamps() {
        let model = RecordInspectorModel()
        model.setContent(refs: sampleRefs, drawingIndices: [3], supportsPartial: true, isEMF: true, contentID: 1)
        model.home()
        #expect(model.selectedIndex == 0)
        model.step(by: -1)
        #expect(model.selectedIndex == 0)               // clamped at the bottom
        model.jumpDrawing(forward: true)
        #expect(model.selectedIndex == 3)
        model.end()
        #expect(model.selectedIndex == 4)
        model.step(by: 10)
        #expect(model.selectedIndex == 4)               // clamped at the top
    }

    // MARK: - DC-panel formatting

    @Test("The DC panel formats a real playback state into four groups with colour swatches")
    func stateFormatting() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/gate-p2-house.emf")
        let file = try EMFFile.parse(try Data(contentsOf: url))
        let state = EMFRenderer.playbackState(of: file, throughRecordIndex: file.records.count - 1)
        let groups = RecordStateFormat.groups(for: state)

        #expect(groups.map(\.title) == ["Objects", "Colours", "Mapping", "State"])
        // The colour rows carry a swatch; the text-align row does not.
        let colours = try #require(groups.first { $0.title == "Colours" })
        let textRow = try #require(colours.rows.first { $0.label == "Text" })
        #expect(textRow.swatch != nil)
        #expect(textRow.value.hasPrefix("#"))
        let alignRow = try #require(colours.rows.first { $0.label == "Text align" })
        #expect(alignRow.swatch == nil)
        // The mapping group names the map mode.
        let mapping = try #require(groups.first { $0.title == "Mapping" })
        let mapRow = try #require(mapping.rows.first { $0.label == "Map mode" })
        #expect(mapRow.value.hasPrefix("MM_"))
    }

    @Test("The compact number formatter trims and keeps integers clean")
    func numberFormatting() {
        #expect(RecordStateFormat.num(1) == "1")
        #expect(RecordStateFormat.num(-2) == "-2")
        #expect(RecordStateFormat.num(1.5) == "1.5")
        #expect(RecordStateFormat.num(1.2500) == "1.25")
    }
}
