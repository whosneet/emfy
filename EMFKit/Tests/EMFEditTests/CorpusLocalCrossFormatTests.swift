import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
import WMFParse
@testable import EMFEdit

/// Slice E1b2c2 corpus-local sweep (gitignored; may be absent). The structural
/// gate — export → parse-clean → re-import — now covers EVERY EMF/EMZ file,
/// INCLUDING the multi-MB Office files the old sweep skipped (the most realistic
/// inputs), within a ~420 s EMFEdit budget. Render-fidelity comparison stays
/// SAMPLED (an extra pair of full renders per file is the costly part). Work-
/// sourced files are confidential — COUNTS and anonymised indices only.
struct CorpusLocalCrossFormatTests {

    @Test func emfToWMFAcrossLocalCorpus() throws {
        let files = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "emf" || $0.pathExtension.lowercased() == "emz" }
        guard !files.isEmpty else { print("\n=== E1b2c2 corpus-local EMF→WMF: absent (0 files) ==="); return }

        let clock = ContinuousClock()
        var scenes = 0, exported = 0, parseClean = 0, reimported = 0
        var sampled = 0, rendered = 0
        var buckets = [0, 0, 0, 0]   // ≤2%, ≤5%, ≤15%, >15%
        var outliers: [String] = []
        var rasterCount = 0, droppedCount = 0
        // Profiling: cumulative phase times and the slowest files by total time.
        var tImport = Duration.zero, tExport = Duration.zero, tParse = Duration.zero, tReimport = Duration.zero
        var slowest: [(idx: Int, kb: Int, ms: Double)] = []
        // Embed-on probe for the big files (the default path re-exports the EMF and
        // re-embeds it): confirm the probe parses and re-imports, and time it.
        var embedProbed = 0, embedOK = 0
        var embedProbe: [String] = []
        var index = -1

        for url in files {
            let kb = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
            guard let data = try? Data(contentsOf: url) else { continue }
            index += 1
            let fileStart = clock.now

            var base: Scene?
            tImport += clock.measure { base = try? SceneImporter.import(data: data) }
            guard let base else { outliers.append("import#\(index)"); continue }
            scenes += 1

            // Structural gate on EVERY file (embed off → exercises the synthesis).
            var result: ExportResult?
            tExport += clock.measure { result = try? SceneExporter.export(base, as: .wmf, options: ExportOptions(embedEMFInWMF: false)) }
            guard let result else { outliers.append("export#\(index)"); continue }
            exported += 1
            for w in result.warnings {
                if case .contentRasterized = w { rasterCount += 1 }
                if case .contentDropped = w { droppedCount += 1 }
            }
            var wmf: WMFFile?
            tParse += clock.measure { wmf = try? WMFFile.parse(result.data) }
            guard let wmf else { outliers.append("parse#\(index)"); continue }
            if wmf.diagnostics.isEmpty { parseClean += 1 } else { outliers.append("diag#\(index)") }

            var reScene: Scene?
            tReimport += clock.measure { reScene = try? SceneImporter.import(data: result.data) }
            if reScene != nil { reimported += 1 } else { outliers.append("reimport#\(index)") }

            // Embed-on probe on mid-large files (profiles the re-export path without
            // the two multi-MB giants, whose embed cost — a whole-file re-observe,
            // ~30 s for the 14 MB file — is recorded in the slice report, not re-run
            // every suite). The structural gate above already covers EVERY file.
            if kb >= 1024, kb <= 4096 {
                var probe: ExportResult?
                let dt = clock.measure { probe = try? SceneExporter.export(base, as: .wmf) }
                embedProbed += 1
                let ok = probe.flatMap { try? WMFFile.parse($0.data) }?.diagnostics.isEmpty == true
                    && (probe.flatMap { try? SceneImporter.import(data: $0.data) }) != nil
                if ok { embedOK += 1 }
                embedProbe.append("#\(index)(\(kb)KB embed \(Int(dt.seconds * 1000))ms\(ok ? "" : " FAIL"))")
            }

            // Render fidelity on a bounded sample (every 8th file, area-capped).
            if index % 8 == 0 {
                let area = base.pageSizeDevice.width * base.pageSizeDevice.height
                if area <= 4_000_000 {
                    sampled += 1
                    let scale = min(CGFloat(2), CGFloat(900) / max(max(base.pageSizeDevice.width, base.pageSizeDevice.height), 1))
                    if let opened = try? OpenedMetafile.open(data),
                       let original = MetafileRenderer.makeImage(opened, scale: scale)?.0,
                       let outOpened = try? OpenedMetafile.open(result.data),
                       let outImg = MetafileRenderer.makeImage(outOpened, scale: scale)?.0 {
                        rendered += 1
                        let diff = compareImages(original, outImg, tolerance: 16)
                        let f = diff.sameSize ? diff.differingFraction : 1
                        if f <= 0.02 { buckets[0] += 1 } else if f <= 0.05 { buckets[1] += 1 }
                        else if f <= 0.15 { buckets[2] += 1 } else { buckets[3] += 1; outliers.append("render#\(index)=\(String(format: "%.1f%%", f * 100))") }
                    }
                }
            }

            let ms = (clock.now - fileStart).seconds * 1000
            slowest.append((index, kb, ms))
        }
        slowest.sort { $0.ms > $1.ms }

        print("""

        === E1b2c2 corpus-local EMF → WMF (all files, counts only) ===
        files / scenes         : \(files.count) / \(scenes)
        exported / parse-clean : \(exported) / \(parseClean)
        re-imported            : \(reimported)
        rasterised / dropped warnings : \(rasterCount) / \(droppedCount)
        render sample ≤2/≤5/≤15/>15% : \(buckets[0]) / \(buckets[1]) / \(buckets[2]) / \(buckets[3]) (sampled \(sampled), rendered \(rendered))
        phase totals (s)       : import \(fmt(tImport)) export \(fmt(tExport)) parse \(fmt(tParse)) reimport \(fmt(tReimport))
        embed-on probe (≥1MB)  : \(embedOK)/\(embedProbed) ok — \(embedProbe.joined(separator: ", "))
        slowest files          : \(slowest.prefix(6).map { "#\($0.idx)(\($0.kb)KB \(Int($0.ms))ms)" }.joined(separator: ", "))
        outliers (index only)  : \(outliers.prefix(20).joined(separator: ", "))
        """)

        #expect(exported == scenes, "some EMF→WMF exports failed")
        #expect(parseClean == exported, "some EMF→WMF outputs had WMF diagnostics")
        #expect(reimported == exported, "some EMF→WMF outputs failed to re-import")
        #expect(embedOK == embedProbed, "an embed-on probe failed to parse or re-import")
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

/// Seconds as a Double, for the profiling print.
private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
private func fmt(_ d: Duration) -> String { String(format: "%.1f", d.seconds) }
