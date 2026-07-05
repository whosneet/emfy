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

    /// The phase-4 text gate file exercises the real text record set:
    /// EMR_EXTCREATEFONTINDIRECTW (82) and EMR_EXTTEXTOUTW (84). Every one of
    /// those must decode non-malformed, and the three EmrText strings must
    /// decode to their known contents — real-world EmrText validation for free.
    @Test("gate-p4-text.emf: 82/84 records decode non-malformed, strings correct")
    func gateP4Text() throws {
        let url = CorpusPaths.file("gate-p4-text.emf")
        let data = try #require(
            try? Data(contentsOf: url),
            "corpus file not readable at \(url.path) — see CorpusPaths fragility note"
        )
        let file = try EMFFile.parse(data)

        var fontCount = 0
        var strings: [String] = []
        for record in file.records {
            let payload = file.payload(of: record)
            // The text records must never be a malformed verdict.
            if record.type == 82 || record.type == 84 {
                #expect(payload.malformedReason == nil, "record type \(record.type) decoded malformed")
            }
            switch payload {
            case .extCreateFontIndirectW:
                fontCount += 1
            case .extTextOutW(let text):
                strings.append(text.string)
            default:
                break
            }
        }

        #expect(fontCount == 3)
        #expect(strings == ["Hello Emfy 123", "Quick brown fox", "Bold small text"])
    }

    /// The phase-4 image gate file exercises EMR_STRETCHDIBITS (81) with an
    /// embedded 24-bit BI_RGB DIB. It must decode non-malformed with decoded
    /// pixels (not `.unsupported`).
    @Test("gate-p4-image.emf: 81 record decodes non-malformed with pixels")
    func gateP4Image() throws {
        let url = CorpusPaths.file("gate-p4-image.emf")
        let data = try #require(
            try? Data(contentsOf: url),
            "corpus file not readable at \(url.path) — see CorpusPaths fragility note"
        )
        let file = try EMFFile.parse(data)

        var sawStretch = false
        for record in file.records where record.type == 81 {
            let payload = file.payload(of: record)
            #expect(payload.malformedReason == nil, "STRETCHDIBITS decoded malformed")
            guard case .stretchDIBits(let p) = payload else {
                Issue.record("expected .stretchDIBits, got \(payload)")
                continue
            }
            sawStretch = true
            let dib = try #require(p.dib)
            #expect(dib.bitCount == 24)
            #expect(dib.compression == .rgb)
            // The embedded image is a real BI_RGB bitmap — pixels, not
            // .unsupported.
            if case .unsupported(let reason) = dib.content {
                Issue.record("expected decoded pixels, got .unsupported(\(reason))")
            }
        }
        #expect(sawStretch)
    }
}
