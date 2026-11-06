import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
import WMFParse
@testable import EMFEdit

/// E1b1 export gate: unchanged scenes re-emit byte-identically; edited GDI EMF
/// and WMF scenes export, re-import with the edit visible, render like the
/// edited scene, leave the rest of the page untouched, and parse cleanly.
struct SceneExportTests {

    static let renderScale: CGFloat = 2
    /// Per-channel tolerance (matches the renderer's comparator).
    static let tolerance = 16
    /// Differing-pixel budget for render(exported) vs the edited scene. Both EMF
    /// and WMF are now true overlays, so unedited content is byte-verbatim and the
    /// edited element is rendered by the SAME synthesis the exporter writes. The
    /// residual is the E1a lift baseline (the scene renderer draws unedited
    /// geometry from value types where playback replays records) plus device
    /// rounding — the worst committed case is ~0.8%.
    static let maxDifferingFraction = 0.015
    static let maxMeanDelta = 2.0

    // MARK: - Format helpers

    private func format(for url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "emz": return .emz
        case "wmf": return .wmf
        case "wmz": return .wmz
        default: return .emf
        }
    }

    private func renderBytes(_ data: Data, scale: CGFloat) -> CGImage? {
        guard let opened = try? OpenedMetafile.open(data) else { return nil }
        return MetafileRenderer.makeImage(opened, scale: scale)?.0
    }

    /// Files the edit matrix exercises: GDI EMF and WMF with editable content
    /// (EMF+ files and empty WMFs are excluded — editing EMF+ is E1b2).
    private func editableFiles() -> [URL] {
        EditTestPaths.committedMetafiles().filter { url in
            guard let scene = try? SceneImporter.import(data: (try? Data(contentsOf: url)) ?? Data()) else { return false }
            return scene.source.renderPath != .emfPlus && !scene.editableElements.isEmpty
        }
    }

    // MARK: - Unchanged == re-emit

    @Test func unchangedExportMatchesReEmitAndSource() throws {
        for url in EditTestPaths.committedMetafiles() {
            let data = try Data(contentsOf: url)
            guard let scene = try? SceneImporter.import(data: data) else {
                Issue.record("import failed: \(url.lastPathComponent)"); continue
            }
            #expect(!SceneExporter.isEdited(scene), "\(url.lastPathComponent): fresh import reported edited")
            let result = try SceneExporter.export(scene, as: format(for: url))

            // Byte-identical to an independently computed re-emit (both families).
            var expected: Data
            if scene.source.format == .emf {
                expected = try EMFDocumentWriter.reEmit(try EMFFile.parse(scene.source.data), source: scene.source.data)
            } else {
                expected = try WMFDocumentWriter.reEmit(try WMFFile.parse(scene.source.data), source: scene.source.data)
            }
            if scene.source.wasCompressed { expected = GzipWriter.compress(expected) }
            #expect(result.data == expected, "\(url.lastPathComponent): unchanged export != reEmit")

            // Every file: renders pixel-identical to the source.
            guard let srcImg = renderBytes(data, scale: Self.renderScale),
                  let outImg = renderBytes(result.data, scale: Self.renderScale) else {
                Issue.record("render failed: \(url.lastPathComponent)"); continue
            }
            let diff = compareImages(srcImg, outImg, tolerance: 0)
            #expect(diff.sameSize && diff.maxChannelDelta == 0,
                    "\(url.lastPathComponent): unchanged export not pixel-identical to source (maxΔ \(diff.maxChannelDelta))")
            // Determinism.
            let again = try SceneExporter.export(scene, as: format(for: url))
            #expect(again.data == result.data, "\(url.lastPathComponent): export not deterministic")
        }
    }

    // MARK: - Edit matrix

    enum Edit: CustomStringConvertible {
        case delete, translate, fill, stroke, text
        var description: String {
            switch self {
            case .delete: return "delete"; case .translate: return "translate"
            case .fill: return "fill"; case .stroke: return "stroke"; case .text: return "setText"
            }
        }
    }

    @Test func editMatrixAcrossCommittedFiles() throws {
        var report = "\n=== E1b1 edit matrix ===\n"
        for url in editableFiles() {
            let data = try Data(contentsOf: url)
            let base = try SceneImporter.import(data: data)
            // Render the source ONCE per file (the "outside the footprint is unchanged"
            // check compares against it on every edit — rendering it per edit was the
            // dominant redundant cost, slice E1b2d item 7).
            let sourceImg = renderBytes(data, scale: Self.renderScale)
            let editable = base.editableElements
            // First, middle, last editable element (deterministic).
            let picks = Set([0, editable.count / 2, editable.count - 1]).sorted().map { editable[$0].id }

            for id in picks {
                guard let element = base.element(id: id) else { continue }
                for edit in applicableEdits(for: element) {
                    do {
                        try runEdit(url: url, base: base, sourceImg: sourceImg, id: id, edit: edit, report: &report)
                    } catch {
                        Issue.record("\(url.lastPathComponent) id=\(id) \(edit): threw \(error)")
                    }
                }
            }
        }
        print(report)
    }

    private func applicableEdits(for element: Element) -> [Edit] {
        var edits: [Edit] = [.delete, .translate]
        let fillable: Set<ElementKind> = [.rect, .ellipse, .roundRect, .polygon, .path, .arc]
        if fillable.contains(element.kind) || element.kind == .text { edits.append(.fill) }
        if element.kind != .text && element.kind != .image { edits.append(.stroke) }
        if element.kind == .text { edits.append(.text) }
        return edits
    }

    private func runEdit(url: URL, base: Scene, sourceImg: CGImage?, id: Int, edit: Edit, report: inout String) throws {
        var scene = base
        let original = try #require(scene.element(id: id))
        let newColor = SceneColor(red: 0.90, green: 0.12, blue: 0.55)
        let newText = "EDITED-\(id)"
        // Width chosen so the stroke is ~5 device px regardless of the element's
        // logical→device scale (small-scale files would otherwise round to a
        // cosmetic hairline).
        let strokeLogicalWidth = 5.0 / SceneSynthesis.averageScale(original.transform)

        switch edit {
        case .delete: try scene.delete([id])
        case .translate: try scene.translate([id], dx: 10, dy: 5)
        case .fill: try scene.setFill([id], SceneFill(color: newColor, evenOdd: false))
        case .stroke: try scene.setStroke([id], SceneStroke(color: SceneColor(red: 0.05, green: 0.05, blue: 0.9), isCosmetic: false, width: strokeLogicalWidth, dash: .solid, cap: .round, join: .round, miterLimit: 10))
        case .text: try scene.setText(id, newText)
        }

        let result = try SceneExporter.export(scene, as: format(for: url))
        let reimport = try SceneImporter.import(data: result.data)

        // (a) the edit is visible on re-import.
        checkEditVisible(url: url, edit: edit, original: original, base: base, reimport: reimport, newColor: newColor, newText: newText)

        // (b) render(exported) matches the edited scene. The export is rendered ONCE
        // here and reused by the footprint check below (slice E1b2d item 7).
        let outImg = renderBytes(result.data, scale: Self.renderScale)
        if let sceneImg = SceneRenderer.makeImage(scene, scale: Self.renderScale), let outImg {
            let diff = compareImages(sceneImg, outImg, tolerance: Self.tolerance)
            #expect(diff.sameSize, "\(url.lastPathComponent) id=\(id) \(edit): size mismatch")
            #expect(diff.differingFraction <= Self.maxDifferingFraction,
                    "\(url.lastPathComponent) id=\(id) \(edit): \(pct(diff.differingFraction)) differ (budget \(pct(Self.maxDifferingFraction)))")
            #expect(diff.meanDelta <= Self.maxMeanDelta,
                    "\(url.lastPathComponent) id=\(id) \(edit): mean Δ \(diff.meanDelta)")
            report += String(format: "%-28@ id=%-3d %-9@ b: diff=%.3f%% mean=%.2f warn=%d\n",
                url.lastPathComponent, id, "\(edit)", diff.differingFraction * 100, diff.meanDelta, result.warnings.count)
        } else {
            Issue.record("\(url.lastPathComponent) id=\(id) \(edit): render failed")
        }

        // (c) pixels outside the edited element's footprint are unchanged from
        // the ORIGINAL render — the lossless-overlay guarantee. It holds for EMF
        // (verbatim records) and for WMF (true overlay: verbatim records, or for
        // an embedded-EMF WMF a lossless embedded-EMF overlay).
        checkOutsideUnchanged(url: url, base: base, original: original, edit: edit, sourceImg: sourceImg, exportImg: outImg)

        // (d) byte accounting is clean.
        checkByteAccounting(url: url, scene: scene, data: result.data)
    }

    // MARK: - (a) edit visible

    private func checkEditVisible(url: URL, edit: Edit, original: Element, base: Scene, reimport: Scene, newColor: SceneColor, newText: String) {
        let name = url.lastPathComponent
        switch edit {
        case .delete:
            #expect(reimport.editableElements.count == base.editableElements.count - 1,
                    "\(name) \(edit): editable count did not drop")
        case .translate:
            // A re-imported element reflects the (10,5) device-space move. Text
            // runs carry no geometry, so match the shifted reference point;
            // everything else matches the shifted geometry bounding box (NOT the
            // clipped `boundsDevice`, which the clip may crop independently).
            if original.kind == .text, let text = original.text {
                let ref = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(original.transform)
                let movedRef = CGPoint(x: ref.x + 10, y: ref.y + 5)
                let found = reimport.editableElements.contains { element in
                    guard let rt = element.text else { return false }
                    let r = CGPoint(x: rt.referenceLogical.x, y: rt.referenceLogical.y).applying(element.transform)
                    return abs(r.x - movedRef.x) <= 6 && abs(r.y - movedRef.y) <= 6
                }
                #expect(found, "\(name) \(edit): no text run found at the moved reference \(movedRef)")
            } else {
                let g = original.geometryDevice.boundingBox
                if !g.isNull {
                    let moved = g.offsetBy(dx: 10, dy: 5)
                    let found = reimport.editableElements.contains { boundsClose($0.geometryDevice.boundingBox, moved, tol: 6) }
                    #expect(found, "\(name) \(edit): no element found at the moved geometry \(moved)")
                }
            }
        case .fill:
            if original.kind == .text {
                #expect(reimport.editableElements.contains { colorClose($0.text?.color, newColor) }, "\(name) \(edit): text colour not applied")
            } else {
                #expect(reimport.editableElements.contains { colorClose($0.style.fill?.color, newColor) }, "\(name) \(edit): fill colour not applied")
            }
        case .stroke:
            // The re-imported element draws its stroke in device space (its
            // transform is now identity), so a ~5 px device stroke lifts as width ≈ 5.
            #expect(reimport.editableElements.contains { ($0.style.stroke?.width ?? 0) >= 2 }, "\(name) \(edit): stroke not widened")
        case .text:
            #expect(reimport.editableElements.contains { $0.text?.string == newText }, "\(name) \(edit): text not changed")
        }
    }

    // MARK: - (c) outside the footprint is unchanged

    private func checkOutsideUnchanged(url: URL, base: Scene, original: Element, edit: Edit, sourceImg: CGImage?, exportImg: CGImage?) {
        guard let srcImg = sourceImg, let outImg = exportImg,
              let sp = PixelImage(srcImg), let op = PixelImage(outImg),
              sp.width == op.width, sp.height == op.height
        else { return }

        // Edit footprint in device space.
        var footprint = elementFootprintDevice(original)
        if edit == .translate {
            footprint = footprint.union(footprint.offsetBy(dx: 10, dy: 5))
        }
        // Map to pixel space and dilate.
        let rect = targetPixelRect(footprint, pageBounds: base.pageBoundsDevice,
                                   targetW: sp.width, targetH: sp.height).insetBy(dx: -8, dy: -8)

        var outsideDiffs = 0
        for y in 0 ..< sp.height {
            for x in 0 ..< sp.width where !rect.contains(CGPoint(x: x, y: y)) {
                let o = (y * sp.width + x) * 4
                for c in 0 ..< 4 where abs(Int(sp.pixels[o + c]) - Int(op.pixels[o + c])) > Self.tolerance {
                    outsideDiffs += 1; break
                }
            }
        }
        // A handful of stray antialiased pixels at the footprint margin are
        // tolerated; a disturbed far element would be thousands.
        #expect(outsideDiffs <= 40, "\(url.lastPathComponent) \(edit): \(outsideDiffs) pixels changed OUTSIDE the edited element footprint")
    }

    /// The device-space footprint of an element (text falls back to a reference
    /// box, since a text run carries no geometry bounds).
    private func elementFootprintDevice(_ element: Element) -> CGRect {
        if !element.boundsDevice.isNull { return element.boundsDevice }
        if let image = element.image { return image.destRectDevice.standardized }
        if let text = element.text {
            let scale = SceneSynthesis.averageScale(element.transform)
            let em = max(6, Double(abs(text.logicalHeight)) * scale)
            let ref = CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform)
            let len = Double(max(text.string.count, 8)) + 4
            return CGRect(x: ref.x - em, y: ref.y - em * 1.6, width: em * len, height: em * 2.4)
        }
        return .null
    }

    // MARK: - (d) byte accounting

    private func checkByteAccounting(url: URL, scene: Scene, data: Data) {
        // Decompress EMZ/WMZ to the raw metafile bytes for parsing.
        let raw = (try? OpenedMetafile.open(data))?.data ?? data
        if scene.source.format == .emf {
            guard let file = try? EMFFile.parse(raw) else {
                Issue.record("\(url.lastPathComponent): exported EMF did not parse"); return
            }
            #expect(file.diagnostics.isEmpty, "\(url.lastPathComponent): exported EMF has diagnostics \(file.diagnostics)")
            #expect(Int(file.header.records) == file.records.count,
                    "\(url.lastPathComponent): header Records \(file.header.records) != \(file.records.count)")
        } else {
            guard let file = try? WMFFile.parse(raw) else {
                Issue.record("\(url.lastPathComponent): exported WMF did not parse"); return
            }
            // The header's advisory size matches what was actually written.
            let metafileWords = (18 + file.records.reduce(0) { $0 + $1.byteSize }) / 2
            let declared = Int(file.header.sizeLow) | (Int(file.header.sizeHigh) << 16)
            #expect(declared == metafileWords, "\(url.lastPathComponent): WMF Size \(declared) != \(metafileWords)")
            guard let reimport = try? SceneImporter.import(data: data) else {
                Issue.record("\(url.lastPathComponent): exported WMF did not re-import"); return
            }
            #expect(reimport.partition.isComplete, "\(url.lastPathComponent): exported WMF partition incomplete")
        }
    }

    // MARK: - Insert

    @Test func insertRendersNewElementsOnTop() throws {
        let url = EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")
        var scene = try SceneImporter.import(data: try Data(contentsOf: url))

        let rect = Element(
            id: 90_001, kind: .rect,
            geometryDevice: ScenePath(CGPath(rect: CGRect(x: 20, y: 20, width: 120, height: 90), transform: nil)),
            transform: .identity,
            style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.95, green: 0.15, blue: 0.15), evenOdd: false)),
            provenance: Provenance(sourceRecordIndices: [])
        )
        // A SceneText has no from-scratch public init, so borrow one from a text
        // corpus file and retarget it.
        let textSource = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-text.emf")))
        var text = try #require(textSource.editableElements.first { $0.kind == .text }?.text)
        text.string = "NEW"
        text.referenceLogical = CGPoint(x: 1300, y: 6000)
        let textEl = Element(
            id: 90_002, kind: .text,
            geometryDevice: ScenePath(),
            transform: try #require(textSource.editableElements.first { $0.kind == .text }).transform,
            text: text,
            provenance: Provenance(sourceRecordIndices: [])
        )
        scene.insert(rect, at: scene.layers[0].elements.count)
        scene.insert(textEl, at: scene.layers[0].elements.count)

        #expect(SceneExporter.isEdited(scene))
        let result = try SceneExporter.export(scene, as: .emf)

        // The new filled rect's colour appears in the exported render where the
        // rect sits — it draws on top.
        guard let img = PixelImage(renderBytes(result.data, scale: Self.renderScale)!) else {
            Issue.record("render failed"); return
        }
        // Centre of the rect in device (80, 65) → pixel.
        let p = targetPixelRect(CGRect(x: 70, y: 55, width: 20, height: 20), pageBounds: scene.pageBoundsDevice, targetW: img.width, targetH: img.height)
        let cx = Int(p.midX), cy = Int(p.midY)
        let o = (cy * img.width + cx) * 4
        #expect(img.pixels[o] > 180 && img.pixels[o + 1] < 120, "new red rect not drawn on top at centre")

        // Re-import keeps the new elements as editable content.
        let reimport = try SceneImporter.import(data: result.data)
        #expect(reimport.editableElements.count == scene.editableElements.count)
    }

    /// A new element inserted in the MIDDLE of the z-order renders at that depth,
    /// not always on top. Inserting the same opaque rect at the bottom vs the top
    /// of the layer produces different renders (the source elements it overlaps
    /// obscure it or not depending on z).
    @Test func insertHonoursZPosition() throws {
        let url = EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")
        let base = try SceneImporter.import(data: try Data(contentsOf: url))

        func makeRect() -> Element {
            Element(id: 95_001, kind: .rect,
                geometryDevice: ScenePath(CGPath(rect: CGRect(x: 60, y: 60, width: 260, height: 160), transform: nil)),
                transform: .identity,
                style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.1, green: 0.8, blue: 0.9), evenOdd: false)),
                provenance: Provenance(sourceRecordIndices: []))
        }
        var bottom = base
        bottom.insert(makeRect(), at: 0)
        var top = base
        top.insert(makeRect(), at: top.layers[0].elements.count)

        let bottomData = try SceneExporter.export(bottom, as: .emf).data
        let topData = try SceneExporter.export(top, as: .emf).data
        guard let bImg = renderBytes(bottomData, scale: Self.renderScale),
              let tImg = renderBytes(topData, scale: Self.renderScale) else {
            Issue.record("render failed"); return
        }
        let diff = compareImages(bImg, tImg, tolerance: Self.tolerance)
        // The house's foreground polygons overlap the rect, so bottom != top.
        #expect(diff.differingFraction > 0.01, "z-position ignored: bottom and top inserts render the same")

        // Both re-import with the new element present.
        #expect((try? SceneImporter.import(data: bottomData))?.editableElements.count == base.editableElements.count + 1)
        #expect((try? SceneImporter.import(data: topData))?.editableElements.count == base.editableElements.count + 1)
    }

    // MARK: - Kind preservation (E2 resize handles depend on it)

    @Test func editedKindsArePreserved() throws {
        // One representative element of each recoverable kind, across committed
        // GDI EMF files: a translate must re-import as the same kind.
        let recoverable: Set<ElementKind> = [.rect, .ellipse, .polygon, .polyline, .bezier]
        var seen = Set<ElementKind>()
        var report = "\n=== kind preservation ===\n"
        for url in EditTestPaths.committedMetafiles() where url.pathExtension == "emf" {
            guard let data = try? Data(contentsOf: url),
                  let base = try? SceneImporter.import(data: data), base.source.renderPath == .gdi else { continue }
            for element in base.editableElements where recoverable.contains(element.kind) && !seen.contains(element.kind) {
                let g = element.geometryDevice.boundingBox
                guard !g.isNull else { continue }
                var scene = base
                try scene.translate([element.id], dx: 10, dy: 5)
                guard let out = try? SceneExporter.export(scene, as: .emf),
                      let re = try? SceneImporter.import(data: out.data) else { continue }
                let moved = g.offsetBy(dx: 10, dy: 5)
                let match = re.editableElements.first { $0.kind == element.kind && boundsClose($0.geometryDevice.boundingBox, moved, tol: 6) }
                #expect(match != nil, "\(url.lastPathComponent): \(element.kind) did not re-import as \(element.kind) at the moved position")
                report += "\(element.kind) from \(url.lastPathComponent): preserved=\(match != nil)\n"
                seen.insert(element.kind)
            }
        }
        // The committed corpus has no rect/ellipse editable element, so prove
        // those two through the (shared) synthesis path by inserting them.
        let base = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")))
        for (kind, cg) in [(ElementKind.rect, CGPath(rect: CGRect(x: 40, y: 40, width: 120, height: 90), transform: nil)),
                           (ElementKind.ellipse, CGPath(ellipseIn: CGRect(x: 200, y: 40, width: 120, height: 90), transform: nil))] {
            var scene = base
            scene.insert(Element(id: 97_000, kind: kind, geometryDevice: ScenePath(cg), transform: .identity,
                style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.2, green: 0.6, blue: 0.9), evenOdd: false)),
                provenance: Provenance(sourceRecordIndices: [])), at: scene.layers[0].elements.count)
            let out = try SceneExporter.export(scene, as: .emf)
            let re = try SceneImporter.import(data: out.data)
            #expect(re.editableElements.contains { $0.kind == kind }, "inserted \(kind) did not re-import as \(kind)")
            report += "\(kind) (inserted): preserved=\(re.editableElements.contains { $0.kind == kind })\n"
            seen.insert(kind)
        }
        print(report + "kinds covered: \(seen.sorted { "\($0)" < "\($1)" }.map { "\($0)" }.joined(separator: ", "))")
        #expect(seen.contains(.rect) && seen.contains(.ellipse))
    }

    // MARK: - Hostile / typed errors

    @Test func crossContainerExportRoundTrips() throws {
        // Cross-container EMF→WMF and WMF→EMF are supported as of slice E1b2c: the
        // output parses and re-imports (fidelity is covered in the cross-format suite).
        let emf = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")))
        var edited = emf
        try edited.translate([emf.editableElements[0].id], dx: 1, dy: 1)
        let wmfOut = try SceneExporter.export(edited, as: .wmf)
        #expect(try WMFFile.parse(wmfOut.data).diagnostics.isEmpty, "EMF→WMF produced WMF diagnostics")
        #expect((try? SceneImporter.import(data: wmfOut.data)) != nil, "EMF→WMF did not re-import")

        let wmf = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-wmf-gdi-p2-star.wmf")))
        let emfOut = try SceneExporter.export(wmf, as: .emf)
        #expect(try EMFFile.parse(emfOut.data).diagnostics.isEmpty, "WMF→EMF produced EMF diagnostics")
        #expect((try? SceneImporter.import(data: emfOut.data)) != nil, "WMF→EMF did not re-import")
    }

    @Test func editingEMFPlusIsSupported() throws {
        // Editing an EMF+ file is implemented in slice E1b2a (an EMF+ overlay), so
        // an unchanged scene still re-emits byte-identically and an edited one
        // exports and re-imports with the edit visible (full coverage is in
        // `SceneEMFPlusExportTests`).
        let scene = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("handmade-emfplus-shapes.emf")))
        _ = try SceneExporter.export(scene, as: .emf)
        var edited = scene
        try edited.translate([scene.editableElements[0].id], dx: 5, dy: 5)
        let result = try SceneExporter.export(edited, as: .emf)
        let reimport = try SceneImporter.import(data: result.data)
        #expect(reimport.editableElements.count == scene.editableElements.count)
        #expect(try EMFFile.parse(result.data).diagnostics.isEmpty)
    }

    @Test func wmfCoordinateOverflowThrowsTypedError() throws {
        var scene = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-wmf-gdi-p2-star.wmf")))
        // Push geometry far beyond the 16-bit WMF coordinate range.
        try scene.translate([scene.editableElements[0].id], dx: 5_000_000, dy: 0)
        var threw = false
        do { _ = try SceneExporter.export(scene, as: .wmf) }
        catch { threw = true }
        #expect(threw, "expected a typed WMF overflow error")
    }

    // MARK: - Geometry mapping helpers

    private func targetPixelRect(_ deviceRect: CGRect, pageBounds: CGRect, targetW: Int, targetH: Int) -> CGRect {
        let dw = max(pageBounds.width, 1), dh = max(pageBounds.height, 1)
        let sx = Double(targetW) / dw, sy = Double(targetH) / dh
        // device → CG target (y-up), then CG y → pixel row (top-left).
        func px(_ p: CGPoint) -> CGPoint {
            let cgx = sx * (p.x - pageBounds.minX)
            let cgy = sy * (p.y - pageBounds.minY)   // device y-down → pixel row directly
            return CGPoint(x: cgx, y: cgy)
        }
        let a = px(CGPoint(x: deviceRect.minX, y: deviceRect.minY))
        let b = px(CGPoint(x: deviceRect.maxX, y: deviceRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func boundsClose(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        guard !a.isNull, !b.isNull else { return false }
        return abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    private func colorClose(_ a: SceneColor?, _ b: SceneColor) -> Bool {
        guard let a else { return false }
        return abs(a.red - b.red) < 0.02 && abs(a.green - b.green) < 0.02 && abs(a.blue - b.blue) < 0.02
    }

    private func pct(_ f: Double) -> String { String(format: "%.3f%%", f * 100) }
}
