import AppKit
import EMFRender
import Foundation
import UniformTypeIdentifiers

/// The drag-out item provider for the Mac viewer (F1 design call 3).
///
/// **Drag-start choice:** a document-proxy drag handle in the toolbar, not an
/// ⌥-drag on the canvas. The viewer canvas is a custom `NSScrollView` that already
/// owns pan, magnify and (in edit mode) element-drag gestures; layering an ⌥-drag
/// hit-test on top of it is fragile and collides with edit-mode dragging. A toolbar
/// proxy handle is unambiguous, discoverable, and matches the title-bar proxy-icon
/// pattern — and it is only shown in viewer mode.
///
/// The provider carries the whole drawing as a vector **PDF file promise** (a Finder
/// drop yields "<name>.pdf"), a **PNG**, and — when the original is a plain EMF — the
/// **original file**. Each representation is produced lazily on a background queue
/// through the same renderer the exports use, so starting the drag is cheap.
@MainActor
enum MacDrawingDrag {
    /// Builds the drag item provider. `bookmark` + `originalIsEMF` add the original
    /// file promise when the source is a plain EMF; otherwise only PDF + PNG are
    /// offered (a WMF/edited drawing's bytes don't match the rendered output).
    static func itemProvider(
        prepared: MetafileRenderer.Prepared,
        baseName: String,
        pngScale: Int,
        background: RenderBackground,
        options: RenderOptions,
        bookmark: Data?,
        originalIsEMF: Bool
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = baseName

        // PDF file promise — the richest vector form; a Finder drop writes "<name>.pdf".
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                guard let data = MetafileRenderer.pdfData(prepared, options: options) else {
                    completion(nil, false, DragError.renderFailed); return
                }
                deliverFile(data, name: "\(baseName).pdf", completion: completion)
            }
            return nil
        }

        // PNG data at the Settings default scale, within the shared area cap.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                let selection = ExportScale.select(
                    baseWidth: Int(prepared.naturalSize.width.rounded()),
                    baseHeight: Int(prepared.naturalSize.height.rounded()),
                    requested: pngScale, areaCap: ExportScale.areaCap)
                guard let (image, _) = MetafileRenderer.makeImage(
                        prepared, scale: CGFloat(selection.multiplier), background: background, options: options),
                      let data = EMFExport.pngData(from: image) else {
                    completion(nil, DragError.renderFailed); return
                }
                completion(data, nil)
            }
            return nil
        }

        // The original EMF file, when it cleanly applies.
        if originalIsEMF, let bookmark {
            provider.registerFileRepresentation(
                forTypeIdentifier: DrawingClipboard.emfTypeIdentifier, fileOptions: [], visibility: .all
            ) { completion in
                Task.detached(priority: .userInitiated) {
                    guard let data = resolveOriginalBytes(bookmark: bookmark) else {
                        completion(nil, false, DragError.renderFailed); return
                    }
                    deliverFile(data, name: "\(baseName).emf", completion: completion)
                }
                return nil
            }
        }

        return provider
    }

    /// Writes `data` into a fresh `EmfyExport-*` temp directory (the launch sweep
    /// reclaims it) and hands the URL to the drop. `false` = the system copies it out.
    nonisolated private static func deliverFile(_ data: Data, name: String, completion: (URL?, Bool, Error?) -> Void) {
        let directory = ExportTemp.makeDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(MetafileExport.sanitisedFileName(name))
            try data.write(to: url, options: .atomic)
            completion(url, false, nil)
        } catch {
            completion(nil, false, error)
        }
    }

    /// Resolves the original bytes from the recents bookmark on the drag's background
    /// queue, taking and releasing the macOS security scope around the read.
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

    private enum DragError: Error { case renderFailed }
}
