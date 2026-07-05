import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import QuickLookThumbnailing

/// The Finder thumbnail extension for EMF files.
///
/// `QLThumbnailProvider` (macOS 10.15+): the system requests a thumbnail no
/// larger than `request.maximumSize`; we parse and render through EMFKit —
/// the same clean-room engine the app uses — aspect-fitted into that box, on a
/// white background. Log-and-skip runs end to end (primer §8): a file with
/// diagnostics still thumbnails from its best partial render; a file EMFKit
/// cannot parse yields `handler(nil, error)` and Finder keeps the generic icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let file: EMFFile
        do {
            let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
            file = try EMFFile.parse(data)
        } catch {
            handler(nil, error)
            return
        }

        // Aspect-fit into the requested maximum. The context size is in points;
        // Quick Look scales it by `request.scale` for the backing bitmap.
        let size = ThumbnailSizing.contextSize(
            for: file.header,
            maximumSize: request.maximumSize,
            minimumSize: request.minimumSize
        )
        let target = CGRect(origin: .zero, size: size)

        let reply = QLThumbnailReply(contextSize: size) { (context: CGContext) -> Bool in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(target)
            _ = EMFRenderer.render(file, into: context, target: target)
            return true
        }
        handler(reply, nil)
    }
}
