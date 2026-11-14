import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import Testing

// F3 unit tests for the pure text extractor (`DrawingTextExtractor`): sanitisation
// and the per-run/per-file caps, reading-order sort, Copy All Text assembly, and
// extraction from a real corpus scene with known text. OCR runs are modelled as
// `.picture` source runs so the reading-order and Copy All Text behaviour is tested
// without Vision.

@Suite struct DrawingTextExtractionTests {

    private func run(_ text: String, _ rect: CGRect, _ source: DrawingTextRun.Source = .drawing) -> DrawingTextRun {
        DrawingTextRun(text: text, boundsDevice: rect, fontFamily: nil, fontSize: nil, source: source)
    }

    // MARK: Sanitisation and caps

    @Test func sanitizeStripsControlCharacters() {
        #expect(DrawingTextExtractor.sanitize("a\u{0000}b\tc\nd\re") == "abcde")
        #expect(DrawingTextExtractor.sanitize("héllo") == "héllo")   // diacritics kept
        #expect(DrawingTextExtractor.sanitize("漢字") == "漢字")       // CJK kept
    }

    @Test func sanitizeCapsAtPerRunLimit() {
        let long = String(repeating: "x", count: DrawingTextExtractor.maxCharactersPerRun + 500)
        let clean = DrawingTextExtractor.sanitize(long)
        #expect(clean.utf16.count == DrawingTextExtractor.maxCharactersPerRun)
    }

    @Test func perFileCapStopsAddingRuns() {
        // Each run is at the per-run cap; after ~32 runs the 1 MB file cap is hit.
        let big = String(repeating: "y", count: DrawingTextExtractor.maxCharactersPerRun)
        let scene = sceneWithTextRuns(Array(repeating: big, count: 40))
        let runs = DrawingTextExtractor.extract(from: scene)
        let total = runs.reduce(0) { $0 + $1.text.utf16.count }
        #expect(total <= DrawingTextExtractor.maxCharactersPerFile)
        #expect(runs.count < 40)
    }

    @Test func emptyAfterSanitizeIsDropped() {
        let scene = sceneWithTextRuns(["\u{0000}\u{0001}", "real"])
        let runs = DrawingTextExtractor.extract(from: scene)
        #expect(runs.map(\.text) == ["real"])
    }

    // MARK: Visual line count (FM-3)

    @Test func visualLineCountGroupsMultiRunLines() {
        // Two visual rows, each drawn as three separate runs (kerned words) at the
        // same y. Row height 10 → band 5. The old per-run count would say 6.
        let input = [
            run("Hello", CGRect(x: 0, y: 0, width: 20, height: 10)),
            run("there", CGRect(x: 25, y: 0, width: 20, height: 10)),
            run("world", CGRect(x: 50, y: 0, width: 20, height: 10)),
            run("second", CGRect(x: 0, y: 40, width: 20, height: 10)),
            run("line", CGRect(x: 25, y: 40, width: 20, height: 10)),
            run("here", CGRect(x: 50, y: 40, width: 20, height: 10)),
        ]
        #expect(DrawingTextExtractor.visualLineCount(input) == 2)
    }

    @Test func visualLineCountIgnoresWhitespaceRuns() {
        let input = [
            run("alpha", CGRect(x: 0, y: 0, width: 20, height: 10)),
            run("   ", CGRect(x: 25, y: 0, width: 20, height: 10)),     // whitespace-only
            run("beta", CGRect(x: 0, y: 40, width: 20, height: 10)),
        ]
        #expect(DrawingTextExtractor.visualLineCount(input) == 2)
    }

    @Test func visualLineCountEdgeCounts() {
        #expect(DrawingTextExtractor.visualLineCount([]) == 0)
        #expect(DrawingTextExtractor.visualLineCount([run("only", CGRect(x: 0, y: 0, width: 10, height: 10))]) == 1)
        // A lone whitespace run is not a line.
        #expect(DrawingTextExtractor.visualLineCount([run("  ", CGRect(x: 0, y: 0, width: 10, height: 10))]) == 0)
    }

    // MARK: Reading order

    @Test func readingOrderSortsTopToBottomLeftToRight() {
        // Deliberately shuffled: bottom-right, top-right, top-left, bottom-left.
        let input = [
            run("D", CGRect(x: 10, y: 100, width: 20, height: 10)),
            run("B", CGRect(x: 10, y: 0, width: 20, height: 10)),
            run("A", CGRect(x: 0, y: 0, width: 5, height: 10)),
            run("C", CGRect(x: 0, y: 100, width: 5, height: 10)),
        ]
        #expect(DrawingTextExtractor.readingOrder(input).map(\.text) == ["A", "B", "C", "D"])
    }

    @Test func readingOrderClustersRunsOnTheSameRow() {
        // Slight vertical jitter within one line must not reorder the columns.
        let input = [
            run("world", CGRect(x: 100, y: 2, width: 40, height: 10)),
            run("hello", CGRect(x: 0, y: 0, width: 40, height: 10)),
        ]
        #expect(DrawingTextExtractor.readingOrder(input).map(\.text) == ["hello", "world"])
    }

    // MARK: Copy All Text

    @Test func copyAllTextJoinsReadingOrderWithPictureSection() {
        let input = [
            run("second", CGRect(x: 0, y: 50, width: 30, height: 10)),
            run("first", CGRect(x: 0, y: 0, width: 30, height: 10)),
            run("in-pic", CGRect(x: 0, y: 0, width: 30, height: 10), .picture),
        ]
        let text = DrawingTextExtractor.copyAllText(input)
        #expect(text == "first\nsecond\n\nText in pictures:\nin-pic")
    }

    @Test func copyAllTextIsEmptyWhenNothingToCopy() {
        #expect(DrawingTextExtractor.copyAllText([]) == "")
    }

    // MARK: Corpus scene with known text

    @Test func extractsKnownTextFromCorpusScene() throws {
        let scene = try corpusScene("gate-p4-text.emf")
        let runs = DrawingTextExtractor.extract(from: scene)
        #expect(!runs.isEmpty)
        // The file's visible text concatenated in reading order carries letters.
        let joined = DrawingTextExtractor.copyAllText(runs)
        #expect(joined.contains(where: { $0.isLetter }))
        // Every run is sanitised: no control characters survive.
        for r in runs {
            #expect(!r.text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        }
    }

    // MARK: Helpers

    private func corpusScene(_ name: String) throws -> Scene {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/\(name)")
        let data = try Data(contentsOf: url)
        return try SceneImporter.import(data: data)
    }

    /// Builds a minimal scene whose only elements are text runs with the given
    /// strings, stacked vertically, for sanitisation/cap tests.
    private func sceneWithTextRuns(_ strings: [String]) -> Scene {
        var elements: [Element] = []
        for (i, s) in strings.enumerated() {
            let origin = CGPoint(x: 0, y: CGFloat(i) * 20 + 12)
            let el = SceneFactory.makeText(
                string: s,
                originDevice: origin,
                family: "Helvetica",
                pointSize: 12,
                color: SceneColor(red: 0, green: 0, blue: 0),
                id: i,
                deviceUnitsPerPoint: 1
            )
            elements.append(el)
        }
        let layer = Layer(id: 0, name: "Layer 1", elements: elements)
        return Scene(
            pageBoundsDevice: CGRect(x: 0, y: 0, width: 200, height: CGFloat(strings.count) * 20 + 20),
            layers: [layer],
            partition: ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0),
            source: SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
        )
    }
}
