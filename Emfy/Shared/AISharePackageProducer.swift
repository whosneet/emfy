import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation

// MARK: - Building the Send-to-AI package off-main (A3b)
//
// The IO/parse half of "Send to AI…": from the drawing's resolved bytes and the
// viewer's in-hand facts (its Copy All Text, its record count, the render source) it
// produces the PNG and the summary string the system share sheet carries. Pure data
// in, `Sendable` data out, so both the Mac (NSSharingServicePicker) and iOS
// (UIActivityViewController) viewers run it on a detached task and present the result.
//
// Emfy sends nothing: this only assembles bytes. The original file is carried only when
// the user opted in. This file is app-target only (it reaches the F4 info helpers and
// the format labels), so the pure `AISharePackage` stays dependency-light for its tests.

enum AISharePackageProducer {
    /// The assembled package: the PNG render, the summary text, and — only when opted in
    /// — the original file's bytes for the share sheet to attach.
    struct Package: Sendable {
        var pngData: Data?
        var summary: String
        var originalData: Data?
    }

    /// Builds the package off-main. `allText` is the viewer's Copy All Text (already
    /// honouring the cached-OCR rule); `recordCount` is the walker's own count; the PNG
    /// renders from `source` (the edited scene when diverged, else the original). The
    /// page size in millimetres comes from the original EMF header ([MS-EMF] §2.2.9).
    static func make(
        resolvedData: Data,
        fileName: String,
        allText: String,
        recordCount: Int,
        source: OutputSource,
        prepared: MetafileRenderer.Prepared,
        editedScene: Scene?,
        background: RenderBackground,
        options: RenderOptions,
        includeOriginal: Bool
    ) -> Package {
        let pageSizeMM = (try? OpenedMetafile.open(resolvedData)).flatMap { AppIntentDrawing.pageSizeMM(opened: $0) }
        let summary = AISharePackage.summary(
            fileName: fileName,
            format: MetafileFormatLabel.names(for: fileName).full,
            pageSizeMM: pageSizeMM,
            recordCount: recordCount,
            allText: allText)
        let png = AISharePackageRender.pngData(
            source: source, prepared: prepared, editedScene: editedScene,
            background: background, options: options)
        return Package(pngData: png, summary: summary, originalData: includeOriginal ? resolvedData : nil)
    }
}
