import Foundation
import Testing
@testable import EMFParse

/// Filesystem anchor for committed corpus files, derived from `#filePath`.
///
/// FRAGILITY NOTE: the location is resolved from this source file's compile-
/// time path (`<repo>/EMFKit/Tests/EMFParseTests/`). Moving this file,
/// renaming the test directory, or building from a copied tree without the
/// sibling `corpus/` directory breaks the lookup. This mirrors the same
/// trade-off documented in EMFRenderTests' `TestPaths`; SPM has no supported
/// way to reference files outside the package.
private enum CorpusPaths {
    /// `<repo>/corpus/<name>`
    static func file(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // EMFParseTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // EMFKit
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("corpus")
            .appendingPathComponent(name)
    }
}

@Suite("Corpus path-record decode")
struct CorpusPathTests {

    /// The committed, hand-authored corpus file exercises a real path bracket:
    /// BEGINPATH … geometry … CLOSEFIGURE/ENDPATH … STROKEANDFILLPATH (see the
    /// corpus/README.md manifest). Every one of those records must decode to a
    /// non-`.malformed` payload of the expected case.
    @Test("handmade-strokes-paths.emf: path records decode non-malformed")
    func handmadeStrokesPaths() throws {
        let url = CorpusPaths.file("handmade-strokes-paths.emf")
        let data = try #require(
            try? Data(contentsOf: url),
            "corpus file not readable at \(url.path) — see CorpusPaths fragility note"
        )
        let file = try EMFFile.parse(data)
        #expect(file.diagnostics.isEmpty)

        var sawBeginPath = false
        var sawEndPath = false
        var sawCloseFigure = false
        var sawStrokeAndFill = false

        for record in file.records {
            let payload = file.payload(of: record)
            // No record in this file may be a malformed verdict.
            #expect(payload.malformedReason == nil, "record type \(record.type) decoded malformed")

            switch payload {
            case .beginPath: sawBeginPath = true
            case .endPath: sawEndPath = true
            case .closeFigure: sawCloseFigure = true
            case .strokeAndFillPath: sawStrokeAndFill = true
            default: break
            }
        }

        // The manifest guarantees each of these appears exactly once.
        #expect(sawBeginPath)
        #expect(sawEndPath)
        #expect(sawCloseFigure)
        #expect(sawStrokeAndFill)
    }
}
