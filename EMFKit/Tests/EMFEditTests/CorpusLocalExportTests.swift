import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// Exercises the E1b1 overlay exporter over every parseable GDI EMF in
/// `corpus-local/` (gitignored; may be absent): delete the middle editable
/// element and translate the first, export, re-import, render-compare, and parse.
/// Work-sourced files are confidential — this reports COUNTS only, never a name
/// or any content.
struct CorpusLocalExportTests {

    @Test func overlayExportAcrossLocalCorpus() throws {
        let files = EditTestPaths.localMetafiles()
        guard !files.isEmpty else {
            print("\n=== E1b1 corpus-local export: absent (0 files) ===")
            return
        }

        var gdiEMF = 0            // parseable GDI EMF with >= 2 editable elements
        var exported = 0          // export of the edited scene succeeded
        var reimported = 0        // the output re-imports
        var editVisible = 0       // the moved + deleted edit shows on re-import
        var parseClean = 0        // output parses with no diagnostics and correct counts
        var rendered = 0          // render-compared within budget (where rendered)
        var renderSkipped = 0     // skipped render (too large) — export still checked
        var renderFailed = 0
        var outliers: [String] = []   // by enumeration index only — never names
        let tolerance = 16
        let budget = 0.03
        var fileIndex = -1

        for url in files {
            guard url.pathExtension.lowercased() == "emf" || url.pathExtension.lowercased() == "emz" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let base = try? SceneImporter.import(data: data),
                  base.source.renderPath == .gdi,
                  base.source.format == .emf
            else { continue }
            let editable = base.editableElements
            guard editable.count >= 2 else { continue }
            gdiEMF += 1
            fileIndex += 1

            let firstID = editable[0].id
            let midID = editable[editable.count / 2].id
            guard midID != firstID else { continue }

            var scene = base
            guard (try? scene.delete([midID])) != nil,
                  (try? scene.translate([firstID], dx: 10, dy: 5)) != nil else { continue }

            let result: ExportResult
            do { result = try SceneExporter.export(scene, as: .emf) }
            catch { outliers.append("export#\(fileIndex): \(error) firstKind=\(base.element(id: firstID)?.kind ?? .group)"); continue }
            exported += 1

            guard let re = try? SceneImporter.import(data: result.data) else { continue }
            reimported += 1
            if re.partition.isComplete, re.editableElements.count == base.editableElements.count - 1 {
                editVisible += 1
            } else {
                // Report the delta by index only — a deleted element whose draw
                // spanned a shared record, or a lift that re-split, changes the count.
                outliers.append("count#\(fileIndex): base=\(base.editableElements.count) reimport=\(re.editableElements.count) complete=\(re.partition.isComplete)")
            }

            if let file = try? EMFFile.parse(result.data) {
                if file.diagnostics.isEmpty, Int(file.header.records) == file.records.count {
                    parseClean += 1
                } else {
                    // Report by index only — a diagnostic or a header-count mismatch
                    // in the output (never names/content).
                    outliers.append("parse#\(fileIndex): diagnostics=\(file.diagnostics) records=\(file.records.count) header=\(file.header.records)")
                }
            } else {
                outliers.append("parse#\(fileIndex): exported EMF did not parse")
            }

            // Render-compare at scale 1 for pages within a bounded area.
            let area = base.pageSizeDevice.width * base.pageSizeDevice.height
            if area > 4_000_000 { renderSkipped += 1; continue }
            guard let sceneImg = SceneRenderer.makeImage(scene, scale: 1),
                  let opened = try? OpenedMetafile.open(result.data),
                  let outImg = MetafileRenderer.makeImage(opened, scale: 1)?.0 else {
                renderFailed += 1; outliers.append("render#\(fileIndex): render nil"); continue
            }
            let diff = compareImages(sceneImg, outImg, tolerance: tolerance)
            if diff.sameSize && diff.differingFraction <= budget { rendered += 1 }
            else { renderFailed += 1; outliers.append("render#\(fileIndex): frac=\(String(format: "%.4f", diff.differingFraction)) max=\(diff.maxChannelDelta) sameSize=\(diff.sameSize) edKinds=\(base.element(id: firstID)?.kind ?? .group)/\(base.element(id: midID)?.kind ?? .group)") }
        }

        print("""

        === E1b1 corpus-local export (counts only) ===
        GDI EMF with >=2 editable : \(gdiEMF)
        export succeeded          : \(exported)
        re-imported               : \(reimported)
        edit visible (count-1)    : \(editVisible)
        parse clean               : \(parseClean)
        render within \(Int(budget*100))%        : \(rendered)
        render skipped (large)    : \(renderSkipped)
        render failed/over-budget : \(renderFailed)
        outliers (by index only)  : \(outliers.isEmpty ? "none" : "")
        \(outliers.joined(separator: "\n        "))
        """)

        // Every file that exported must re-import and parse cleanly; most render matches.
        #expect(exported == gdiEMF, "some GDI EMF scenes failed to export")
        #expect(reimported == exported, "some exported files failed to re-import")
        #expect(parseClean == exported, "some exported files parsed with diagnostics or wrong counts")
        if rendered + renderFailed > 0 {
            let ok = Double(rendered) / Double(rendered + renderFailed)
            #expect(ok >= 0.9, "render match rate \(ok) below 90%")
        }
    }
}
