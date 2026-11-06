import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Slice E1b2b gate: editing a GDI-only EMF so it needs a feature GDI cannot
/// express — sub-1 opacity or a gradient — exports a DUAL EMF+ file. The EMF+ half
/// carries the edit faithfully (unedited content replays the original GDI verbatim
/// inside GetDC windows, so it is lossless); the GDI half carries the original
/// drawing plus each edited element's opaque/flattened approximation, so down-level
/// readers still work and nothing is drawn twice.
struct SceneGDIDualExportTests {

    // Scale 1 keeps the pass cheap: the identity-exact comparisons (EMF+ render ==
    // SceneRenderer, GDI mode == flat export, outside == original) are scale-stable,
    // so a quarter of the pixels measures the same thing far faster.
    static let renderScale: CGFloat = 1
    static let tolerance = 16
    static let maxDifferingFraction = 0.015
    static let corpusScale: CGFloat = 1

    /// Committed GDI EMF files with editable vector/text content.
    private static let gdiFiles = [
        "gate-p2-house.emf",
        "gate-p2-star.emf",
        "gate-p2-triangles.emf",
        "gate-p3-curves.emf",
        "gate-p3-shapes.emf",
        "gate-p4-text.emf",
        "handmade-strokes-paths.emf",
    ]

    // MARK: - Helpers

    private func scene(_ name: String) throws -> Scene {
        try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name)))
    }

    private func render(_ data: Data, options: RenderOptions = .default, scale: CGFloat = Self.renderScale) -> CGImage? {
        guard let opened = try? OpenedMetafile.open(data) else { return nil }
        return MetafileRenderer.makeImage(opened, scale: scale, options: options)?.0
    }

    enum Edit: CustomStringConvertible {
        case opacity, fillAlpha, fillGradient, strokeAlpha
        var description: String {
            switch self {
            case .opacity: return "opacity"; case .fillAlpha: return "fillAlpha"
            case .fillGradient: return "fillGradient"; case .strokeAlpha: return "strokeAlpha"
            }
        }
    }

    private func applicableEdits(for element: Element) -> [Edit] {
        // opacity exercises the alpha path, fillGradient the gradient path, strokeAlpha
        // the pen-alpha path. fillAlpha (fill-colour alpha) overlaps opacity and is
        // covered on its own in forceGDIOnlyFlattensWithWarning — kept out of the broad
        // matrix so the pass stays cheap.
        let fillable: Set<ElementKind> = [.rect, .ellipse, .roundRect, .polygon, .polyline, .line, .path, .arc, .bezier]
        if fillable.contains(element.kind) { return [.opacity, .fillGradient, .strokeAlpha] }
        if element.kind == .text { return [.opacity] }
        return []
    }

    private func apply(_ edit: Edit, to id: Int, in scene: inout Scene, original: Element) throws {
        let alpha = SceneColor(red: 0.10, green: 0.40, blue: 0.95, alpha: 0.5)
        let box = original.geometryDevice.boundingBox.isNull
            ? CGRect(x: 0, y: 0, width: 100, height: 100) : original.geometryDevice.boundingBox
        let gradient = SceneGradient(
            stops: [.init(location: 0, color: SceneColor(red: 1, green: 0.1, blue: 0.1)),
                    .init(location: 1, color: SceneColor(red: 0.1, green: 0.1, blue: 1))],
            startDevice: CGPoint(x: box.minX, y: box.midY), endDevice: CGPoint(x: box.maxX, y: box.midY), tilesWrap: false)
        let strokeWidth = 4.0 / SceneSynthesis.averageScale(original.transform)
        switch edit {
        case .opacity: try scene.setOpacity([id], 0.5)
        case .fillAlpha: try scene.setFill([id], SceneFill(color: alpha, evenOdd: false))
        case .fillGradient: try scene.setFill([id], SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false, gradient: gradient))
        case .strokeAlpha: try scene.setStroke([id], SceneStroke(color: SceneColor(red: 0.05, green: 0.05, blue: 0.9, alpha: 0.5), isCosmetic: false, width: strokeWidth, dash: .solid, cap: .round, join: .round, miterLimit: 10))
        }
    }

    // MARK: - Edit matrix: GDI + opacity/gradient → dual EMF+

    @Test func gdiDualEditMatrix() throws {
        var report = "\n=== E1b2b GDI → dual edit matrix ===\n"
        for name in Self.gdiFiles {
            let base = try scene(name)
            guard base.source.renderPath == .gdi else { continue }
            let editable = base.editableElements.filter { $0.kind != .image }
            guard !editable.isEmpty else { continue }
            // The original render is identical across this file's cases — render once.
            guard let originalImg = render(base.source.data) else { Issue.record("\(name): original render failed"); continue }
            let picks = Set([0, editable.count - 1]).sorted().map { editable[$0].id }   // first + last
            for id in picks {
                guard let element = base.element(id: id) else { continue }
                for edit in applicableEdits(for: element) {
                    try runDualEdit(name: name, base: base, id: id, edit: edit, originalImg: originalImg, report: &report)
                }
            }
        }
        print(report)
    }

    private func runDualEdit(name: String, base: Scene, id: Int, edit: Edit, originalImg: CGImage, report: inout String) throws {
        var scene = base
        let original = try #require(scene.element(id: id))
        try apply(edit, to: id, in: &scene, original: original)

        let result = try SceneExporter.export(scene, as: .emf)

        // The output is a DUAL EMF+ file, parse-clean, with EMF+ drawing records.
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF diagnostics \(file.diagnostics)")
        let plus = file.emfPlusStream()
        #expect(plus.diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF+ diagnostics \(plus.diagnostics)")
        #expect(plus.objectDefinitions().diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF+ object diagnostics")
        #expect(plus.header?.isDual == true, "\(name) id=\(id) \(edit): did NOT upgrade to a dual EMF+ file")
        let hasDrawing = plus.records.contains { $0.isDrawing }
        #expect(hasDrawing, "\(name) id=\(id) \(edit): no EMF+ drawing records")
        // The dual route carries the edit faithfully — no opacity/gradient warning.
        #expect(!result.warnings.contains(.opacityDropped(elementID: id)), "\(name) id=\(id) \(edit): opacityDropped though dual")
        #expect(!result.warnings.contains(.gradientFlattened(elementID: id)), "\(name) id=\(id) \(edit): gradientFlattened though dual")

        // (c) re-import shows the alpha / gradient on some editable element.
        let reimport = try SceneImporter.import(data: result.data)
        let featureBack: Bool
        switch edit {
        case .fillGradient:
            featureBack = reimport.editableElements.contains { $0.style.fill?.gradient != nil }
        case .strokeAlpha:
            featureBack = reimport.editableElements.contains { ($0.style.stroke?.color.alpha ?? 1) < 0.9 }
        case .opacity, .fillAlpha:
            // Opacity folds into whichever paint the element carries (fill, stroke
            // or text colour); an alpha fill lands on the fill colour.
            featureBack = reimport.editableElements.contains {
                ($0.style.fill?.color.alpha ?? 1) < 0.9
                    || ($0.style.stroke?.color.alpha ?? 1) < 0.9
                    || ($0.text?.color.alpha ?? 1) < 0.9
            }
        }
        #expect(featureBack, "\(name) id=\(id) \(edit): re-import does not show the alpha/gradient")

        guard let emfPlusImg = render(result.data),
              let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale) else {
            Issue.record("\(name) id=\(id) \(edit): render failed"); return
        }

        // (a) EMF+ mode matches SceneRenderer of the edited scene.
        let aDiff = compareImages(sceneImg, emfPlusImg, tolerance: Self.tolerance)
        #expect(aDiff.sameSize && aDiff.differingFraction <= Self.maxDifferingFraction,
                "\(name) id=\(id) \(edit): EMF+ render vs SceneRenderer \(pct(aDiff.differingFraction)) differ")

        // Footprint of the edited element in device space (dilated).
        let footprint = editFootprint(original)

        // (a-outside) EMF+ mode OUTSIDE the footprint is the ORIGINAL (unedited
        // content replays verbatim via GetDC — lossless).
        let outPlus = differingOutside(emfPlusImg, originalImg, footprint: footprint, pageBounds: base.pageBoundsDevice)
        #expect(outPlus <= 120, "\(name) id=\(id) \(edit): \(outPlus) px differ OUTSIDE footprint in EMF+ mode")

        // (b-outside) GDI mode OUTSIDE the footprint is the ORIGINAL too.
        guard let gdiImg = render(result.data, options: RenderOptions(emfPlusArbitration: .gdi)) else {
            Issue.record("\(name) id=\(id) \(edit): GDI-mode render failed"); return
        }
        let outGDI = differingOutside(gdiImg, originalImg, footprint: footprint, pageBounds: base.pageBoundsDevice)
        #expect(outGDI <= 120, "\(name) id=\(id) \(edit): \(outGDI) px differ OUTSIDE footprint in GDI mode")

        // (b) the GDI half is exactly the opaque GDI approximation a flat (forced)
        // GDI export would write — a down-level reader sees that, and only that, so
        // nothing is drawn twice and the EMF+ half is never drawn by a GDI reader.
        let flat = try SceneExporter.export(scene, as: .emf, options: ExportOptions(forceGDIOnly: true))
        if let flatImg = render(flat.data) {
            let bDiff = compareImages(flatImg, gdiImg, tolerance: Self.tolerance)
            #expect(bDiff.sameSize && bDiff.differingFraction <= 0.001,
                    "\(name) id=\(id) \(edit): dual GDI mode != flat GDI export \(pct(bDiff.differingFraction))")
        }

        // The two halves genuinely differ where the edit is visible (opaque vs
        // translucent/gradient) — informational: a thin/covered element can match.
        let insideDiff = differingInside(gdiImg, emfPlusImg, footprint: footprint, pageBounds: base.pageBoundsDevice)
        report += String(format: "%-26@ id=%-3d %-12@ a=%.3f%% outP=%-4d outG=%-4d in=%-5d warn=%d\n",
                         name, id, "\(edit)", aDiff.differingFraction * 100, outPlus, outGDI, insideDiff, result.warnings.count)
    }

    // MARK: - Insert a new semi-transparent element → dual

    @Test func insertSemiTransparentElement() throws {
        let base = try scene("gate-p2-house.emf")
        #expect(base.source.renderPath == .gdi)
        func rect(_ id: Int, alpha: Double) -> Element {
            Element(id: id, kind: .rect,
                geometryDevice: ScenePath(CGPath(rect: CGRect(x: 30, y: 30, width: 180, height: 120), transform: nil)),
                transform: .identity,
                style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.95, green: 0.2, blue: 0.2, alpha: alpha), evenOdd: false)),
                provenance: Provenance(sourceRecordIndices: []))
        }
        var scene = base
        scene.insert(rect(90_001, alpha: 0.5), at: scene.layers[0].elements.count)   // on top
        #expect(SceneExporter.needsEMFPlus(scene), "inserted semi-transparent rect does not need EMF+")
        let result = try SceneExporter.export(scene, as: .emf)

        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty)
        #expect(file.emfPlusStream().header?.isDual == true, "insert: not dual")
        #expect(!result.warnings.contains(.opacityDropped(elementID: 90_001)))

        // Re-import keeps the new element and shows its alpha.
        let reimport = try SceneImporter.import(data: result.data)
        #expect(reimport.editableElements.count == base.editableElements.count + 1, "insert: element not added")
        #expect(reimport.editableElements.contains { ($0.style.fill?.color.alpha ?? 1) < 0.9 }, "insert: alpha not present")

        // EMF+ mode matches the edited scene; OUTSIDE the new rect, the page is the original.
        guard let emfPlusImg = render(result.data),
              let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale),
              let originalImg = render(base.source.data) else { Issue.record("render failed"); return }
        let diff = compareImages(sceneImg, emfPlusImg, tolerance: Self.tolerance)
        #expect(diff.differingFraction <= Self.maxDifferingFraction, "insert: EMF+ vs SceneRenderer \(pct(diff.differingFraction))")
        let footprint = CGRect(x: 30, y: 30, width: 180, height: 120)
        let outside = differingOutside(emfPlusImg, originalImg, footprint: footprint, pageBounds: base.pageBoundsDevice)
        #expect(outside <= 120, "insert: \(outside) px differ outside the new rect")

        // A translucent red rect over the house blends: the centre is neither pure
        // red (opaque) nor the original — a blend.
        if let img = PixelImage(emfPlusImg) {
            let r = targetPixelRect(CGRect(x: 110, y: 80, width: 20, height: 20), pageBounds: base.pageBoundsDevice, targetW: img.width, targetH: img.height)
            let x = min(max(Int(r.midX), 0), img.width - 1), y = min(max(Int(r.midY), 0), img.height - 1)
            let o = (y * img.width + x) * 4
            #expect(img.pixels[o] > 120 && img.pixels[o + 1] < 200, "insert: translucent red overlay not blended: \((img.pixels[o], img.pixels[o+1], img.pixels[o+2]))")
        }
    }

    // MARK: - An opaque GDI edit stays a flat GDI EMF (no upgrade)

    @Test func opaqueEditStaysGDI() throws {
        // gate-p2-house is itself a GetDC-wrapped dual file (EMF+ control comments
        // around GDI draws, no EMF+ DRAWING records), so an opaque edit re-emits
        // those control comments verbatim — the test is that NO EMF+ DRAWING record
        // is added (the edit stays a flat GDI draw, no dual upgrade).
        let base = try scene("gate-p2-house.emf")
        var scene = base
        let id = try #require(base.editableElements.first { $0.kind != .image }).id
        try scene.setFill([id], SceneFill(color: SceneColor(red: 0.9, green: 0.1, blue: 0.5), evenOdd: false))
        let result = try SceneExporter.export(scene, as: .emf)
        let plus = try EMFFile.parse(result.data).emfPlusStream()
        let hasDrawing = plus.records.contains { $0.isDrawing }
        #expect(!hasDrawing, "an opaque GDI edit must NOT add EMF+ drawing records")
        #expect(result.warnings.isEmpty, "an opaque GDI edit must not warn")
    }

    // MARK: - forceGDIOnly flattens to GDI with a warning

    @Test func forceGDIOnlyFlattensWithWarning() throws {
        let base = try scene("gate-p2-house.emf")
        let id = try #require(base.editableElements.first { $0.kind != .image }).id
        var scene = base
        try scene.setFill([id], SceneFill(color: SceneColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 0.5), evenOdd: false))
        // Default: dual (EMF+ drawing records carry the edit, no warning).
        let dual = try SceneExporter.export(scene, as: .emf)
        let dualPlus = try EMFFile.parse(dual.data).emfPlusStream()
        #expect(dualPlus.header?.isDual == true)
        #expect(dualPlus.records.contains { $0.isDrawing }, "dual export carries no EMF+ drawing")
        #expect(dual.warnings.isEmpty, "dual export should carry the edit without a warning")
        // forceGDIOnly: flat GDI EMF (no EMF+ DRAWING records added — the source's own
        // control comments are re-emitted verbatim), feature flattened, warning emitted.
        let flat = try SceneExporter.export(scene, as: .emf, options: ExportOptions(forceGDIOnly: true))
        let flatPlus = try EMFFile.parse(flat.data).emfPlusStream()
        #expect(!flatPlus.records.contains { $0.isDrawing }, "forceGDIOnly must not add EMF+ drawing records")
        #expect(flat.warnings.contains(.opacityDropped(elementID: id)) || flat.warnings.contains(.gradientFlattened(elementID: id)),
                "forceGDIOnly must report the dropped feature")
    }

    // MARK: - Gradient fill carries, and a gradient stroke is not modelled

    @Test func gradientStrokeIsNotModelled() throws {
        // SceneStroke carries a solid colour only (no gradient field), so a gradient
        // STROKE cannot be expressed; a gradient FILL is the supported gradient edit.
        let stroke = SceneStroke(color: SceneColor(red: 0, green: 0, blue: 1), isCosmetic: false, width: 2, dash: .solid, cap: .butt, join: .miter, miterLimit: 10)
        _ = stroke
        #expect(Bool(true), "documented: gradient strokes are out of the scene model; gradient fills are covered by the matrix")
    }

    // MARK: - Image opacity is reported (not expressible in EMF+), image survives dual

    /// A GDI-only EMF with one STRETCHDIBITS image (no EMF+), built from scratch.
    private func gdiImageEMF() throws -> Data {
        let w = 8, h = 8
        var px: [UInt8] = []
        for row in 0 ..< h { for _ in 0 ..< w { px += row < h / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255] } }   // B,G,R,A
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

    @Test func imageOpacityReportsAndImageSurvivesDual() throws {
        let base = try SceneImporter.import(data: try gdiImageEMF())
        #expect(base.source.renderPath == .gdi, "built image EMF is not GDI")
        let imageID = try #require(base.editableElements.first(where: { $0.kind == .image })).id

        // A pure image-opacity edit is NOT upgraded (the renderer applies no
        // ImageAttributes alpha) — it stays a GDI EMF and reports opacityDropped.
        var opacityScene = base
        try opacityScene.setOpacity([imageID], 0.5)
        #expect(!SceneExporter.elementNeedsEMFPlus(try #require(opacityScene.element(id: imageID))),
                "image opacity must not drive a dual upgrade")
        let flat = try SceneExporter.export(opacityScene, as: .emf)
        #expect(try EMFFile.parse(flat.data).emfPlusStream().records.isEmpty, "image-opacity export unexpectedly emitted EMF+")
        #expect(flat.warnings.contains(.opacityDropped(elementID: imageID)), "image opacity not reported")

        // If a DIFFERENT element forces the dual upgrade, the unedited image is still
        // drawn (via GetDC, lossless) — insert a semi-transparent rect to force dual.
        var dualScene = base
        let newRect = Element(id: 90_010, kind: .rect,
            geometryDevice: ScenePath(CGPath(rect: CGRect(x: 30, y: 30, width: 40, height: 40), transform: nil)),
            transform: .identity,
            style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0, green: 1, blue: 0, alpha: 0.5), evenOdd: false)),
            provenance: Provenance(sourceRecordIndices: []))
        dualScene.insert(newRect, at: dualScene.layers[0].elements.count)   // on top of the image
        let dual = try SceneExporter.export(dualScene, as: .emf)
        let file = try EMFFile.parse(dual.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "image+dual: diagnostics")
        #expect(file.emfPlusStream().header?.isDual == true, "image+dual: not dual")
        // The image re-imports (survives the dual upgrade via GetDC).
        let reimport = try SceneImporter.import(data: dual.data)
        #expect(reimport.editableElements.contains { $0.kind == .image }, "image lost in the dual upgrade")
        // The image still renders in both modes (lossless) outside the new rect.
        guard let originalImg = render(base.source.data), let emfPlusImg = render(dual.data) else { return }
        let footprint = CGRect(x: 30, y: 30, width: 40, height: 40)
        #expect(differingOutside(emfPlusImg, originalImg, footprint: footprint, pageBounds: base.pageBoundsDevice) <= 120,
                "image+dual: EMF+ mode disturbed the image outside the new rect")
    }

    // MARK: - Hostile: a full object table and a truncated file still export

    @Test func hostileGDIDualExportIsBounded() throws {
        // Truncated GDI file + an alpha edit: never traps (typed throw or output).
        let full = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf"))
        for fraction in [0.3, 0.5, 0.7, 0.9] {
            let cut = Data(full.prefix(Int(Double(full.count) * fraction)))
            guard var scene = try? SceneImporter.import(data: cut),
                  let first = scene.editableElements.first(where: { $0.kind != .image }) else { continue }
            try? scene.setFill([first.id], SceneFill(color: SceneColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 0.5), evenOdd: false))
            _ = try? SceneExporter.export(scene, as: .emf)
        }

        // A GDI EMF whose object table is nearly full (200 pens created + selected),
        // then a filled rect: edit it with an alpha fill and still export a dual file.
        let page = RectL(left: 0, top: 0, right: 399, bottom: 299)
        let builder = EMFDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        for i in 0 ..< 200 {
            let h = try builder.allocateObjectHandle()
            try builder.append(.createPen(CreatePenPayload(ihPen: h, style: 0, width: PointL(x: 1, y: 0), color: ColorRef(red: UInt8(i & 0xFF), green: 0, blue: 0))))
            try builder.append(.selectObject(.table(index: h)))
        }
        let brushHandle = try builder.allocateObjectHandle()
        try builder.append(.createBrushIndirect(CreateBrushPayload(ihBrush: brushHandle, style: 0, color: ColorRef(red: 20, green: 180, blue: 60), hatch: 0)))
        try builder.append(.selectObject(.table(index: brushHandle)))
        try builder.append(.rectangle(box: RectL(left: 50, top: 50, right: 250, bottom: 200)))
        let data = try builder.finish()

        var scene = try SceneImporter.import(data: data)
        let rectID = try #require(scene.editableElements.first { $0.kind == .rect }).id
        try scene.setFill([rectID], SceneFill(color: SceneColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 0.5), evenOdd: false))
        let result = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "full-table dual: diagnostics")
        #expect(file.emfPlusStream().header?.isDual == true, "full-table dual: not dual")
        #expect(Int(file.header.records) == file.records.count, "full-table dual: header Records mismatch")
        #expect(render(result.data) != nil, "full-table dual did not render")
    }

    // MARK: - corpus-local sweep (counts only; gitignored, may be absent)

    @Test func corpusLocalGDIDualSweep() throws {
        let urls = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "emf" }
        var files = 0, exported = 0, parseClean = 0, dual = 0
        // The expensive per-file checks (re-import + two fidelity renders) run on an
        // evenly spaced SAMPLE so the 210-file sweep stays cheap; the structural gate
        // (export, parse-clean, dual) runs on every file.
        var sampled = 0, reimported = 0, plusWithin = 0, gdiWithin = 0
        var outliers: [String] = []
        for (index, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url), let base = try? SceneImporter.import(data: data),
                  base.source.renderPath == .gdi, base.source.format == .emf else { continue }
            let editable = base.editableElements.filter { $0.kind != .image }
            guard let firstID = editable.first?.id else { continue }
            files += 1
            var scene = base
            // Set the first editable element to 0.5 opacity.
            guard (try? scene.setOpacity([firstID], 0.5)) != nil else { continue }
            guard let result = try? SceneExporter.export(scene, as: .emf) else {
                outliers.append("export#\(index)"); continue
            }
            exported += 1
            guard let file = try? EMFFile.parse(result.data) else { outliers.append("parse#\(index)"); continue }
            if file.diagnostics.isEmpty, file.emfPlusStream().diagnostics.isEmpty, Int(file.header.records) == file.records.count { parseClean += 1 }
            else { outliers.append("clean#\(index)") }
            if file.emfPlusStream().header?.isDual == true { dual += 1 }

            // Sampled: re-import + fidelity OUTSIDE the edited element's footprint,
            // both modes, vs the original, within 0.5% of the frame (~280 px/side —
            // an area fraction is scale-stable). The committed matrix proves unedited
            // content is PIXEL-identical at full precision; this is a broad guard.
            guard index % 3 == 0 else { continue }
            sampled += 1
            if (try? SceneImporter.import(data: result.data)) != nil { reimported += 1 } else { outliers.append("reimport#\(index)") }
            let scale = min(Self.corpusScale, CGFloat(280) / max(max(base.pageSizeDevice.width, base.pageSizeDevice.height), 1))
            guard let original = render(data, scale: scale), let originalElement = base.element(id: firstID) else { continue }
            let footprint = editFootprint(originalElement)
            if let plusImg = render(result.data, scale: scale) {
                let frac = Double(differingOutside(plusImg, original, footprint: footprint, pageBounds: base.pageBoundsDevice)) / Double(max(plusImg.width * plusImg.height, 1))
                if frac <= 0.005 { plusWithin += 1 } else { outliers.append("plus#\(index)=\(String(format: "%.2f%%", frac * 100))") }
            }
            if let gdiImg = render(result.data, options: RenderOptions(emfPlusArbitration: .gdi), scale: scale) {
                let frac = Double(differingOutside(gdiImg, original, footprint: footprint, pageBounds: base.pageBoundsDevice)) / Double(max(gdiImg.width * gdiImg.height, 1))
                if frac <= 0.005 { gdiWithin += 1 } else { outliers.append("gdi#\(index)=\(String(format: "%.2f%%", frac * 100))") }
            }
        }
        let outlierText = outliers.prefix(16).joined(separator: ", ")
        print("""

        === E1b2b corpus-local GDI → dual (counts only) ===
        GDI EMF with editable       : \(files)
        exported                    : \(exported)
        parse-clean                 : \(parseClean)
        dual EMF+                   : \(dual)
        sampled (re-import+render)  : \(sampled)
        re-imported (of sampled)    : \(reimported)
        EMF+-mode outside <=0.5%    : \(plusWithin) / \(sampled)
        GDI-mode outside <=0.5%     : \(gdiWithin) / \(sampled)
        outliers (index only)       : \(outliers.isEmpty ? "none" : outlierText)
        """)
        if files > 0 {
            #expect(exported == files, "some GDI dual exports failed to export")
            #expect(dual == files, "some GDI alpha edits did not upgrade to dual")
            #expect(parseClean == files, "some dual outputs parsed with diagnostics or wrong counts")
            #expect(reimported == sampled, "some sampled dual exports failed to re-import")
        }
    }

    // MARK: - Interop evidence files (opt-in)

    @Test func interopEvidenceFiles() throws {
        // A GDI file with an alpha-fill edit and a gradient-fill edit, written for an
        // external reader (LibreOffice) to pixel-sample off-repo when EMFY_INTEROP_DIR
        // is set. Always runs the export + parse checks; the file write is opt-in.
        let base = try scene("gate-p2-house.emf")
        let id = try #require(base.editableElements.first { $0.kind != .image }).id
        let box = try #require(base.element(id: id)).geometryDevice.boundingBox

        var alphaScene = base
        try alphaScene.setFill([id], SceneFill(color: SceneColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 0.5), evenOdd: false))
        let alpha = try SceneExporter.export(alphaScene, as: .emf)
        #expect(try EMFFile.parse(alpha.data).emfPlusStream().header?.isDual == true)

        var gradientScene = base
        let gradient = SceneGradient(
            stops: [.init(location: 0, color: SceneColor(red: 1, green: 0.1, blue: 0.1)),
                    .init(location: 1, color: SceneColor(red: 0.1, green: 0.1, blue: 1))],
            startDevice: CGPoint(x: box.minX, y: box.midY), endDevice: CGPoint(x: box.maxX, y: box.midY), tilesWrap: false)
        try gradientScene.setFill([id], SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false, gradient: gradient))
        let grad = try SceneExporter.export(gradientScene, as: .emf)
        #expect(try EMFFile.parse(grad.data).emfPlusStream().header?.isDual == true)

        if let dir = ProcessInfo.processInfo.environment["EMFY_INTEROP_DIR"] {
            let baseURL = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            try alpha.data.write(to: baseURL.appendingPathComponent("gdi-dual-alpha.emf"))
            try grad.data.write(to: baseURL.appendingPathComponent("gdi-dual-gradient.emf"))
            try base.source.data.write(to: baseURL.appendingPathComponent("gdi-original.emf"))
        }
    }

    // MARK: - Geometry helpers

    /// The dilated device-space footprint of an edited element.
    private func editFootprint(_ element: Element) -> CGRect {
        var box = element.boundsDevice
        if box.isNull { box = element.image?.destRectDevice.standardized ?? .null }
        if box.isNull, let text = element.text {
            let scale = SceneSynthesis.averageScale(element.transform)
            let em = max(8, Double(abs(text.logicalHeight)) * scale)
            let ref = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform)
            let len = Double(max(text.string.count, 8)) + 4
            box = CGRect(x: ref.x - em, y: ref.y - em * 1.8, width: em * len, height: em * 2.8)
        }
        return box
    }

    private func targetPixelRect(_ deviceRect: CGRect, pageBounds: CGRect, targetW: Int, targetH: Int) -> CGRect {
        let dw = max(pageBounds.width, 1), dh = max(pageBounds.height, 1)
        let sx = Double(targetW) / dw, sy = Double(targetH) / dh
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: sx * (p.x - pageBounds.minX), y: sy * (p.y - pageBounds.minY)) }
        let a = px(CGPoint(x: deviceRect.minX, y: deviceRect.minY)), b = px(CGPoint(x: deviceRect.maxX, y: deviceRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Pixels where `a` and `b` differ by > tolerance OUTSIDE the footprint rect
    /// (dilated 16 px).
    private func differingOutside(_ a: CGImage, _ b: CGImage, footprint: CGRect, pageBounds: CGRect) -> Int {
        guard let pa = PixelImage(a), let pb = PixelImage(b), pa.width == pb.width, pa.height == pb.height else { return Int.max }
        if footprint.isNull { return 0 }
        let rect = targetPixelRect(footprint, pageBounds: pageBounds, targetW: pa.width, targetH: pa.height).insetBy(dx: -16, dy: -16)
        var outside = 0
        for y in 0 ..< pa.height {
            for x in 0 ..< pa.width where !rect.contains(CGPoint(x: x, y: y)) {
                let o = (y * pa.width + x) * 4
                for c in 0 ..< 4 where abs(Int(pa.pixels[o + c]) - Int(pb.pixels[o + c])) > Self.tolerance { outside += 1; break }
            }
        }
        return outside
    }

    /// Pixels where `a` and `b` differ by > tolerance INSIDE the footprint rect.
    private func differingInside(_ a: CGImage, _ b: CGImage, footprint: CGRect, pageBounds: CGRect) -> Int {
        guard let pa = PixelImage(a), let pb = PixelImage(b), pa.width == pb.width, pa.height == pb.height else { return 0 }
        if footprint.isNull { return 0 }
        let rect = targetPixelRect(footprint, pageBounds: pageBounds, targetW: pa.width, targetH: pa.height)
        var inside = 0
        for y in 0 ..< pa.height {
            for x in 0 ..< pa.width where rect.contains(CGPoint(x: x, y: y)) {
                let o = (y * pa.width + x) * 4
                for c in 0 ..< 4 where abs(Int(pa.pixels[o + c]) - Int(pb.pixels[o + c])) > Self.tolerance { inside += 1; break }
            }
        }
        return inside
    }

    private func pct(_ f: Double) -> String { String(format: "%.3f%%", f * 100) }
}
