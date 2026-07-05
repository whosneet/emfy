import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import QuickLookUI

/// The data-based Quick Look preview extension for EMF files.
///
/// `QLPreviewProvider` (macOS 12+) + `QLPreviewingController`: the system hands
/// us the file URL, we parse and render through EMFKit — the same clean-room
/// engine the app uses — into a bitmap `QLPreviewReply`. Log-and-skip runs
/// end to end (primer §8): a file with diagnostics still previews from its best
/// partial render; only a file EMFKit cannot even give a header for throws, and
/// Quick Look then falls back to the generic icon.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Aspect-fit long-edge cap for the preview context, in points.
    private static let maxLongEdge = 4096

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
        // Throws EMFParseError on a headerless/invalid file — Quick Look then
        // shows the generic icon. Anything past a valid header renders.
        let file = try EMFFile.parse(data)
        let size = PreviewSizing.contextSize(
            for: file.header,
            maxLongEdge: Self.maxLongEdge
        )

        return QLPreviewReply(
            contextSize: size,
            isBitmap: true,
            drawUsing: { (context: CGContext, _: QLPreviewReply) in
                let target = CGRect(origin: .zero, size: size)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(target)
                _ = EMFRenderer.render(file, into: context, target: target)
            }
        )
    }
}
