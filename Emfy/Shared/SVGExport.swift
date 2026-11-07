import EMFEdit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The SVG export backend shared by the Mac and iOS viewers (F2). Unlike PNG/PDF —
/// which rasterise or paginate the already-parsed `MetafileRenderer.Prepared` — an
/// SVG is produced from the editable scene: the original metafile bytes are imported
/// to a `Scene` (`SceneImporter`), then serialised by EMFKit's clean-room
/// `SceneSVGExporter`. So this path takes the file's bytes, not a `Prepared`, and
/// runs off-main (import can be heavy on a large file).
enum SVGExport {
    /// The Mac/iOS export-failure wording for an SVG that could not be produced (the
    /// bytes did not import as a scene). Matches the PNG/PDF phrasing.
    static let generateFailure = "Emfy could not generate an SVG for this document."

    /// Imports the scene from `original` metafile bytes and serialises it to a
    /// standalone SVG document. Returns the bytes and any fidelity warnings, or `nil`
    /// when the bytes cannot be imported as a scene. Pure and `Sendable`: callers run
    /// it on a detached task and observe `Task.isCancelled` around it.
    static func data(from original: Data) -> (data: Data, warnings: [SVGExportWarning])? {
        guard let scene = try? SceneImporter.import(data: original) else { return nil }
        if Task.isCancelled { return nil }
        let result = SceneSVGExporter.export(scene)
        return (result.data, result.warnings)
    }
}

/// A write-only `FileDocument` carrying already-serialised SVG bytes, for
/// `.fileExporter`. Read is unsupported — it only ever writes (mirrors
/// `PNGExportDocument`/`PDFExportDocument`).
struct SVGExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.svg]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
