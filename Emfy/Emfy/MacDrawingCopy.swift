import AppKit
import CoreGraphics
import EMFEdit
import EMFRender
import Foundation
import UniformTypeIdentifiers

/// Mac Edit ▸ Copy of the drawing (F1 design call 2). The copy is driven through the
/// RESPONDER CHAIN — the viewer host's `.onCopyCommand` returns these item providers
/// to the single system Edit ▸ Copy (⌘C), so a focused text field (the inspector
/// fields, the text popover, the sidebar search) keeps its own ⌘C and the canvas is
/// copied only when no field is first responder. There is no second ⌘C menu item.
///
/// The provider carries the drawing as vector **PDF** and **PNG** (at the Settings
/// default scale, within the shared area cap) — plus the original file's raw EMF when
/// it cleanly applies. With a canvas selection in edit mode it copies only the
/// selected elements (a subset scene, as the E2b ghost does); an edited document
/// copies the edited scene. Each representation renders lazily, so ⌘C is cheap.
@MainActor
enum MacDrawingCopy {
    /// The item providers for the current drawing / selection, for `.onCopyCommand`.
    static func itemProviders(
        session: DocumentSession,
        prepared: MetafileRenderer.Prepared,
        entry: RecentEntry,
        settings: EmfySettings,
        selection: Set<Int>
    ) -> [NSItemProvider] {
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
        let editedScene = session.editingScene
        let subsetScene = isSubset ? CopySubset.scene(editedScene, ids: selection) : nil
        let bookmark = entry.bookmark

        let provider = NSItemProvider()
        provider.suggestedName = entry.baseName

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pdf.identifier, visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                let data = makePDF(source, prepared: prepared, editedScene: editedScene, subsetScene: subsetScene, options: options)
                completion(data, data == nil ? CopyError.renderFailed : nil)
            }
            return nil
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                let data = makePNG(source, prepared: prepared, editedScene: editedScene, subsetScene: subsetScene,
                                   pngScale: pngScale, background: background, options: options)
                completion(data, data == nil ? CopyError.renderFailed : nil)
            }
            return nil
        }

        if includesOriginal {
            provider.registerDataRepresentation(
                forTypeIdentifier: DrawingClipboard.emfTypeIdentifier, visibility: .all
            ) { completion in
                Task.detached(priority: .userInitiated) {
                    let data = resolveOriginalBytes(bookmark: bookmark)
                    completion(data, data == nil ? CopyError.renderFailed : nil)
                }
                return nil
            }
        }

        return [provider]
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
            return sceneImagePNG(scene, pngScale: pngScale, background: background)
        case .editedScene:
            guard let scene = editedScene else { return originalPNG(prepared, pngScale: pngScale, background: background, options: options) }
            return sceneImagePNG(scene, pngScale: pngScale, background: background)
        case .original:
            return originalPNG(prepared, pngScale: pngScale, background: background, options: options)
        }
    }

    nonisolated private static func sceneImagePNG(_ scene: Scene, pngScale: Int, background: RenderBackground) -> Data? {
        let selection = ExportScale.select(
            baseWidth: Int(scene.pageSizeDevice.width.rounded()),
            baseHeight: Int(scene.pageSizeDevice.height.rounded()),
            requested: pngScale, areaCap: ExportScale.areaCap)
        // Honour the Export › PNG background setting for the edited scene exactly as the
        // viewer export does for the original (the scene renderer defaulted to white).
        return SceneRenderer.makeImage(scene, scale: CGFloat(selection.multiplier), background: background)
            .flatMap { EMFExport.pngData(from: $0) }
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

    /// Resolves the original bytes from the recents bookmark off-main, taking and
    /// releasing the macOS security scope around the read.
    nonisolated private static func resolveOriginalBytes(bookmark: Data) -> Data? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: RecentsStore.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private enum CopyError: Error { case renderFailed }
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
