import CoreGraphics
import EMFEdit
import Foundation

/// A single-page, true-vector PDF of an editable `Scene` (F1). It mirrors
/// `MetafileRenderer.pdfData` — a white page sized to the scene's device page, the
/// drawing played in through `SceneRenderer` — so that when a document is being
/// edited (or a selection subset is copied), Print / Copy / drag produce the same
/// kind of vector PDF the original-metafile path produces, reflecting the edited
/// content (design calls 1 and 2). Pure and `Sendable`; callers run it off-main.
enum ScenePDF {
    /// The page-size clamp `MetafileRenderer` uses, so a degenerate or absurd page
    /// never produces an unopenable PDF.
    private static let minSide: CGFloat = 1
    private static let maxSide: CGFloat = 200 * 72   // 200 inches, PDF's practical limit

    /// The PDF bytes for `scene`, or `nil` if the PDF context cannot be created.
    static func data(_ scene: Scene) -> Data? {
        let size = clamp(scene.pageSizeDevice)
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        SceneRenderer.render(scene, into: context, target: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func clamp(_ size: CGSize) -> CGSize {
        func c(_ value: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0 else { return minSide }
            return min(max(value, minSide), maxSide)
        }
        return CGSize(width: c(size.width), height: c(size.height))
    }
}
