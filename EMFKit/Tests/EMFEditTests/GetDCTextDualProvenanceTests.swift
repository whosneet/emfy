import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Provenance for `corpus/handmade-getdc-text-dual.emf`: the committed file is
/// byte-for-byte the output of `GetDCTextDualCorpus.fixtureData()`, so it can
/// never drift from its documented origin (a GDI source → import → set the
/// rectangle's opacity to 0.5 → dual export).
///
/// Under `EMFY_RECORD=1` this (re-)writes the file into the source `corpus/` and
/// fails deliberately, so a recording run can never pass as green — the same
/// convention as the CJK/EMF+ hand-authored fixtures.
struct GetDCTextDualProvenanceTests {

    private static var recording: Bool { ProcessInfo.processInfo.environment["EMFY_RECORD"] == "1" }

    private static var corpusURL: URL {
        EditTestPaths.corpusDirectory.appendingPathComponent("\(GetDCTextDualCorpus.fixtureName).emf")
    }

    @Test func committedFixtureEqualsGenerator() throws {
        let generated = try GetDCTextDualCorpus.fixtureData()
        if Self.recording {
            try generated.write(to: Self.corpusURL)
            Issue.record("EMFY_RECORD: wrote \(Self.corpusURL.path) — re-run without EMFY_RECORD to verify")
            return
        }
        let committed = try #require(
            try? Data(contentsOf: Self.corpusURL),
            "corpus file not readable at \(Self.corpusURL.path) — materialise it with EMFY_RECORD=1 swift test --filter committedFixtureEqualsGenerator"
        )
        #expect(committed == generated,
                "committed \(GetDCTextDualCorpus.fixtureName).emf differs from the generator (\(committed.count) vs \(generated.count) bytes)")
    }

    /// The source GDI EMF is also reproducible, and genuinely GDI-only (no EMF+):
    /// the fixture's dual-ness comes from the OPACITY edit, not the source.
    @Test func sourceIsGDIOnlyAndDeterministic() throws {
        let a = try GetDCTextDualCorpus.sourceGDIData()
        let b = try GetDCTextDualCorpus.sourceGDIData()
        #expect(a == b, "source generator is not deterministic")
        let scene = try SceneImporter.import(data: a)
        #expect(scene.source.renderPath == .gdi, "source is not GDI-only: \(scene.source.renderPath)")
        // Two text runs plus two shapes lift as editable content.
        #expect(scene.editableElements.filter { $0.kind == .text }.count == 2, "expected two text runs")
        #expect(scene.editableElements.contains { $0.kind == .rect }, "expected a rectangle")
        #expect(scene.editableElements.contains { $0.kind == .ellipse }, "expected an ellipse")
    }

    /// The committed fixture is a parse-clean DUAL EMF+ file whose two text runs
    /// are GetDC-window GDI entries (not EMF+ draws), so editing one drives the
    /// world-transform re-emit this fixture exists to pin down.
    @Test func committedFixtureIsDualWithGetDCText() throws {
        let data = try #require(try? Data(contentsOf: Self.corpusURL), "fixture missing")
        let file = try EMFFile.parse(data)
        #expect(file.diagnostics.isEmpty, "EMF diagnostics: \(file.diagnostics)")
        let plus = file.emfPlusStream()
        #expect(plus.diagnostics.isEmpty, "EMF+ diagnostics: \(plus.diagnostics)")
        #expect(plus.header?.isDual == true, "fixture is not a dual EMF+ file")
        #expect(plus.records.contains { $0.isDrawing }, "fixture has no EMF+ drawing records")

        let scene = try SceneImporter.import(data: data)
        #expect(scene.source.renderPath == .emfPlus, "fixture did not import as EMF+")
        // The two text runs are GetDC-window GDI entries.
        guard let opened = try? OpenedMetafile.open(data), let prepared = MetafileRenderer.prepare(opened) else {
            Issue.record("prepare failed"); return
        }
        let entries = MetafileRenderer.observe(prepared).plusEntries
        let gdiCount = entries.filter { if case .gdi = $0 { return true }; return false }.count
        #expect(gdiCount >= 3, "expected the ellipse + two text runs as GetDC GDI entries, got \(gdiCount)")
        // Both text runs replay verbatim (two EXTTEXTOUTW records), and each run
        // carries its explicit Dx advances through the import.
        let textRuns = scene.editableElements.filter { $0.kind == .text }
        #expect(textRuns.count == 2)
        #expect(textRuns.allSatisfy { !($0.text?.advancesLogical.isEmpty ?? true) }, "a text run lost its Dx advances")
    }
}
