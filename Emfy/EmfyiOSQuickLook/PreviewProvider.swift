import CoreGraphics
import CoreText
import EMFParse
import EMFRender
import Foundation
import QuickLook

/// The data-based Quick Look preview extension for the metafile family on iOS.
///
/// `QLPreviewProvider` + `QLPreviewingController` (iOS 15+): the system hands us
/// the file URL, we open and render it through EMFKit's one front door — the
/// same clean-room engine the app and the Mac extensions use — into a bitmap
/// `QLPreviewReply`. A gzip .emz / .wmz wrapper is unwrapped by
/// `OpenedMetafile.open`; the EMF or WMF is parsed once by
/// `MetafileRenderer.prepare`. Log-and-skip runs end to end (primer §8): a file
/// with diagnostics still previews from its best partial render; a file EMFKit
/// cannot open at all shows a plain "couldn't read" message rather than a blank
/// or a crash.
///
/// This mirrors the Mac `PreviewProvider`: the same front-door, data-based
/// pattern and the same long-edge cap, with the extension's memory kept bounded.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Long-edge pixel size for the preview bitmap. A data-based `QLPreviewReply`
    /// bitmap is exactly `contextSize` pixels (no `request.scale` multiply — the
    /// preview has no scale), so every preview renders with its long edge at this
    /// value: the vector is scaled up or down to it, aspect preserved. Held at
    /// 2048, matching the Mac extension, so a preview stays crisp even on an iPad
    /// Quick Look surface up to ~2752 px wide, rather than rendering at a small
    /// natural size and being upscaled soft.
    ///
    /// At the long edge a square worst case is `2048² × 4` = 16 MB; the extension
    /// process peaked at ~25 MB in the iPhone 18 Pro (iOS 27.2) simulator (I4;
    /// vmmap peak) — ~4.2 MP, under the ~16 MP (`4096²`) ceiling and within an
    /// iOS Quick Look extension's budget (Apple publishes no official figure; the
    /// conservative ~30 MB figure cited for the tightest extensions leaves
    /// headroom). A large-bounds or hostile-bounds file is scaled down to this
    /// long edge too, so the bitmap never tracks the file's declared bounds.
    /// Simulator figures are indicative only; real-device peak is an I5
    /// release-blocker check.
    private static let maxLongEdge: CGFloat = 2048

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Anything past a valid header renders best-effort. A broken gzip
        // wrapper, an unrecognised format, or a header-less input yields the
        // plain message below instead of a crash or a silent blank canvas.
        guard let data = try? Data(contentsOf: request.fileURL, options: .mappedIfSafe),
              let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else {
            return Self.unreadableReply()
        }

        let size = Self.previewPixelSize(for: prepared.naturalSize)

        return QLPreviewReply(contextSize: size, isBitmap: true) { (context: CGContext, _: QLPreviewReply) in
            let target = CGRect(origin: .zero, size: size)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(target)
            _ = MetafileRenderer.render(prepared, into: context, target: target)
        }
    }

    /// The preview bitmap's pixel size: the natural size (aspect preserved)
    /// scaled so the long edge is exactly `maxLongEdge`, each side at least 1 px.
    /// Small drawings are scaled up and large or hostile ones down, so the
    /// preview is rendered crisply at the cap on any Quick Look surface while the
    /// bitmap stays bounded.
    static func previewPixelSize(for naturalSize: CGSize) -> CGSize {
        let width = naturalSize.width.isFinite && naturalSize.width > 0 ? naturalSize.width : 1
        let height = naturalSize.height.isFinite && naturalSize.height > 0 ? naturalSize.height : 1
        let longEdge = max(width, height)
        let scale = maxLongEdge / longEdge
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    /// A small white reply carrying the plain "couldn't read" message, drawn with
    /// CoreText so the extension needs no UIKit. Shown only when EMFKit cannot
    /// open the file at all.
    private static func unreadableReply() -> QLPreviewReply {
        let size = CGSize(width: 480, height: 320)
        return QLPreviewReply(contextSize: size, isBitmap: true) { (context: CGContext, _: QLPreviewReply) in
            let rect = CGRect(origin: .zero, size: size)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
            drawCenteredMessage("Emfy couldn’t read this file.", into: context, in: rect)
        }
    }

    /// Draws a single centred line of text into a Core Graphics bitmap context
    /// (origin bottom-left) using CoreText only.
    private static func drawCenteredMessage(_ message: String, into context: CGContext, in rect: CGRect) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let color = CGColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, message as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x = (rect.width - bounds.width) / 2 - bounds.minX
        let y = (rect.height - bounds.height) / 2 - bounds.minY
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
