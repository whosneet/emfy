import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Slice E1b2a gate: editing an EMF+ (or dual) file exports a lossless EMF+
/// overlay — unedited records verbatim, edited elements replaced in place, new
/// elements inserted at z, images written as compressed-PNG EmfPlusBitmaps, the
/// GDI object slots restored, and (dual) a regenerated GDI fallback.
struct SceneEMFPlusExportTests {

    static let renderScale: CGFloat = 2
    static let tolerance = 16
    static let maxDifferingFraction = 0.015
    static let maxMeanDelta = 2.0

    private static let emfPlusFiles = [
        "handmade-emfplus-shapes.emf",
        "handmade-emfplus-text.emf",
        "handmade-emfplus-image.emf",
        "handmade-emfplus-dual.emf",
    ]

    private func scene(_ name: String) throws -> Scene {
        try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name)))
    }
    private func render(_ data: Data, options: RenderOptions = .default, scale: CGFloat = Self.renderScale) -> CGImage? {
        guard let opened = try? OpenedMetafile.open(data) else { return nil }
        return MetafileRenderer.makeImage(opened, scale: scale, options: options)?.0
    }
    /// The corpus-local identity sweep renders at a lower scale than the committed
    /// oracle: a quarter of the pixels (scale 1 vs 2) keeps the confidential-file
    /// sweep well under budget without changing what it measures (an area-fraction
    /// diff is scale-stable), and the committed oracle keeps full precision.
    static let corpusScale: CGFloat = 1

    // MARK: - Unchanged EMF+ re-emits byte-identically

    @Test(arguments: emfPlusFiles)
    func unchangedEMFPlusReEmitsByteIdentical(_ name: String) throws {
        let scene = try scene(name)
        let result = try SceneExporter.export(scene, as: .emf)
        let expected = try EMFDocumentWriter.reEmit(try EMFFile.parse(scene.source.data), source: scene.source.data)
        #expect(result.data == expected, "\(name): unchanged EMF+ export != reEmit")
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Edit matrix

    enum Edit: CustomStringConvertible {
        case delete, translate, fillOpaque, fillAlpha, fillGradient, stroke, text
        var description: String {
            switch self {
            case .delete: return "delete"; case .translate: return "translate"
            case .fillOpaque: return "fillOpaque"; case .fillAlpha: return "fillAlpha"
            case .fillGradient: return "fillGradient"; case .stroke: return "stroke"; case .text: return "setText"
            }
        }
    }

    @Test func emfPlusEditMatrix() throws {
        var report = "\n=== E1b2a EMF+ edit matrix ===\n"
        for name in Self.emfPlusFiles {
            let base = try scene(name)
            let editable = base.editableElements
            guard !editable.isEmpty else { continue }
            // A dual file's GetDC-window GDI elements can't carry alpha/gradient
            // (GDI is opaque, solid), so the edit set and re-import checks adapt.
            let gdiIDs = gdiElementIDs(base)
            let picks = Set([0, editable.count / 2, editable.count - 1]).sorted().map { editable[$0].id }
            for id in picks {
                guard let element = base.element(id: id) else { continue }
                for edit in applicableEdits(for: element, isGDI: gdiIDs.contains(id)) {
                    try runEdit(name: name, base: base, id: id, edit: edit, report: &report)
                }
            }
        }
        print(report)
    }

    /// The editable element ids whose EMF+ playback entry is a GetDC-window GDI
    /// draw (opaque GDI, not EMF+), so the test does not expect alpha/gradients on
    /// them.
    private func gdiElementIDs(_ scene: Scene) -> Set<Int> {
        guard let opened = try? OpenedMetafile.open(scene.source.data), let prepared = MetafileRenderer.prepare(opened) else { return [] }
        var ids: Set<Int> = []
        for (id, entry) in MetafileRenderer.observe(prepared).plusEntries.enumerated() {
            if case .gdi = entry { ids.insert(id) }
        }
        return ids
    }

    private func applicableEdits(for element: Element, isGDI: Bool) -> [Edit] {
        var edits: [Edit] = [.delete, .translate]
        let fillable: Set<ElementKind> = [.rect, .ellipse, .polygon, .polyline, .line, .path, .arc, .bezier]
        if fillable.contains(element.kind) {
            edits += isGDI ? [.fillOpaque, .stroke] : [.fillOpaque, .fillAlpha, .fillGradient, .stroke]
        }
        if element.kind == .text { edits += [.fillOpaque, .text] }
        return edits
    }

    private func runEdit(name: String, base: Scene, id: Int, edit: Edit, report: inout String) throws {
        var scene = base
        let original = try #require(scene.element(id: id))
        let opaque = SceneColor(red: 0.90, green: 0.12, blue: 0.55)
        let alpha = SceneColor(red: 0.10, green: 0.40, blue: 0.95, alpha: 0.5)
        let box = original.geometryDevice.boundingBox.isNull ? CGRect(x: 0, y: 0, width: 100, height: 100) : original.geometryDevice.boundingBox
        let gradient = SceneGradient(
            stops: [.init(location: 0, color: SceneColor(red: 1, green: 0.1, blue: 0.1)),
                    .init(location: 1, color: SceneColor(red: 0.1, green: 0.1, blue: 1))],
            startDevice: CGPoint(x: box.minX, y: box.midY), endDevice: CGPoint(x: box.maxX, y: box.midY), tilesWrap: false)
        let newText = "EDIT-\(id)"
        let strokeWidth = 5.0 / SceneSynthesis.averageScale(original.transform)

        switch edit {
        case .delete: try scene.delete([id])
        case .translate: try scene.translate([id], dx: 10, dy: 6)
        case .fillOpaque: try scene.setFill([id], SceneFill(color: opaque, evenOdd: false))
        case .fillAlpha: try scene.setFill([id], SceneFill(color: alpha, evenOdd: false))
        case .fillGradient: try scene.setFill([id], SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false, gradient: gradient))
        case .stroke: try scene.setStroke([id], SceneStroke(color: SceneColor(red: 0.05, green: 0.05, blue: 0.9), isCosmetic: false, width: strokeWidth, dash: .solid, cap: .round, join: .round, miterLimit: 10))
        case .text: try scene.setText(id, newText)
        }

        let result = try SceneExporter.export(scene, as: .emf)

        // (e) parse clean, no EMF+ diagnostics.
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF diagnostics \(file.diagnostics)")
        let plus = file.emfPlusStream()
        #expect(plus.diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF+ diagnostics \(plus.diagnostics)")
        #expect(plus.objectDefinitions().diagnostics.isEmpty, "\(name) id=\(id) \(edit): EMF+ object diagnostics")

        // Deleting the SOLE EMF+ drawing element of a dual file leaves no EMF+
        // drawing record, so the file correctly degrades to its GDI fallback (the
        // pairing-undetermined case, flagged `fallbackMayBeStale`). The EMF+-mode
        // assertions below do not apply; the delete is honest and parse-clean.
        let degradedToGDI = (plus.header?.isDual ?? false) && !plus.records.contains(where: \.isDrawing)
        if edit == .delete, degradedToGDI {
            #expect(result.warnings.contains(.fallbackMayBeStale), "\(name): dual degrade without a stale-fallback warning")
            return
        }

        // (a) re-import shows the new values and kinds.
        let reimport = try SceneImporter.import(data: result.data)
        checkEditVisible(name: name, edit: edit, original: original, base: base, reimport: reimport, opaque: opaque, alpha: alpha, newText: newText)

        // (b) the EMF+ render of the export matches SceneRenderer of the edited scene.
        if let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale), let outImg = render(result.data) {
            let diff = compareImages(sceneImg, outImg, tolerance: Self.tolerance)
            #expect(diff.sameSize && diff.differingFraction <= Self.maxDifferingFraction && diff.meanDelta <= Self.maxMeanDelta,
                    "\(name) id=\(id) \(edit): render(export) vs SceneRenderer — \(pct(diff.differingFraction)) differ, mean \(diff.meanDelta)")
            report += String(format: "%-28@ id=%-3d %-12@ diff=%.3f%% mean=%.2f warn=%d\n", name, id, "\(edit)", diff.differingFraction*100, diff.meanDelta, result.warnings.count)
        } else {
            Issue.record("\(name) id=\(id) \(edit): render failed")
        }

        // (c) pixels outside the edited element footprint are unchanged from source.
        checkOutsideUnchanged(name: name, base: base, original: original, edit: edit, exported: result.data)

        // (d) dual files: the GDI-mode render shows the edit, or a warning was emitted.
        if plus.header?.isDual ?? false {
            let gdi = render(result.data, options: RenderOptions(emfPlusArbitration: .gdi))
            let srcGDI = render(base.source.data, options: RenderOptions(emfPlusArbitration: .gdi))
            let changedInGDI: Bool
            if let gdi, let srcGDI { changedInGDI = compareImages(gdi, srcGDI, tolerance: Self.tolerance).differingFraction > 0.001 }
            else { changedInGDI = false }
            #expect(changedInGDI || result.warnings.contains(.fallbackMayBeStale),
                    "\(name) id=\(id) \(edit): dual GDI-mode shows no edit and no fallback warning")
        }
    }

    private func checkEditVisible(name: String, edit: Edit, original: Element, base: Scene, reimport: Scene, opaque: SceneColor, alpha: SceneColor, newText: String) {
        switch edit {
        case .delete:
            #expect(reimport.editableElements.count == base.editableElements.count - 1, "\(name) delete: count did not drop")
        case .translate:
            switch original.kind {
            case .text:
                // The re-imported text run's drawn device point (referenceLogical
                // through its transform, the one convention) moved by (10,6) ±2 px.
                let base0 = original.text.map { CGPoint(x: $0.referenceLogical.x, y: $0.referenceLogical.y).applying(original.transform) } ?? .zero
                let target = CGPoint(x: base0.x + 10, y: base0.y + 6)
                let found = reimport.editableElements.contains { element in
                    guard element.kind == .text, let t = element.text else { return false }
                    let p = CGPoint(x: t.referenceLogical.x, y: t.referenceLogical.y).applying(element.transform)
                    return abs(p.x - target.x) <= 2 && abs(p.y - target.y) <= 2
                }
                #expect(found, "\(name) translate: text run not at moved reference \(target)")
            case .image:
                // The re-imported image's destination rect moved by (10,6).
                let moved = (original.image?.destRectDevice.standardized ?? .null).offsetBy(dx: 10, dy: 6)
                let found = reimport.editableElements.contains { element in
                    guard element.kind == .image, let img = element.image else { return false }
                    return boundsClose(img.destRectDevice.standardized, moved, tol: 4)
                }
                #expect(found, "\(name) translate: image dest not moved to \(moved)")
            default:
                let moved = original.geometryDevice.boundingBox.offsetBy(dx: 10, dy: 6)
                #expect(reimport.editableElements.contains { boundsClose($0.geometryDevice.boundingBox, moved, tol: 8) }, "\(name) translate: no element at moved box")
            }
        case .fillOpaque:
            if original.kind == .text {
                #expect(reimport.editableElements.contains { colorClose($0.text?.color, opaque) }, "\(name): text colour not applied")
            } else {
                #expect(reimport.editableElements.contains { colorClose($0.style.fill?.color, opaque) }, "\(name): fill colour not applied")
            }
        case .fillAlpha:
            #expect(reimport.editableElements.contains { ($0.style.fill?.color.alpha ?? 1) < 0.9 }, "\(name): alpha fill not applied")
        case .fillGradient:
            #expect(reimport.editableElements.contains { $0.style.fill?.gradient != nil }, "\(name): gradient fill not applied")
        case .stroke:
            #expect(reimport.editableElements.contains { ($0.style.stroke?.width ?? 0) >= 2 }, "\(name): stroke not widened")
        case .text:
            #expect(reimport.editableElements.contains { $0.text?.string == newText }, "\(name): text not changed")
        }
    }

    private func checkOutsideUnchanged(name: String, base: Scene, original: Element, edit: Edit, exported: Data) {
        guard let srcImg = render(base.source.data), let outImg = render(exported),
              let sp = PixelImage(srcImg), let op = PixelImage(outImg), sp.width == op.width, sp.height == op.height else { return }
        var footprint = original.boundsDevice.isNull ? (original.image?.destRectDevice.standardized ?? .null) : original.boundsDevice
        if original.kind == .text {
            // A text run's layout box is a point; a generous box around the string.
            footprint = footprint.insetBy(dx: -footprint.width - 60, dy: -footprint.height - 24)
        }
        if edit == .translate { footprint = footprint.union(footprint.offsetBy(dx: 10, dy: 6)) }
        if footprint.isNull { return }
        let rect = targetPixelRect(footprint, pageBounds: base.pageBoundsDevice, targetW: sp.width, targetH: sp.height).insetBy(dx: -10, dy: -10)
        var outside = 0
        for y in 0 ..< sp.height {
            for x in 0 ..< sp.width where !rect.contains(CGPoint(x: x, y: y)) {
                let o = (y * sp.width + x) * 4
                for c in 0 ..< 4 where abs(Int(sp.pixels[o + c]) - Int(op.pixels[o + c])) > Self.tolerance { outside += 1; break }
            }
        }
        #expect(outside <= 60, "\(name) \(edit): \(outside) pixels changed OUTSIDE the edited footprint")
    }

    // MARK: - Independent fidelity oracle (identity edit)

    /// The edit matrix compares render(export) against `SceneRenderer`, which both
    /// go through the SAME synthesis — a systematic synthesis error scores 0.000%
    /// there. This is the INDEPENDENT oracle: mark an element edited with a
    /// value-preserving mutation (translate 0,0), export, render the export with
    /// `MetafileRenderer`, and compare against `MetafileRenderer` of the ORIGINAL
    /// file — so a synthesis that mis-draws the edited element shows up as a real
    /// pixel difference. Done once per element and once with ALL elements edited.
    ///
    /// Thresholds (measured on the committed fixtures, justified):
    /// - Geometry re-emits the same device vertices — pixel-tight (observed
    ///   0.000%; budget 0.5%).
    /// - An image re-emits its exact placement: an axis-aligned DrawImage, or a
    ///   DrawImagePoints whose parallelogram the lift preserves (rotation/shear/
    ///   mirror), re-encoded lossless PNG, honouring the source SrcRect crop —
    ///   pixel-tight (observed 0.000%; budget 0.5%).
    /// - Text re-draws through its transform in the source font's own em size and
    ///   size unit, with the real layout rect and a re-emitted StringFormat object
    ///   when the run is center/far/line-aligned or carries format flags, so a
    ///   centered run lands exactly where the source did (observed 0.000%, down from
    ///   the pre-fix 1.124% on the one centered committed run). Budget 0.5%.
    @Test func identityEditFidelityOracle() throws {
        let geometryBudget = 0.005
        let textBudget = 0.005
        let imageBudget = 0.005
        var report = "\n=== E1b2a identity-edit fidelity oracle (render(export) vs MetafileRenderer(original)) ===\n"
        for name in Self.emfPlusFiles {
            let base = try scene(name)
            guard let originalImg = render(base.source.data) else { Issue.record("\(name): original render failed"); continue }
            let editable = base.editableElements
            guard !editable.isEmpty else { continue }

            // Per-element identity edit.
            for element in editable {
                var scene = base
                try scene.translate([element.id], dx: 0, dy: 0)
                #expect(scene.element(id: element.id)?.provenance.edited == true,
                        "\(name) id=\(element.id): identity translate did not mark edited")
                let result = try SceneExporter.export(scene, as: .emf)
                guard let outImg = render(result.data) else { Issue.record("\(name) id=\(element.id): export render failed"); continue }
                let diff = compareImages(originalImg, outImg, tolerance: Self.tolerance)
                let budget = element.kind == .text ? textBudget : (element.kind == .image ? imageBudget : geometryBudget)
                #expect(diff.sameSize && diff.differingFraction <= budget,
                        "\(name) id=\(element.id) [\(element.kind)]: identity edit \(pct(diff.differingFraction)) differ from original (budget \(pct(budget)))")
                report += String(format: "%-28@ id=%-3d %-10@ diff=%.3f%% mean=%.2f\n", name, element.id, "\(element.kind)", diff.differingFraction * 100, diff.meanDelta)
            }

            // All elements edited at once.
            var all = base
            try all.translate(Set(editable.map(\.id)), dx: 0, dy: 0)
            let allResult = try SceneExporter.export(all, as: .emf)
            if let outImg = render(allResult.data) {
                let diff = compareImages(originalImg, outImg, tolerance: Self.tolerance)
                let budget = max(geometryBudget, max(textBudget, imageBudget))
                #expect(diff.sameSize && diff.differingFraction <= budget,
                        "\(name) ALL edited: \(pct(diff.differingFraction)) differ from original (budget \(pct(budget)))")
                report += String(format: "%-28@ ALL       diff=%.3f%% mean=%.2f\n", name, diff.differingFraction * 100, diff.meanDelta)
            } else {
                Issue.record("\(name) ALL: export render failed")
            }
        }
        print(report)
    }

    // MARK: - Insert at bottom / middle / top

    @Test func insertAtZPositions() throws {
        let base = try scene("handmade-emfplus-shapes.emf")
        func rect(_ id: Int) -> Element {
            Element(id: id, kind: .rect,
                geometryDevice: ScenePath(CGPath(rect: CGRect(x: 40, y: 40, width: 120, height: 90), transform: nil)),
                transform: .identity,
                style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.1, green: 0.85, blue: 0.2), evenOdd: false)),
                provenance: Provenance(sourceRecordIndices: []))
        }
        for (label, z) in [("bottom", 0), ("middle", base.layers[0].elements.count / 2), ("top", base.layers[0].elements.count)] {
            var scene = base
            scene.insert(rect(90_000 + z), at: z)
            #expect(SceneExporter.isEdited(scene), "insert \(label): not edited")
            let result = try SceneExporter.export(scene, as: .emf)
            let file = try EMFFile.parse(result.data)
            #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "insert \(label): diagnostics")
            let reimport = try SceneImporter.import(data: result.data)
            #expect(reimport.editableElements.count == base.editableElements.count + 1, "insert \(label): element not added")
            if let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale), let outImg = render(result.data) {
                let diff = compareImages(sceneImg, outImg, tolerance: Self.tolerance)
                #expect(diff.differingFraction <= Self.maxDifferingFraction, "insert \(label): render \(pct(diff.differingFraction)) differ")
            }
        }
        // Bottom vs top must differ (z honoured): the green rect sits behind vs in front.
        var bottom = base; bottom.insert(rect(1), at: 0)
        var top = base; top.insert(rect(2), at: base.layers[0].elements.count)
        let b = try SceneExporter.export(bottom, as: .emf).data
        let t = try SceneExporter.export(top, as: .emf).data
        if let bi = render(b), let ti = render(t) {
            #expect(compareImages(bi, ti, tolerance: Self.tolerance).differingFraction > 0.001, "insert z ignored")
        }
    }

    // MARK: - Image: compressed-PNG bitmap

    @Test func editedImageIsCompressedPNGBitmap() throws {
        let base = try scene("handmade-emfplus-image.emf")
        let id = try #require(base.editableElements.first { $0.kind == .image }).id
        var scene = base
        try scene.translate([id], dx: 25, dy: 15)
        let result = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty)
        // At least one EmfPlusBitmap with BitmapDataType compressed (1) in the export.
        var compressed = 0
        for def in file.emfPlusStream().objectDefinitions().definitions {
            if case .image(let img) = def.decodedValue(), case .bitmap(let header, let data) = img.content, header.bitmapDataType == 1 {
                compressed += 1
                #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG stream")
            }
        }
        #expect(compressed >= 1, "edited image not written as a compressed-PNG EmfPlusBitmap")
        // It renders.
        if let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale), let outImg = render(result.data) {
            #expect(compareImages(sceneImg, outImg, tolerance: Self.tolerance).differingFraction <= Self.maxDifferingFraction)
        }
    }

    // MARK: - Image rotation (EmfPlusDrawImagePoints parallelogram)

    @Test func rotatedImageWritesDrawImagePoints() throws {
        let base = try scene("handmade-emfplus-image.emf")
        let original = try #require(base.editableElements.first { $0.kind == .image })
        let box = try #require(original.image).destRectDevice.standardized
        #expect(box.width > 0 && box.height > 0)
        // Rotate 30° about the image centre (device space).
        let cx = box.midX, cy = box.midY
        let rot = CGAffineTransform(translationX: cx, y: cy).rotated(by: .pi / 6).translatedBy(x: -cx, y: -cy)
        var scene = base
        try scene.applyTransform([original.id], rot)
        // The edit stored the true device parallelogram, not a bounding box.
        let edited = try #require(scene.element(id: original.id)?.image)
        let corners = try #require(edited.destCornersDevice)
        #expect(corners.count == 4, "rotation did not store four device corners")

        let result = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "rotated image: diagnostics")
        // The rotated image is written as EmfPlusDrawImagePoints (0x401B). (This file
        // also holds a second image that is natively a DrawImagePoints, so match the
        // rotated one by its three device corners rather than by record count.)
        let drawImagePoints = file.emfPlusStream().records.filter { $0.type == 0x401B }
        #expect(!drawImagePoints.isEmpty, "no EmfPlusDrawImagePoints written for the rotated image")
        // Decode the three device corners (§2.3.4.9): ImageAttributesID(4) +
        // SrcUnit(4) + SrcRect(16) + Count(4), then uncompressed PointF pairs.
        func corners3(_ record: EMFPlusRecord) -> (tl: CGPoint, tr: CGPoint, bl: CGPoint)? {
            let bytes = [UInt8](record.data)
            guard bytes.count >= 28 + 24 else { return nil }
            func f(_ offset: Int) -> Double {
                let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                return Double(Float(bitPattern: bits))
            }
            let count = UInt32(bytes[24]) | UInt32(bytes[25]) << 8 | UInt32(bytes[26]) << 16 | UInt32(bytes[27]) << 24
            guard count == 3 else { return nil }
            return (CGPoint(x: f(28), y: f(32)), CGPoint(x: f(36), y: f(40)), CGPoint(x: f(44), y: f(48)))
        }
        // Match the record whose corners equal the edited element's stored parallelogram.
        let match = drawImagePoints.lazy.compactMap { corners3($0) }.first { c in
            hypot(c.tl.x - corners[0].x, c.tl.y - corners[0].y) < 1.5
                && hypot(c.tr.x - corners[1].x, c.tr.y - corners[1].y) < 1.5
                && hypot(c.bl.x - corners[3].x, c.bl.y - corners[3].y) < 1.5
        }
        let (tl, tr, bl) = try #require(match, "no DrawImagePoints matched the rotated parallelogram")
        // The top edge is rotated 30° and keeps the box width; the left edge keeps
        // the box height — a rigid rotation, not an axis-aligned bounding box.
        let topAngle = atan2(tr.y - tl.y, tr.x - tl.x)
        #expect(abs(topAngle - .pi / 6) < 0.03, "top edge not rotated 30°: \(topAngle) rad")
        #expect(abs(hypot(tr.x - tl.x, tr.y - tl.y) - box.width) < 2, "top edge length != width")
        #expect(abs(hypot(bl.x - tl.x, bl.y - tl.y) - box.height) < 2, "left edge length != height")
        // It renders without trapping.
        #expect(render(result.data) != nil, "rotated-image export did not render")
    }

    /// A rotated image in a GDI container cannot hold a parallelogram, so the GDI
    /// synthesis warns rather than silently axis-aligning. (EMF+ keeps it; this
    /// checks the honest GDI-fallback warning via a dual file's GDI fallback.)
    @Test func rotatedImageGDIFallbackWarns() throws {
        let base = try scene("handmade-emfplus-image.emf")
        var warnings: [ExportWarning] = []
        guard var image = base.editableElements.first(where: { $0.kind == .image })?.image else { return }
        // A rotated parallelogram fed to the GDI image synthesis warns imageRotated.
        image.destCornersDevice = image.destRectDevice.standardized.cornersTLTRBRBL.map {
            $0.applying(CGAffineTransform(rotationAngle: .pi / 6))
        }
        var element = try #require(base.editableElements.first { $0.kind == .image })
        element.image = image
        _ = SceneSynthesis.emfBlock(for: element, baseHandle: 1, warnings: &warnings)
        #expect(warnings.contains(.imageRotated(elementID: element.id)), "GDI image synthesis did not warn on a rotated dest")
    }

    // MARK: - Horizontal mirror of an image (negative determinant keeps corners)

    /// A horizontal mirror is a negative-determinant transform with b == c == 0, so
    /// `applyDeviceTransform` must keep the four device corners (a flip survives only
    /// as an oriented parallelogram), and the EMF+ export must re-emit it as a
    /// DrawImagePoints whose orientation is flipped — a left-red / right-blue image
    /// comes back right-red / left-blue.
    @Test func horizontalMirrorOfImageKeepsFlip() throws {
        let w = 8, h = 8
        var pixels: [UInt8] = []
        for _ in 0 ..< h {
            for col in 0 ..< w { pixels += col < w / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255] }   // B,G,R,A: left red, right blue
        }
        let header = EMFPlusImageBitmapHeader(width: Int32(w), height: Int32(h), stride: Int32(w * 4), pixelFormat: 0x0026_200A, bitmapDataType: 0)
        let plusImage = EMFPlusImage(version: 0xDBC0_1002, content: .bitmap(header, data: Data(pixels)))

        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFPlusDualDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        let imageID = try builder.addObject(.image(plusImage))
        builder.appendPlus(.drawImage(imageID: imageID, imageAttributesID: nil, srcUnit: 2 /* pixel */,
                                      srcRect: EMFPlusRectF(x: 0, y: 0, width: Float(w), height: Float(h)),
                                      destRect: EMFPlusRectF(x: 20, y: 20, width: 160, height: 160)))
        let data = try builder.finish()

        let base = try SceneImporter.import(data: data)
        let original = try #require(base.editableElements.first { $0.kind == .image })
        let box = try #require(original.image).destRectDevice.standardized
        // A horizontal mirror about the image centre (negative x-scale: det < 0, b == c == 0).
        let cx = box.midX
        let mirror = CGAffineTransform(translationX: cx, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -cx, y: 0)
        var scene = base
        try scene.applyTransform([original.id], mirror)
        // The flip is kept as four device corners (not standardised to a box).
        let corners = try #require(scene.element(id: original.id)?.image?.destCornersDevice)
        #expect(corners.count == 4, "mirror did not store four device corners")
        // The former top-left corner is now to the RIGHT of the former top-right.
        #expect(corners[0].x > corners[1].x, "horizontal mirror not reflected in the corners: \(corners)")

        let result = try SceneExporter.export(scene, as: .emf)
        #expect(try EMFFile.parse(result.data).emfPlusStream().diagnostics.isEmpty, "mirrored image: diagnostics")
        #expect(!result.data.isEmpty)
        // Rendered in EMF+ mode, the mirror swaps the colours left↔right: the left
        // band is now blue, the right band now red.
        let out = try #require(render(result.data), "mirror render failed")
        let img = try #require(PixelImage(out))
        func sample(_ deviceRect: CGRect) -> (r: Int, g: Int, b: Int) {
            let r = targetPixelRect(deviceRect, pageBounds: base.pageBoundsDevice, targetW: img.width, targetH: img.height)
            let x = min(max(Int(r.midX), 0), img.width - 1), y = min(max(Int(r.midY), 0), img.height - 1)
            let o = (y * img.width + x) * 4
            return (Int(img.pixels[o]), Int(img.pixels[o + 1]), Int(img.pixels[o + 2]))
        }
        let left = sample(CGRect(x: 45, y: 90, width: 10, height: 20))    // device left band
        let right = sample(CGRect(x: 145, y: 90, width: 10, height: 20))  // device right band
        #expect(left.b > 150 && left.r < 100, "mirrored image left band not blue: \(left)")
        #expect(right.r > 150 && right.b < 100, "mirrored image right band not red: \(right)")
    }

    // MARK: - Slot restore (all 64 object slots live)

    @Test func slotRestoreWithAllSlotsLive() throws {
        // A hand-built EMF+ stream: 64 brushes (ids 0…63, every slot live), three
        // FillRects — A and C both use brush 0, B (the middle) is the editable
        // element. Stroking B forces its synthesis to REUSE a defined slot (none is
        // free) and restore it; the restore must leave brush 0 intact so C renders
        // unchanged.
        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFPlusDualDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> EMFPlusObjectValue {
            .brush(EMFPlusBrush(version: 0xDBC0_1002, brushType: .solid, data: .solid(EMFPlusARGB(blue: b, green: g, red: r, alpha: 255))))
        }
        // Brush 0 is a distinctive red used by A and C.
        _ = try builder.addObject(solid(220, 20, 20))
        for i in 1 ..< 64 { _ = try builder.addObject(solid(UInt8(i), UInt8(i), 200)) }
        func rect(_ x: Float, _ y: Float) -> EMFPlusRectF { EMFPlusRectF(x: x, y: y, width: 30, height: 30) }
        builder.appendPlus(.fillRects(brush: .object(0), rects: [rect(10, 10)]))     // A (brush 0)
        builder.appendPlus(.fillRects(brush: .object(5), rects: [rect(80, 80)]))     // B (editable, brush 5)
        builder.appendPlus(.fillRects(brush: .object(0), rects: [rect(10, 150)]))    // C (brush 0)
        let data = try builder.finish()

        let base = try SceneImporter.import(data: data)
        let editable = base.editableElements
        try #require(editable.count == 3, "expected 3 FillRects elements")
        let midID = editable[1].id
        var scene = base
        let w = 5.0 / SceneSynthesis.averageScale(try #require(scene.element(id: midID)).transform)
        try scene.setStroke([midID], SceneStroke(color: SceneColor(red: 0, green: 0.8, blue: 0, alpha: 1), isCosmetic: false, width: w, dash: .solid, cap: .butt, join: .miter, miterLimit: 10))
        let result = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty, "slot restore: diagnostics")

        // C still re-imports as the distinctive red brush 0 (slot 0 restored).
        let reimport = try SceneImporter.import(data: result.data)
        let red = SceneColor(EMFPlusARGB(blue: 20, green: 20, red: 220, alpha: 255))
        #expect(reimport.editableElements.filter { colorClose($0.style.fill?.color, red) }.count >= 2, "slot restore: brush 0 not intact for A and C")

        // Pixels outside B's footprint are unchanged from the source (A and C intact).
        guard let srcImg = render(data), let outImg = render(result.data),
              let sp = PixelImage(srcImg), let op = PixelImage(outImg), sp.width == op.width else { return }
        let bBox = try #require(scene.element(id: midID)).geometryDevice.boundingBox
        let rect = targetPixelRect(bBox, pageBounds: base.pageBoundsDevice, targetW: sp.width, targetH: sp.height).insetBy(dx: -12, dy: -12)
        var outside = 0
        for y in 0 ..< sp.height {
            for x in 0 ..< sp.width where !rect.contains(CGPoint(x: x, y: y)) {
                let o = (y * sp.width + x) * 4
                for c in 0 ..< 4 where abs(Int(sp.pixels[o + c]) - Int(op.pixels[o + c])) > Self.tolerance { outside += 1; break }
            }
        }
        #expect(outside <= 40, "slot restore: \(outside) pixels changed outside B — a reused slot was not restored")
    }

    // MARK: - Dual GDI-fallback pairing (between-comments rule)

    @Test func dualFallbackPairingRemovesPairedRecord() throws {
        // A dual file where each EMF+ element's GDI fallback sits between its comment
        // and the next element's comment (so pairing IS determinable): FillRects A +
        // its GDI fallback rect (box A), then FillRects B + its GDI fallback rect
        // (box B). Translating A must DROP A's paired fallback rect (box A gone from
        // the GDI records) and KEEP B's (box B present), with no stale-fallback warning.
        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFPlusDualDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        let boxA = RectL(left: 10, top: 10, right: 60, bottom: 60)
        let boxB = RectL(left: 120, top: 120, right: 170, bottom: 170)
        func gdiRect(_ box: RectL, _ color: ColorRef) throws {
            try builder.appendGDIFallback(.createBrushIndirect(CreateBrushPayload(ihBrush: 0, style: 0, color: color, hatch: 0)))
            try builder.appendGDIFallback(.selectObject(.table(index: 0)))
            try builder.appendGDIFallback(.rectangle(box: box))
            try builder.appendGDIFallback(.selectObject(.stock(.whiteBrush)))
            try builder.appendGDIFallback(.deleteObject(.table(index: 0)))
        }
        builder.appendPlus(.fillRects(brush: .color(EMFPlusARGB(blue: 20, green: 20, red: 220, alpha: 255)), rects: [EMFPlusRectF(x: 10, y: 10, width: 50, height: 50)]))
        try gdiRect(boxA, ColorRef(red: 220, green: 20, blue: 20))
        builder.appendPlus(.fillRects(brush: .color(EMFPlusARGB(blue: 220, green: 20, red: 20, alpha: 255)), rects: [EMFPlusRectF(x: 120, y: 120, width: 50, height: 50)]))
        try gdiRect(boxB, ColorRef(red: 20, green: 20, blue: 220))
        let data = try builder.finish()

        let base = try SceneImporter.import(data: data)
        let editable = base.editableElements
        try #require(editable.count == 2, "expected 2 EMF+ rects")
        #expect(!base.partition.fallback.isEmpty, "no GDI fallback lifted")
        var scene = base
        try scene.translate([editable[0].id], dx: 50, dy: 50)   // move A off its original box
        let result = try SceneExporter.export(scene, as: .emf)
        let file = try EMFFile.parse(result.data)
        #expect(file.diagnostics.isEmpty && file.emfPlusStream().diagnostics.isEmpty)
        // All fallback is cleanly paired, so no stale-fallback warning.
        #expect(!result.warnings.contains(.fallbackMayBeStale), "false stale-fallback warning on cleanly-paired fallback")

        // The GDI records of the export: A's ORIGINAL fallback rect (box A) is gone
        // (paired, removed); B's (box B) survives; the moved A is redrawn elsewhere.
        var rects: [RectL] = []
        for record in file.records where record.type == 43 {   // EMR_RECTANGLE
            if case .rectangle(let box) = file.payload(of: record) { rects.append(box) }
        }
        #expect(!rects.contains(boxA), "A's paired GDI fallback rect was NOT removed: \(rects)")
        #expect(rects.contains(boxB), "B's GDI fallback rect was wrongly dropped: \(rects)")
        #expect(rects.contains(RectL(left: 60, top: 60, right: 110, bottom: 110)), "moved A not redrawn in the GDI fallback: \(rects)")
    }

    // MARK: - GDI-fallback image orientation (top-down DIB)

    /// A hand-built DUAL file with an asymmetric EMF+ image (top half red, bottom
    /// half blue). Editing it regenerates a GDI STRETCHDIBITS fallback; rendered in
    /// GDI-arbitration mode the image must keep its orientation (top red, bottom
    /// blue) — a positive/bottom-up DIB height would flip it.
    @Test func dualGDIFallbackImageKeepsOrientation() throws {
        let w = 8, h = 8
        var pixels: [UInt8] = []
        for row in 0 ..< h {
            let top = row < h / 2
            for _ in 0 ..< w { pixels += top ? [0, 0, 255, 255] : [255, 0, 0, 255] }   // B,G,R,A: red / blue
        }
        let header = EMFPlusImageBitmapHeader(width: Int32(w), height: Int32(h), stride: Int32(w * 4), pixelFormat: 0x0026_200A, bitmapDataType: 0)
        let plusImage = EMFPlusImage(version: 0xDBC0_1002, content: .bitmap(header, data: Data(pixels)))

        let page = RectL(left: 0, top: 0, right: 199, bottom: 199)
        let builder = EMFPlusDualDocumentBuilder(bounds: page, frame: page, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        let imageID = try builder.addObject(.image(plusImage))
        builder.appendPlus(.drawImage(imageID: imageID, imageAttributesID: nil, srcUnit: 2 /* pixel */,
                                      srcRect: EMFPlusRectF(x: 0, y: 0, width: Float(w), height: Float(h)),
                                      destRect: EMFPlusRectF(x: 20, y: 20, width: 160, height: 160)))
        let data = try builder.finish()

        let base = try SceneImporter.import(data: data)
        let id = try #require(base.editableElements.first { $0.kind == .image }).id
        var scene = base
        try scene.translate([id], dx: 0, dy: 0)   // mark edited → regenerate the GDI fallback
        let result = try SceneExporter.export(scene, as: .emf)

        let gdi = try #require(render(result.data, options: RenderOptions(emfPlusArbitration: .gdi)), "GDI-mode render failed")
        let img = try #require(PixelImage(gdi))
        func sample(_ deviceRect: CGRect) -> (r: Int, g: Int, b: Int) {
            let r = targetPixelRect(deviceRect, pageBounds: base.pageBoundsDevice, targetW: img.width, targetH: img.height)
            let x = min(max(Int(r.midX), 0), img.width - 1), y = min(max(Int(r.midY), 0), img.height - 1)
            let o = (y * img.width + x) * 4
            return (Int(img.pixels[o]), Int(img.pixels[o + 1]), Int(img.pixels[o + 2]))
        }
        let top = sample(CGRect(x: 90, y: 45, width: 20, height: 10))     // device y≈50 → image top band
        let bottom = sample(CGRect(x: 90, y: 145, width: 20, height: 10)) // device y≈150 → image bottom band
        #expect(top.r > 150 && top.b < 100, "GDI fallback image top is not red (orientation flipped): \(top)")
        #expect(bottom.b > 150 && bottom.r < 100, "GDI fallback image bottom is not blue (orientation flipped): \(bottom)")
    }

    // MARK: - GDI 32-bpp BI_RGB with alpha bytes 0 must render opaque

    @Test func gdiBIRGB32AlphaZeroDecodesOpaque() throws {
        // A 4×4 GDI 32-bpp BI_RGB DIB: green (B=0,G=255,R=0) with the reserved
        // fourth byte 0. The reserved byte is NOT alpha, so the decode must be
        // opaque — the old hand-rolled unpacker read it as alpha and the image
        // vanished.
        let w = 4, h = 4
        let px = Array(repeating: [UInt8](arrayLiteral: 0, 255, 0, 0), count: w * h).flatMap { $0 }
        let dib = DIB(width: Int32(w), height: Int32(h), bitCount: 32, compression: .rgb,
                      content: .pixels(bytes: Data(px), stride: w * 4, palette: []))
        let cg = try #require(BitmapDecoder.cgImage(from: dib), "32-bpp BI_RGB DIB did not decode")
        let decoded = try #require(PixelImage(cg))
        // Drawn over a transparent buffer: an opaque decode keeps alpha 255 and
        // green; an alpha-0 decode would premultiply the green to 0.
        #expect(decoded.pixels[3] == 255, "decoded 32-bpp BI_RGB not opaque (alpha \(decoded.pixels[3]))")
        #expect(decoded.pixels[1] > 200 && decoded.pixels[0] < 80, "green vanished: \((decoded.pixels[0], decoded.pixels[1], decoded.pixels[2]))")
    }

    @Test func gdiBIRGB32AlphaZeroRendersOpaqueInEMFPlusScene() throws {
        let w = 4, h = 4
        let px = Array(repeating: [UInt8](arrayLiteral: 0, 255, 0, 0), count: w * h).flatMap { $0 }
        let dib = DIB(width: Int32(w), height: Int32(h), bitCount: 32, compression: .rgb,
                      content: .pixels(bytes: Data(px), stride: w * 4, palette: []))
        var scene = try self.scene("handmade-emfplus-image.emf")
        let element = try #require(scene.editableElements.first { $0.kind == .image })
        let destBox = try #require(element.image).destRectDevice.standardized
        // Swap the element's source to the GDI 32-bpp BI_RGB DIB (alpha bytes 0).
        for li in scene.layers.indices {
            for ei in scene.layers[li].elements.indices where scene.layers[li].elements[ei].id == element.id {
                scene.layers[li].elements[ei].image?.sourceDIB = dib
                scene.layers[li].elements[ei].image?.emfPlusImage = nil
            }
        }
        try scene.translate([element.id], dx: 0, dy: 0)   // mark edited
        let result = try SceneExporter.export(scene, as: .emf)
        let out = try #require(render(result.data), "render failed")
        let img = try #require(PixelImage(out))
        let r = targetPixelRect(destBox, pageBounds: scene.pageBoundsDevice, targetW: img.width, targetH: img.height)
        let x = min(max(Int(r.midX), 0), img.width - 1), y = min(max(Int(r.midY), 0), img.height - 1)
        let o = (y * img.width + x) * 4
        #expect(img.pixels[o + 1] > 150 && img.pixels[o] < 120 && img.pixels[o + 2] < 120,
                "alpha-0 32-bpp BI_RGB image did not render opaque green: \((img.pixels[o], img.pixels[o + 1], img.pixels[o + 2]))")
    }

    // MARK: - Object-definition grouping (continuation flag)

    @Test func backToBackCompleteObjectDefsKeepLast() throws {
        func objectRecord(id: UInt8, continues: Bool, data: [UInt8]) -> EMFPlusRecord {
            EMFPlusRecord(type: 0x4008, flags: UInt16(id) | (continues ? 0x8000 : 0),
                          declaredSize: UInt32(12 + data.count), declaredDataSize: UInt32(data.count),
                          data: Data(data), sourceRecordIndex: 0)
        }
        var defs = PlusObjectDefs()
        // Two back-to-back COMPLETE definitions of slot 5 (continuation flag clear).
        defs.feed(record: objectRecord(id: 5, continues: false, data: [1]), framed: [0xA1])
        defs.feed(record: objectRecord(id: 5, continues: false, data: [2]), framed: [0xB2])
        defs.flush()
        #expect(defs.definition(of: 5) == [[0xB2]], "back-to-back complete defs: only the last must survive, got \(defs.definition(of: 5))")
        #expect(defs.definedSlots == [5])

        // A CONTINUED definition groups its consecutive same-slot chunks.
        var cont = PlusObjectDefs()
        cont.feed(record: objectRecord(id: 7, continues: true, data: [1]), framed: [0xC1])
        cont.feed(record: objectRecord(id: 7, continues: true, data: [2]), framed: [0xC2])
        cont.flush()
        #expect(cont.definition(of: 7) == [[0xC1], [0xC2]], "continued def: chunks must group, got \(cont.definition(of: 7))")
    }

    // MARK: - Hostile (typed, never traps)

    @Test func hostileEMFPlusExportIsBounded() throws {
        let full = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("handmade-emfplus-shapes.emf"))
        for fraction in [0.3, 0.5, 0.7, 0.9] {
            let cut = Data(full.prefix(Int(Double(full.count) * fraction)))
            guard var scene = try? SceneImporter.import(data: cut), let first = scene.editableElements.first else { continue }
            try? scene.translate([first.id], dx: 3, dy: 3)
            // Never traps; either exports or throws a typed error.
            _ = try? SceneExporter.export(scene, as: .emf)
        }
    }

    // MARK: - corpus-local (counts only; gitignored, may be absent)

    @Test func corpusLocalEMFPlusEditExports() throws {
        let urls = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "emf" }
        var plusFiles = 0, exported = 0, parseClean = 0, reimported = 0, rendered = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url), let base = try? SceneImporter.import(data: data),
                  base.source.renderPath == .emfPlus, !base.editableElements.isEmpty else { continue }
            plusFiles += 1
            var scene = base
            let editable = base.editableElements
            try? scene.delete([editable[editable.count / 2].id])
            try? scene.translate([editable[0].id], dx: 8, dy: 4)
            guard let result = try? SceneExporter.export(scene, as: .emf) else { continue }
            exported += 1
            // Render-compare the EXPORT (one playback) — NOT SceneRenderer, which
            // replays per element run and is too slow for large lifted files.
            if let file = try? EMFFile.parse(result.data), file.diagnostics.isEmpty, file.emfPlusStream().diagnostics.isEmpty { parseClean += 1 }
            if (try? SceneImporter.import(data: result.data)) != nil { reimported += 1 }
            // A capped, low scale: this only checks the export renders without
            // trapping, so a quarter-res (or less, for a huge page) buffer suffices.
            let maxDim = max(base.pageSizeDevice.width, base.pageSizeDevice.height)
            if render(result.data, scale: min(1, CGFloat(1100) / max(maxDim, 1))) != nil { rendered += 1 }
        }
        print("\n=== corpus-local EMF+ export: \(plusFiles) files, exported \(exported), parse-clean \(parseClean), re-imported \(reimported), rendered \(rendered) ===")
        if plusFiles > 0 { #expect(exported == plusFiles && parseClean == plusFiles && reimported == plusFiles && rendered == plusFiles) }
    }

    /// The independent oracle over corpus-local EMF+ files: ALL-elements identity
    /// edit (translate 0,0), render(export) vs MetafileRenderer(original). Counts
    /// and a distribution only — gitignored, confidential, may be absent. Outliers
    /// are reported by anonymised index (position in the sorted file list), never a
    /// name.
    @Test func corpusLocalIdentityEditFidelity() throws {
        let urls = EditTestPaths.localMetafiles().filter { $0.pathExtension.lowercased() == "emf" }
        var files = 0, within05 = 0, within2 = 0, over2 = 0
        var outliers: [(index: Int, pct: Double)] = []
        for (index, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url), let base = try? SceneImporter.import(data: data),
                  base.source.renderPath == .emfPlus, !base.editableElements.isEmpty else { continue }
            // Adaptive scale: small pages render at full `corpusScale`; a huge page is
            // capped so the sweep stays fast (fidelity is an area fraction, so a capped
            // resolution still measures it). Both renders share the scale → same size.
            let maxDim = max(base.pageSizeDevice.width, base.pageSizeDevice.height)
            let scale = min(Self.corpusScale, CGFloat(1100) / max(maxDim, 1))
            guard let originalImg = render(data, scale: scale) else { continue }
            var scene = base
            try? scene.translate(Set(base.editableElements.map(\.id)), dx: 0, dy: 0)
            guard let result = try? SceneExporter.export(scene, as: .emf), let outImg = render(result.data, scale: scale) else { continue }
            let diff = compareImages(originalImg, outImg, tolerance: Self.tolerance)
            guard diff.sameSize else { continue }
            files += 1
            if diff.differingFraction <= 0.005 { within05 += 1 }
            else if diff.differingFraction <= 0.02 { within2 += 1; outliers.append((index, diff.differingFraction)) }
            else { over2 += 1; outliers.append((index, diff.differingFraction)) }
        }
        let outlierText = outliers.sorted { $0.pct > $1.pct }.prefix(12)
            .map { "#\($0.index)=\(pct($0.pct))" }.joined(separator: ", ")
        print("\n=== corpus-local EMF+ identity-edit fidelity: \(files) files — ≤0.5%: \(within05), ≤2%: \(within2), >2%: \(over2) — outliers: \(outlierText) ===")
        // A COUNT floor only (the files are confidential, so no file is named): most
        // EMF+ files re-emit an identity edit within 0.5%, and the few residuals are
        // GDI text in GetDC windows whose fractional source world transform quantises
        // to an integer EMR reference — a sub-pixel shift, documented, not a
        // regression. The floor catches a broad regression without being flaky.
        if files >= 20 {
            #expect(within05 >= files - 5,
                    "corpus-local identity fidelity regressed: only \(within05)/\(files) within 0.5%")
        }
    }

    // MARK: - Interop evidence (translated text, rotated image)

    /// Round-trips a translated EMF+ text file and a rotated EMF+ image file
    /// (parse-clean, re-import visible), and — when `EMFY_INTEROP_DIR` is set —
    /// writes both to that directory so an external reader (LibreOffice) can be
    /// pixel-sampled off-repo. Always runs; the file write is opt-in.
    @Test func exportInteropEvidenceFiles() throws {
        // Translated text (dx:40, dy:25).
        var textScene = try scene("handmade-emfplus-text.emf")
        let textID = try #require(textScene.editableElements.first { $0.kind == .text }).id
        try textScene.translate([textID], dx: 40, dy: 25)
        let textResult = try SceneExporter.export(textScene, as: .emf)
        #expect(try EMFFile.parse(textResult.data).emfPlusStream().diagnostics.isEmpty)
        #expect(try SceneImporter.import(data: textResult.data).editableElements.contains { $0.kind == .text })

        // Rotated image (30° about its centre).
        var imageScene = try scene("handmade-emfplus-image.emf")
        let imageElement = try #require(imageScene.editableElements.first { $0.kind == .image })
        let box = try #require(imageElement.image).destRectDevice.standardized
        let rot = CGAffineTransform(translationX: box.midX, y: box.midY).rotated(by: .pi / 6).translatedBy(x: -box.midX, y: -box.midY)
        try imageScene.applyTransform([imageElement.id], rot)
        let imageResult = try SceneExporter.export(imageScene, as: .emf)
        #expect(try EMFFile.parse(imageResult.data).emfPlusStream().diagnostics.isEmpty)

        if let dir = ProcessInfo.processInfo.environment["EMFY_INTEROP_DIR"] {
            let base = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try textResult.data.write(to: base.appendingPathComponent("translated-emfplus-text.emf"))
            try imageResult.data.write(to: base.appendingPathComponent("rotated-emfplus-image.emf"))
            try textScene.source.data.write(to: base.appendingPathComponent("original-emfplus-text.emf"))
            try imageScene.source.data.write(to: base.appendingPathComponent("original-emfplus-image.emf"))
        }
    }

    // MARK: - Helpers

    private func targetPixelRect(_ deviceRect: CGRect, pageBounds: CGRect, targetW: Int, targetH: Int) -> CGRect {
        let dw = max(pageBounds.width, 1), dh = max(pageBounds.height, 1)
        let sx = Double(targetW) / dw, sy = Double(targetH) / dh
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: sx * (p.x - pageBounds.minX), y: sy * (p.y - pageBounds.minY)) }
        let a = px(CGPoint(x: deviceRect.minX, y: deviceRect.minY)), b = px(CGPoint(x: deviceRect.maxX, y: deviceRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    private func boundsClose(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        guard !a.isNull, !b.isNull else { return false }
        return abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
    private func colorClose(_ a: SceneColor?, _ b: SceneColor) -> Bool {
        guard let a else { return false }
        return abs(a.red - b.red) < 0.05 && abs(a.green - b.green) < 0.05 && abs(a.blue - b.blue) < 0.05
    }
    private func pct(_ f: Double) -> String { String(format: "%.3f%%", f * 100) }
}
