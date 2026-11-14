import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import QuickLookThumbnailing

/// The Files / Spotlight thumbnail extension for the metafile family on iOS.
///
/// `QLThumbnailProvider` (iOS 11+): the system requests a thumbnail no larger
/// than `request.maximumSize`; we open and render through EMFKit's one front
/// door — the same clean-room engine the app and the Mac extensions use —
/// aspect-fitted into that box. A gzip .emz / .wmz wrapper is unwrapped by
/// `OpenedMetafile.open`; the EMF or WMF is parsed once by
/// `MetafileRenderer.prepare`. Log-and-skip runs end to end (primer §8): a file
/// with diagnostics still thumbnails from its best partial render; a file EMFKit
/// cannot open yields `handler(nil, error)` and Files keeps the generic icon.
///
/// The drawing sits on a white page, identical to the Mac `EmfyThumbnail`
/// treatment: a metafile assumes a white page, so black text and thin lines stay
/// legible on the Files tile in both light and dark appearance (a transparent
/// background would make them invisible against a dark tile).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let prepared: MetafileRenderer.Prepared
        do {
            let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
            let opened = try OpenedMetafile.open(data)
            // A sandboxed extension caps how many records it parses and translates
            // (M1 / C5f2): a crafted metafile renders its best partial output
            // rather than jetsam-killing the process.
            let prepareOptions = RenderOptions(
                playbackRecordBudget: SharedRenderSettings.extensionPlaybackRecordBudget)
            guard let result = MetafileRenderer.prepare(opened, options: prepareOptions) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            prepared = result
        } catch {
            handler(nil, error)
            return
        }

        // The user's Rendering + Quick Look choices from the App Group, read once
        // per request (S1b-2b).
        let shared = SharedRenderSettings.load(from: AppGroup.defaults())

        // Aspect-fit into the requested maximum. `contextSize` is in points;
        // iOS creates the backing `CGBitmapContext` at `contextSize × request.scale`
        // pixels with no CTM pre-scale (QLThumbnailReply.h: "the size of the
        // context will be (scale * x, scale * y)"). So the drawing block must
        // target the context's real pixel extent, not the point size — otherwise
        // the page fills only `1/scale` of the bitmap in the bottom-left corner.
        let size = ThumbnailSizing.contextSize(
            for: prepared.naturalSize,
            maximumSize: request.maximumSize,
            minimumSize: request.minimumSize
        )
        let whitePage = shared.thumbnailBackground == .white

        let reply = QLThumbnailReply(contextSize: size) { (context: CGContext) -> Bool in
            let target = CGRect(
                x: 0, y: 0,
                width: CGFloat(context.width),
                height: CGFloat(context.height)
            )
            // White the page for `.white` (as before) so dark ink stays legible on
            // the Files tile in dark mode; `.transparent` leaves the context's
            // alpha clear, the in-context equivalent of `RenderBackground.transparent`
            // (S1b-2b, thumbnails only).
            if whitePage {
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(target)
            }
            _ = MetafileRenderer.render(prepared, into: context, target: target, options: shared.renderOptions)
            return true
        }
        handler(reply, nil)
    }
}
