import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

// X1a: the fenced AI-summary data block and the Markdown report export.

@Suite struct DrawingAnalysisReportTests {

    private func rectPath(_ r: CGRect) -> ScenePath {
        ScenePath(segments: [.move(CGPoint(x: r.minX, y: r.minY)), .line(CGPoint(x: r.maxX, y: r.minY)),
                             .line(CGPoint(x: r.maxX, y: r.maxY)), .line(CGPoint(x: r.minX, y: r.maxY)), .close])
    }

    private func fixture() -> Scene {
        let grey = SceneColor(ColorRef(red: 0x99, green: 0x99, blue: 0x99))
        var textStyle = SceneStyle(); textStyle.fill = SceneFill(color: grey, evenOdd: false)
        let text = SceneText(string: "Secret label", fontFamily: "Helvetica", logicalHeight: -8, color: grey, referenceLogical: .zero, alignRawValue: 0)
        let textEl = Element(id: 1, kind: .text, geometryDevice: rectPath(CGRect(x: 180, y: 200, width: 120, height: 10)),
                             transform: .identity, style: textStyle, text: text, provenance: Provenance(sourceRecordIndices: []))
        var redStyle = SceneStyle(); redStyle.fill = SceneFill(color: SceneColor(ColorRef(red: 0xCC, green: 0, blue: 0)), evenOdd: false)
        let red = Element(id: 2, kind: .rect, geometryDevice: rectPath(CGRect(x: 10, y: 10, width: 50, height: 50)),
                          transform: .identity, style: redStyle, provenance: Provenance(sourceRecordIndices: []))
        var greenStyle = SceneStyle(); greenStyle.fill = SceneFill(color: SceneColor(ColorRef(red: 0, green: 0x99, blue: 0)), evenOdd: false)
        let green = Element(id: 3, kind: .rect, geometryDevice: rectPath(CGRect(x: 70, y: 10, width: 50, height: 50)),
                            transform: .identity, style: greenStyle, provenance: Provenance(sourceRecordIndices: []))
        let layer = Layer(id: 0, name: "Layer 1", elements: [textEl, red, green])
        let source = SceneSource(data: Data(), format: .wmf, wasCompressed: false, renderPath: .wmf, unitCount: 0)
        let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
        return Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 400, height: 300), layers: [layer], partition: partition, source: source)
    }

    @Test func summaryDataIsFencedAndCarriesFindingsOnly() {
        let analysis = DrawingAnalysis(scene: fixture())
        let data = analysis.summaryData()
        #expect(data.hasPrefix("<<<DRAWING_ANALYSIS_DATA"))
        #expect(data.contains("<<<END_DRAWING_ANALYSIS_DATA>>>"))
        #expect(data.contains("Findings: \(analysis.findings.count)"))
        #expect(data.contains("Low text contrast"))
        // Raw drawing text is NOT handed to the model (untrusted content).
        #expect(!data.contains("Secret label"))
    }

    @Test func summaryColourPairPhrasingIsUnambiguous() throws {
        let data = DrawingAnalysis(scene: fixture()).summaryData()
        // The colour-pair line must say the colours become INDISTINGUISHABLE, so a model
        // can't invert it to "show up differently".
        #expect(data.contains("look the same to people with"))
        #expect(data.contains("colour blindness"))
        // The phrasing stays inside the data fence.
        let open = try #require(data.range(of: "<<<DRAWING_ANALYSIS_DATA"))
        let close = try #require(data.range(of: "<<<END_DRAWING_ANALYSIS_DATA>>>"))
        let phrase = try #require(data.range(of: "look the same to people with"))
        #expect(phrase.lowerBound > open.upperBound && phrase.upperBound < close.lowerBound)
    }

    @Test func hexStringFormatting() {
        #expect(SceneColor(ColorRef(red: 0xCC, green: 0, blue: 0)).hexString == "#CC0000")
        #expect(SceneColor(red: 0, green: 0, blue: 0, alpha: 0.5).hexString == "#00000080")
    }

    @Test func markdownReportHasSectionsAndText() {
        let md = DrawingAnalysis(scene: fixture()).markdownReport(title: "Test report")
        #expect(md.hasPrefix("# Test report"))
        #expect(md.contains("## Fonts"))
        #expect(md.contains("Helvetica"))
        #expect(md.contains("## Colours"))
        #expect(md.contains("#CC0000"))
        #expect(md.contains("## Accessibility findings"))
        // The user-facing export DOES include the text inventory.
        #expect(md.contains("Secret label"))
    }

    @Test func markdownReportIsCleanWhenNoFindings() {
        let source = SceneSource(data: Data(), format: .wmf, wasCompressed: false, renderPath: .wmf, unitCount: 0)
        let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
        let empty = Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 100, height: 100), layers: [Layer(id: 0, name: "Layer 1", elements: [])], partition: partition, source: source)
        let md = DrawingAnalysis(scene: empty).markdownReport()
        #expect(md.contains("No accessibility or legibility issues found."))
    }
}
