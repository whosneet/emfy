import Foundation
import Testing

/// F2 app wiring: the viewer's SVG export path (`SceneImporter` → `SceneSVGExporter`,
/// via `SVGExport.data`) produces well-formed, standalone SVG bytes for a valid
/// metafile, and refuses bytes it can't import. The logic-test bundle can't reach
/// the EMFKit corpus, so the fixture is the in-code minimal EMF the rest of this
/// bundle uses.
struct SVGExportTests {

    @Test func svgExportProducesWellFormedDocument() throws {
        let emf = EmfyTests.minimalEMF(width: 200, height: 120)
        let produced = try #require(SVGExport.data(from: emf))
        // Well-formed XML: Quick Look and other apps parse the exported file.
        let parser = XMLParser(data: produced.data)
        #expect(parser.parse())
        let text = try #require(String(data: produced.data, encoding: .utf8))
        #expect(text.hasPrefix("<?xml version=\"1.0\""))
        #expect(text.contains("<svg "))
        #expect(text.contains("viewBox=\""))
        #expect(text.hasSuffix("</svg>\n"))
    }

    @Test func svgExportRejectsUnparseableBytes() {
        #expect(SVGExport.data(from: Data([1, 2, 3])) == nil)
    }
}
