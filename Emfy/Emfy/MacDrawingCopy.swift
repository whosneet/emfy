import AppKit
import CoreGraphics
import EMFEdit
import EMFRender
import Foundation

/// Mac Edit ▸ Copy of the drawing (F1 design call 2). It puts the drawing on the
/// pasteboard as vector **PDF** and **PNG** (at the Settings default scale, within the
/// shared area cap) — plus the original file's raw EMF when it cleanly applies — using
/// the pure `DrawingClipboard` plan. With a canvas selection in edit mode it copies
/// only the selected elements, rendered from a subset scene (as the E2b ghost does);
/// an edited document copies the edited scene.
@MainActor
enum MacDrawingCopy {
    /// Renders off-main, then writes the representations to `NSPasteboard` and confirms
    /// with a toast.
    static func copy(
        session: DocumentSession,
        prepared: MetafileRenderer.Prepared,
        entry: RecentEntry,
        store: RecentsStore,
        settings: EmfySettings,
        selection: Set<Int>,
        toast: ToastCenter
    ) {
        let editing = session.editing == .editing
        let source = OutputSource.forCopy(
            isEditing: editing, hasDiverged: session.hasDivergedFromOpened, selection: selection)
        let isSubset: Bool = { if case .selectionSubset = source { return true }; return false }()
        let isEdited = source == .editedScene || isSubset
        let originalType: DrawingClipboard.OriginalType =
            entry.formatLabel.uppercased() == "EMF" ? .emf : .other
        let representations = DrawingClipboard.representations(
            naturalSize: prepared.naturalSize,
            pngScale: settings.defaultPNGScale.multiplier,
            areaCap: ExportScale.areaCap,
            isEdited: isEdited, isSubset: isSubset, originalType: originalType)

        let includesOriginal = representations.contains(.originalEMF)
        let background: RenderBackground = settings.pngBackground == .transparent ? .transparent : .white
        let options = settings.renderOptions
        let pngScale = settings.defaultPNGScale.multiplier
        // Snapshot the scene inputs on the main actor before the detached render.
        let editedScene = session.editingScene
        let subsetScene = isSubset ? CopySubset.scene(editedScene, ids: selection) : nil

        Task { @MainActor in
            var emfBytes: Data?
            if includesOriginal { emfBytes = try? await store.resolveData(for: entry) }

            let rendered = await Task.detached(priority: .userInitiated) {
                Rendered(
                    pdf: makePDF(source, prepared: prepared, editedScene: editedScene, subsetScene: subsetScene, options: options),
                    png: makePNG(source, prepared: prepared, editedScene: editedScene, subsetScene: subsetScene,
                                 pngScale: pngScale, background: background, options: options))
            }.value

            guard rendered.pdf != nil || rendered.png != nil else {
                toast.show("Couldn’t copy this drawing", systemImage: "exclamationmark.triangle")
                return
            }
            write(pdf: rendered.pdf, png: rendered.png, emf: includesOriginal ? emfBytes : nil)
            toast.show(isSubset ? "Selection copied" : "Drawing copied", systemImage: "doc.on.doc")
        }
    }

    private struct Rendered: Sendable {
        let pdf: Data?
        let png: Data?
    }

    /// Writes the representations to the general pasteboard as one item carrying every
    /// type, so a paste target picks its richest (PDF first).
    static func write(pdf: Data?, png: Data?, emf: Data?) {
        let item = NSPasteboardItem()
        if let pdf { item.setData(pdf, forType: .pdf) }
        if let png { item.setData(png, forType: .png) }
        if let emf { item.setData(emf, forType: NSPasteboard.PasteboardType(DrawingClipboard.emfTypeIdentifier)) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    // MARK: - Rendering (off-main; `Sendable` inputs)

    nonisolated static func makePDF(
        _ source: OutputSource, prepared: MetafileRenderer.Prepared,
        editedScene: Scene?, subsetScene: Scene?, options: RenderOptions
    ) -> Data? {
        switch source {
        case .selectionSubset:
            return subsetScene.flatMap { ScenePDF.data($0) }
        case .editedScene:
            return editedScene.flatMap { ScenePDF.data($0) } ?? MetafileRenderer.pdfData(prepared, options: options)
        case .original:
            return MetafileRenderer.pdfData(prepared, options: options)
        }
    }

    nonisolated static func makePNG(
        _ source: OutputSource, prepared: MetafileRenderer.Prepared,
        editedScene: Scene?, subsetScene: Scene?,
        pngScale: Int, background: RenderBackground, options: RenderOptions
    ) -> Data? {
        switch source {
        case .selectionSubset:
            guard let scene = subsetScene else { return nil }
            let selection = ExportScale.select(
                baseWidth: Int(scene.pageSizeDevice.width.rounded()),
                baseHeight: Int(scene.pageSizeDevice.height.rounded()),
                requested: pngScale, areaCap: ExportScale.areaCap)
            return SceneRenderer.makeImage(scene, scale: CGFloat(selection.multiplier)).flatMap { EMFExport.pngData(from: $0) }
        case .editedScene:
            guard let scene = editedScene else { return originalPNG(prepared, pngScale: pngScale, background: background, options: options) }
            let selection = ExportScale.select(
                baseWidth: Int(scene.pageSizeDevice.width.rounded()),
                baseHeight: Int(scene.pageSizeDevice.height.rounded()),
                requested: pngScale, areaCap: ExportScale.areaCap)
            return SceneRenderer.makeImage(scene, scale: CGFloat(selection.multiplier)).flatMap { EMFExport.pngData(from: $0) }
        case .original:
            return originalPNG(prepared, pngScale: pngScale, background: background, options: options)
        }
    }

    nonisolated private static func originalPNG(
        _ prepared: MetafileRenderer.Prepared, pngScale: Int, background: RenderBackground, options: RenderOptions
    ) -> Data? {
        let selection = ExportScale.select(
            baseWidth: Int(prepared.naturalSize.width.rounded()),
            baseHeight: Int(prepared.naturalSize.height.rounded()),
            requested: pngScale, areaCap: ExportScale.areaCap)
        guard let (image, _) = MetafileRenderer.makeImage(
                prepared, scale: CGFloat(selection.multiplier), background: background, options: options) else { return nil }
        return EMFExport.pngData(from: image)
    }
}

/// Builds a subset `Scene` holding only the given element ids, with its page set to the
/// selection's device bounds, so a Copy/drag of a selection renders exactly those
/// elements tightly cropped (the same construction the E2b ghost uses).
enum CopySubset {
    static func scene(_ scene: Scene?, ids: Set<Int>) -> Scene? {
        guard let scene, !ids.isEmpty else { return nil }
        let selected = scene.elements.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        var bounds = CGRect.null
        for element in selected {
            let rect = element.selectionBoundsDevice
            if !rect.isNull { bounds = bounds.union(rect) }
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let layer = Layer(id: 0, name: "copy", elements: selected)
        return Scene(pageBoundsDevice: bounds, layers: [layer], partition: scene.partition, source: scene.source)
    }
}
