import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
import WMFParse
@testable import EMFEdit

/// Slice E1b2c gate: cross-container export (EMF ↔ WMF). An EMF/EMF+/dual scene
/// writes to WMF by full synthesis (every visible element a kind-matched WMF
/// block, in z-order), with a de-duplicated limitations report and the current
/// scene's EMF embedded by default. A WMF scene writes to EMF by full synthesis
/// (or the lossless embedded-EMF route when unedited). Both round-trip: the
/// output parses clean and re-imports.
struct SceneCrossFormatExportTests {

    static let scale: CGFloat = 2
    static let tolerance = 16

    private func importScene(_ name: String) throws -> Scene {
        try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name)))
    }
    private func render(_ data: Data, scale: CGFloat = scale) -> CGImage? {
        guard let opened = try? OpenedMetafile.open(data) else { return nil }
        return MetafileRenderer.makeImage(opened, scale: scale)?.0
    }
    private func pct(_ f: Double) -> String { String(format: "%.3f%%", f * 100) }

    /// EMF fixtures and the WMF-render budget (differing fraction) each tolerates
    /// against the original EMF render. Vector is tight; text and EMF+-only
    /// features are looser (metrics differ across paths; some content flattens).
    private static let emfFixtures: [(name: String, budget: Double)] = [
        // Vector: measured 1.0–1.9% (device rounding + AA across the two render
        // paths); budget 2.5%, in the ≤1–2% band with AA headroom.
        ("gate-p2-house.emf", 0.025),
        ("gate-p2-star.emf", 0.025),
        ("gate-p2-triangles.emf", 0.025),
        ("gate-p3-curves.emf", 0.025),
        ("gate-p3-shapes.emf", 0.025),
        ("handmade-strokes-paths.emf", 0.02),
        ("gate-p4-image.emf", 0.02),
        // Text: metrics differ between the EMF and WMF render paths — looser.
        ("gate-p4-text.emf", 0.08),
        ("handmade-cjk-text.emf", 0.12),
        ("handmade-emfplus-text.emf", 0.06),
        // EMF+-only features flatten in WMF (asserted via the warning list elsewhere):
        // an image re-samples; a gradient fill collapses to one solid (large area diff).
        ("handmade-emfplus-image.emf", 0.10),
        ("handmade-emfplus-shapes.emf", 0.30),
        ("handmade-emfplus-dual.emf", 0.02),
    ]

    private static let wmfFixtures = [
        "gate-wmf-p2-house.wmf",
        "gate-wmf-p2-star.wmf",
        "gate-wmf-p2-triangles.wmf",
        "gate-wmf-p3-curves.wmf",
        "gate-wmf-p3-shapes.wmf",
        "gate-wmf-p4-image.wmf",
        "gate-wmf-p4-image-standard.wmf",
        "gate-wmf-p4-text.wmf",
        "gate-wmf-gdi-p2-house.wmf",
        "gate-wmf-gdi-p3-shapes.wmf",
        "gate-wmf-gdi-p4-text.wmf",
        "handmade-wmf-placeable.wmf",
        "handmade-wmf-standard.wmf",
    ]

    // MARK: - EMF → WMF oracle

    @Test func emfToWMFOracle() throws {
        var report = "\n=== E1b2c EMF → WMF oracle (unedited: WMF vs original EMF) ===\n"
        for (name, budget) in Self.emfFixtures {
            let base = try importScene(name)
            guard let original = render(base.source.data) else { Issue.record("\(name): original render failed"); continue }

            for (label, scene) in editedVariants(base) {
                // Embed OFF: a plain WMF, parse-clean and re-importable.
                let plain = try SceneExporter.export(scene, as: .wmf, options: ExportOptions(embedEMFInWMF: false))
                let wmf = try WMFFile.parse(plain.data)
                #expect(wmf.diagnostics.isEmpty, "\(name) [\(label)]: WMF diagnostics \(wmf.diagnostics)")
                #expect((try? SceneImporter.import(data: plain.data)) != nil, "\(name) [\(label)]: plain WMF did not re-import")
                guard let plainImg = render(plain.data) else { Issue.record("\(name) [\(label)]: WMF render failed"); continue }
                #expect(plainImg.width == original.width && plainImg.height == original.height, "\(name) [\(label)]: WMF canvas != EMF")

                // Budget only on the unedited variant (the edit moves pixels vs the
                // original by design); the edited variant is checked on the embed path.
                if label == "unedited" {
                    let diff = compareImages(original, plainImg, tolerance: Self.tolerance)
                    report += String(format: "%-30@ frac=%@ max=%d warn=%d\n", name, pct(diff.differingFraction), diff.maxChannelDelta, plain.warnings.count)
                    #expect(diff.differingFraction <= budget,
                            "\(name): EMF→WMF render \(pct(diff.differingFraction)) over budget \(pct(budget)); warnings \(plain.warnings)")
                }

                // Embed ON: Emfy recovers the embedded EMF and renders it — ≤0.5% vs
                // the scene's own EMF export (the embedded bytes ARE that export).
                let embedded = try SceneExporter.export(scene, as: .wmf, options: ExportOptions(embedEMFInWMF: true))
                let emfExport = try SceneExporter.export(scene, as: .emf)
                #expect((try? SceneImporter.import(data: embedded.data)) != nil, "\(name) [\(label)]: embedded WMF did not re-import")
                if let embImg = render(embedded.data), let emfImg = render(emfExport.data) {
                    let d2 = compareImages(emfImg, embImg, tolerance: Self.tolerance)
                    #expect(d2.sameSize && d2.differingFraction <= 0.005,
                            "\(name) [\(label)]: WMF(embed) render vs EMF export \(pct(d2.differingFraction)) over 0.5%")
                }
            }
        }
        print(report)
    }

    // MARK: - WMF → EMF oracle

    @Test func wmfToEMFOracle() throws {
        var report = "\n=== E1b2c WMF → EMF oracle ===\n"
        for name in Self.wmfFixtures {
            let base = try importScene(name)
            guard let original = render(base.source.data) else { Issue.record("\(name): original render failed"); continue }

            for (label, scene) in editedVariants(base) {
                let out = try SceneExporter.export(scene, as: .emf)
                let file = try EMFFile.parse(out.data)
                #expect(file.diagnostics.isEmpty, "\(name) [\(label)]: EMF diagnostics \(file.diagnostics)")
                #expect(Int(file.header.records) == file.records.count, "\(name) [\(label)]: header Records mismatch")
                #expect((try? SceneImporter.import(data: out.data)) != nil, "\(name) [\(label)]: EMF did not re-import")
                guard let outImg = render(out.data) else { Issue.record("\(name) [\(label)]: EMF render failed"); continue }

                // Unedited: compare against the WMF original. The geometry is exact in
                // EMF; any residual is passthrough content (raster fills/patterns) that
                // a from-scratch EMF cannot re-synthesise — reported via `contentDropped`.
                // Edited: compare against the scene-model render of the EDITED scene (the
                // edit moves pixels vs the original by design).
                let reference = label == "unedited" ? original : SceneRenderer.makeImage(scene, scale: Self.scale)
                guard let reference else { Issue.record("\(name) [\(label)]: reference render failed"); continue }
                let diff = compareImages(reference, outImg, tolerance: Self.tolerance)
                report += String(format: "%-30@ %-9@ frac=%@ max=%d sameSize=%@ warn=%d\n",
                                 name, label, pct(diff.differingFraction), diff.maxChannelDelta, "\(diff.sameSize)", out.warnings.count)
                #expect(diff.sameSize, "\(name) [\(label)]: EMF render size != reference")
                // Vector exactness: a pure-vector WMF with no dropped content lands under
                // 0.5%. Files whose residual is dropped passthrough get a wider budget and
                // must report `contentDropped`.
                let dropped = out.warnings.contains { if case .contentDropped = $0 { return true }; return false }
                let budget = dropped ? 0.03 : 0.015
                #expect(diff.differingFraction <= budget,
                        "\(name) [\(label)]: WMF→EMF render \(pct(diff.differingFraction)) over budget \(pct(budget)); warnings \(out.warnings)")
            }
        }
        print(report)
    }

    // MARK: - WMF scene + alpha edit → dual EMF (reuses E1b2b)

    @Test func wmfSceneAlphaEditUpgradesToDual() throws {
        let base = try importScene("gate-wmf-p2-house.wmf")
        guard let id = base.editableElements.first(where: { $0.kind != .image && $0.kind != .text })?.id else {
            Issue.record("no vector element in gate-wmf-p2-house"); return
        }
        var scene = base
        try scene.setFill([id], SceneFill(color: SceneColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 0.5), evenOdd: false))
        #expect(SceneExporter.needsEMFPlus(scene), "WMF alpha edit does not need EMF+")
        let out = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(out.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "WMF→dual: diagnostics")
        #expect(file.emfPlusStream().header?.isDual == true, "WMF alpha edit did not upgrade to dual EMF+")
        #expect(file.emfPlusStream().records.contains { $0.isDrawing }, "WMF→dual: no EMF+ drawing records")
        #expect(!out.warnings.contains(.opacityDropped(elementID: id)), "WMF→dual dropped opacity though dual")
        // GDI-only still flattens with a report.
        let flat = try SceneExporter.export(scene, as: .emf, options: ExportOptions(forceGDIOnly: true))
        #expect(flat.warnings.contains(.opacityDropped(elementID: id)), "forced GDI WMF→EMF did not report opacity")
    }

    // MARK: - EMF → WMF reports what WMF cannot hold

    @Test func emfToWMFReportsLimitations() throws {
        // Image opacity: dropped in WMF with a report (the EMF+ bake does not apply).
        let gdiImage = try gdiImageEMF()
        var scene = try SceneImporter.import(data: gdiImage)
        let imageID = try #require(scene.editableElements.first { $0.kind == .image }).id
        try scene.setOpacity([imageID], 0.5)
        let wmf = try SceneExporter.export(scene, as: .wmf)
        #expect(wmf.warnings.contains(.opacityDropped(elementID: imageID)), "WMF image opacity not reported")

        // A gradient fill flattens with a report.
        var gScene = try importScene("gate-p2-house.emf")
        let gid = try #require(gScene.editableElements.first { $0.kind != .image && $0.kind != .text }).id
        let box = try #require(gScene.element(id: gid)).geometryDevice.boundingBox
        let gradient = SceneGradient(
            stops: [.init(location: 0, color: SceneColor(red: 1, green: 0, blue: 0)),
                    .init(location: 1, color: SceneColor(red: 0, green: 0, blue: 1))],
            startDevice: CGPoint(x: box.minX, y: box.midY), endDevice: CGPoint(x: box.maxX, y: box.midY), tilesWrap: false)
        try gScene.setFill([gid], SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false, gradient: gradient))
        let gradWMF = try SceneExporter.export(gScene, as: .wmf)
        #expect(gradWMF.warnings.contains(.gradientFlattened(elementID: gid)), "WMF gradient not reported")

        // The summary groups warnings into user-facing categories.
        let summary = SceneExporter.summarize(gradWMF.warnings)
        #expect(summary[.gradient] != nil, "summary missing the gradient category")
    }

    // MARK: - Interop evidence (opt-in; LibreOffice samples off-repo)

    /// Produces the three cross-format interop files and — when `EMFY_INTEROP_DIR`
    /// is set — writes them (plus their originals) for an external reader to sample.
    /// Always runs the export + structural checks; the file write is opt-in.
    @Test func crossFormatInteropEvidence() throws {
        // (1) EMF → WMF, embed OFF (a plain WMF a down-level reader must draw).
        let emfBase = try importScene("gate-p2-house.emf")
        let emfToWMF = try SceneExporter.export(emfBase, as: .wmf, options: ExportOptions(embedEMFInWMF: false))
        #expect(try WMFFile.parse(emfToWMF.data).diagnostics.isEmpty)

        // (2) WMF → EMF (an EMF a reader must draw).
        let wmfBase = try importScene("gate-wmf-p2-house.wmf")
        let wmfToEMF = try SceneExporter.export(wmfBase, as: .emf)
        #expect(try EMFFile.parse(wmfToEMF.data).diagnostics.isEmpty)

        // (3) A 0.5-opacity image → dual EMF+ (the EMF+ half must blend).
        var imageScene = try SceneImporter.import(data: try gdiImageEMF())
        let imageID = try #require(imageScene.editableElements.first { $0.kind == .image }).id
        try imageScene.setOpacity([imageID], 0.5)
        let opacityEMF = try SceneExporter.export(imageScene, as: .emf)
        #expect(try EMFFile.parse(opacityEMF.data).emfPlusStream().header?.isDual == true)

        if let dir = ProcessInfo.processInfo.environment["EMFY_INTEROP_DIR"] {
            let base = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try emfBase.source.data.write(to: base.appendingPathComponent("emf-to-wmf-original.emf"))
            try emfToWMF.data.write(to: base.appendingPathComponent("emf-to-wmf.wmf"))
            try wmfBase.source.data.write(to: base.appendingPathComponent("wmf-to-emf-original.wmf"))
            try wmfToEMF.data.write(to: base.appendingPathComponent("wmf-to-emf.emf"))
            try opacityEMF.data.write(to: base.appendingPathComponent("image-opacity-dual.emf"))
        }
    }

    // MARK: - Helpers

    /// Two variants: the scene unedited, and with a benign translate on the first
    /// editable element (exercising the edited path without adding alpha/gradient).
    private func editedVariants(_ base: Scene) -> [(String, Scene)] {
        var variants: [(String, Scene)] = [("unedited", base)]
        if let id = base.editableElements.first?.id {
            var edited = base
            if (try? edited.translate([id], dx: 6, dy: 4)) != nil {
                variants.append(("translate", edited))
            }
        }
        return variants
    }

    /// A GDI-only EMF with one STRETCHDIBITS image (no EMF+), built from scratch.
    private func gdiImageEMF() throws -> Data {
        let w = 8, h = 8
        var px: [UInt8] = []
        for row in 0 ..< h { for _ in 0 ..< w { px += row < h / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255] } }
        let dib = DIB(width: Int32(w), height: Int32(h), bitCount: 32, compression: .rgb,
                      content: .pixels(bytes: Data(px), stride: w * 4, palette: []))
        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        try builder.append(.stretchDIBits(StretchDIBitsPayload(
            bounds: RectL(left: 20, top: 20, right: 180, bottom: 180), dest: PointL(x: 20, y: 20),
            destSize: SizeL(cx: 160, cy: 160), src: PointL(x: 0, y: 0), srcSize: SizeL(cx: Int32(w), cy: Int32(h)),
            usageSrc: 0, rasterOperation: 0x00CC_0020, dib: dib)))
        return try builder.finish()
    }
}
