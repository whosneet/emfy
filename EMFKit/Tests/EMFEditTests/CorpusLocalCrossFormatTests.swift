import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
import WMFParse
@testable import EMFEdit

/// Slice E1b2c corpus-local sweep (gitignored; may be absent): every parseable
/// EMF/EMF+/GDI file → WMF, and every WMF file → EMF. Full cross-container
/// synthesis re-touches every element, so the breadth sweep runs the structural
/// gate (export, parse-clean) on a 1-in-2 file sample within a byte-size cap, and
/// samples re-import + render fidelity, to stay inside the EMFEdit time budget
/// (the committed oracle and the hostile test are the correctness gates). Work-
/// sourced files are confidential — COUNTS and anonymised indices only.
struct CorpusLocalCrossFormatTests {

    @Test func emfToWMFAcrossLocalCorpus() throws {
        let files = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "emf" || $0.pathExtension.lowercased() == "emz" }
        guard !files.isEmpty else { print("\n=== E1b2c corpus-local EMF→WMF: absent (0 files) ==="); return }

        // Full EMF→WMF synthesis touches every element and re-imports each output
        // through the whole observer, so the sweep is kept cheap for the EMFEdit time
        // budget: the few multi-MB Office files are skipped by byte size, and the
        // structural gate runs on a deterministic 1-in-2 file sample. The committed
        // cross-format oracle (both directions, full fidelity) and the 10k-element
        // hostile test are the correctness gates; this is the breadth sanity check.
        let sizeCap = 400_000
        var candidates = 0, scenes = 0, skippedLarge = 0, exported = 0, parseClean = 0, reimportSamples = 0, reimported = 0
        var sampled = 0, rendered = 0
        var buckets = [0, 0, 0, 0]   // ≤2%, ≤5%, ≤15%, >15%
        var outliers: [String] = []
        var index = -1

        for url in files {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > sizeCap { skippedLarge += 1; continue }
            candidates += 1
            guard candidates % 2 == 0 else { continue }   // 1-in-2 structural sample
            guard let data = try? Data(contentsOf: url), let base = try? SceneImporter.import(data: data) else { continue }
            index += 1
            scenes += 1

            // Structural gate (embed off → tests the synthesis directly).
            let result: ExportResult
            do { result = try SceneExporter.export(base, as: .wmf, options: ExportOptions(embedEMFInWMF: false)) }
            catch { outliers.append("export#\(index)=\(error)"); continue }
            exported += 1
            guard let wmf = try? WMFFile.parse(result.data) else { outliers.append("parse#\(index)"); continue }
            if wmf.diagnostics.isEmpty { parseClean += 1 } else { outliers.append("diag#\(index)") }

            // Re-import + render fidelity on a small, bounded subset (every 5th file) —
            // re-import runs the full observer, so keep it off the all-files path.
            guard index % 5 == 0 else { continue }
            reimportSamples += 1
            if (try? SceneImporter.import(data: result.data)) != nil { reimported += 1 } else { outliers.append("reimport#\(index)") }
            let area = base.pageSizeDevice.width * base.pageSizeDevice.height
            guard area <= 4_000_000 else { continue }
            sampled += 1
            let scale = min(CGFloat(2), CGFloat(900) / max(max(base.pageSizeDevice.width, base.pageSizeDevice.height), 1))
            guard let opened = try? OpenedMetafile.open(data),
                  let original = MetafileRenderer.makeImage(opened, scale: scale)?.0,
                  let outOpened = try? OpenedMetafile.open(result.data),
                  let outImg = MetafileRenderer.makeImage(outOpened, scale: scale)?.0 else { continue }
            rendered += 1
            let diff = compareImages(original, outImg, tolerance: 16)
            let f = diff.sameSize ? diff.differingFraction : 1
            if f <= 0.02 { buckets[0] += 1 } else if f <= 0.05 { buckets[1] += 1 } else if f <= 0.15 { buckets[2] += 1 }
            else { buckets[3] += 1; outliers.append("render#\(index)=\(String(format: "%.1f%%", f * 100))") }
        }

        print("""

        === E1b2c corpus-local EMF → WMF (counts only) ===
        candidates (≤400KB)    : \(candidates) (skipped large: \(skippedLarge))
        scenes (1-in-2 sample) : \(scenes)
        exported               : \(exported)
        parse-clean WMF        : \(parseClean)
        re-imported (sampled)  : \(reimported) / \(reimportSamples)
        render sampled         : \(sampled) (rendered \(rendered))
        render ≤2% / ≤5% / ≤15% / >15% : \(buckets[0]) / \(buckets[1]) / \(buckets[2]) / \(buckets[3])
        outliers (index only)  : \(outliers.prefix(20).joined(separator: ", "))
        """)

        #expect(exported == scenes, "some EMF→WMF exports failed")
        #expect(parseClean == exported, "some EMF→WMF outputs had WMF diagnostics")
        #expect(reimported == reimportSamples, "some sampled EMF→WMF outputs failed to re-import")
    }

    @Test func wmfToEMFAcrossLocalCorpus() throws {
        let files = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "wmf" || $0.pathExtension.lowercased() == "wmz" }
        guard !files.isEmpty else { print("\n=== E1b2c corpus-local WMF→EMF: absent (0 WMF files) ==="); return }

        var scenes = 0, exported = 0, parseClean = 0, reimported = 0
        var sampled = 0, buckets = [0, 0, 0, 0]
        var outliers: [String] = []
        var index = -1

        for url in files {
            guard let data = try? Data(contentsOf: url), let base = try? SceneImporter.import(data: data) else { continue }
            index += 1
            scenes += 1
            guard let result = try? SceneExporter.export(base, as: .emf) else { outliers.append("export#\(index)"); continue }
            exported += 1
            if let file = try? EMFFile.parse(result.data), file.diagnostics.isEmpty, Int(file.header.records) == file.records.count { parseClean += 1 }
            else { outliers.append("parse#\(index)") }
            if (try? SceneImporter.import(data: result.data)) != nil { reimported += 1 } else { outliers.append("reimport#\(index)") }

            guard index % 5 == 0 else { continue }
            let area = base.pageSizeDevice.width * base.pageSizeDevice.height
            guard area <= 4_000_000 else { continue }
            sampled += 1
            let scale = min(CGFloat(2), CGFloat(900) / max(max(base.pageSizeDevice.width, base.pageSizeDevice.height), 1))
            guard let opened = try? OpenedMetafile.open(data),
                  let original = MetafileRenderer.makeImage(opened, scale: scale)?.0,
                  let outOpened = try? OpenedMetafile.open(result.data),
                  let outImg = MetafileRenderer.makeImage(outOpened, scale: scale)?.0 else { continue }
            let diff = compareImages(original, outImg, tolerance: 16)
            let f = diff.sameSize ? diff.differingFraction : 1
            if f <= 0.02 { buckets[0] += 1 } else if f <= 0.05 { buckets[1] += 1 } else if f <= 0.15 { buckets[2] += 1 } else { buckets[3] += 1 }
        }

        print("""

        === E1b2c corpus-local WMF → EMF (counts only) ===
        scenes imported        : \(scenes)
        exported               : \(exported)
        parse-clean EMF        : \(parseClean)
        re-imported            : \(reimported)
        render ≤2% / ≤5% / ≤15% / >15% : \(buckets[0]) / \(buckets[1]) / \(buckets[2]) / \(buckets[3]) (sampled \(sampled))
        outliers (index only)  : \(outliers.prefix(20).joined(separator: ", "))
        """)

        #expect(exported == scenes, "some WMF→EMF exports failed")
        #expect(parseClean == exported, "some WMF→EMF outputs had diagnostics or wrong counts")
        #expect(reimported == exported, "some WMF→EMF outputs failed to re-import")
    }
}
