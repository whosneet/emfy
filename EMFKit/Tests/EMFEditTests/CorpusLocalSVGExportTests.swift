import Foundation
import Testing
@testable import EMFEdit

/// F2 corpus-local structural sweep: every importable corpus-local file exports to
/// well-formed, non-trivial SVG without crashing, cheaply. Work-sourced files are
/// anonymised — COUNTS only, never names. No-ops when `corpus-local/` is absent.
struct CorpusLocalSVGExportTests {

    @Test func everyLocalFileExportsWellFormedSVG() throws {
        let files = EditTestPaths.localMetafiles()
        guard !files.isEmpty else { return }   // corpus-local is gitignored / may be absent

        var exported = 0, skipped = 0, malformed = 0, slow = 0
        var totalBytes = 0
        var worstSeconds = 0.0
        let start = Date()

        for url in files {
            guard let data = try? Data(contentsOf: url), let scene = try? SceneImporter.import(data: data) else {
                skipped += 1; continue
            }
            let t0 = Date()
            let result = SceneSVGExporter.export(scene)
            let dt = Date().timeIntervalSince(t0)
            worstSeconds = max(worstSeconds, dt)
            if dt > 10 { slow += 1 }

            let parser = XMLParser(data: result.data)
            if !parser.parse() { malformed += 1; continue }
            // A minimal valid document is still well-formed; require a real root.
            guard let text = String(data: result.data, encoding: .utf8),
                  text.contains("<svg "), text.hasSuffix("</svg>\n") else { malformed += 1; continue }
            exported += 1
            totalBytes += result.data.count
        }

        let elapsed = Date().timeIntervalSince(start)
        print("""

        === F2 corpus-local SVG sweep ===
        files=\(files.count) exported=\(exported) unimportable=\(skipped) malformed=\(malformed)
        total SVG bytes=\(totalBytes) worst-export=\(String(format: "%.3f", worstSeconds))s sweep=\(String(format: "%.1f", elapsed))s slow(>10s)=\(slow)
        """)

        #expect(malformed == 0, "corpus-local produced \(malformed) malformed SVG document(s)")
        // Every file the IMPORTER accepts must export (export never fails a scene).
        #expect(exported + skipped == files.count)
    }
}
