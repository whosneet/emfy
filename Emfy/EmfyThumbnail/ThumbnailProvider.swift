import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import QuickLookThumbnailing

/// The Finder thumbnail extension for the metafile family.
///
/// `QLThumbnailProvider` (macOS 10.15+): the system requests a thumbnail no
/// larger than `request.maximumSize`; we open and render through EMFKit's one
/// front door — the same clean-room engine the app uses — aspect-fitted into
/// that box, on a white background. A gzip .emz / .wmz wrapper is unwrapped by
/// `OpenedMetafile.open`; the EMF or WMF is parsed once by
/// `MetafileRenderer.prepare`. Log-and-skip runs end to end (primer §8): a file
/// with diagnostics still thumbnails from its best partial render; a file EMFKit
/// cannot open yields `handler(nil, error)` and Finder keeps the generic icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let prepared: MetafileRenderer.Prepared
        do {
            let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
            let opened = try OpenedMetafile.open(data)
            guard let result = MetafileRenderer.prepare(opened) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            prepared = result
        } catch {
            handler(nil, error)
            return
        }

        // Aspect-fit into the requested maximum. The context size is in points;
        // Quick Look scales it by `request.scale` for the backing bitmap.
        let size = ThumbnailSizing.contextSize(
            for: prepared.naturalSize,
            maximumSize: request.maximumSize,
            minimumSize: request.minimumSize
        )
        let target = CGRect(origin: .zero, size: size)

        let reply = QLThumbnailReply(contextSize: size) { (context: CGContext) -> Bool in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(target)
            _ = MetafileRenderer.render(prepared, into: context, target: target)
            return true
        }
        handler(reply, nil)
    }
}
