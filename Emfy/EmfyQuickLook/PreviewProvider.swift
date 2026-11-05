import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import QuickLookUI

/// The data-based Quick Look preview extension for the metafile family.
///
/// `QLPreviewProvider` (macOS 12+) + `QLPreviewingController`: the system hands
/// us the file URL, we open and render it through EMFKit's one front door — the
/// same clean-room engine the app uses — into a bitmap `QLPreviewReply`. A gzip
/// .emz / .wmz wrapper is unwrapped by `OpenedMetafile.open`; the EMF or WMF is
/// parsed once by `MetafileRenderer.prepare`. Log-and-skip runs end to end
/// (primer §8): a file with diagnostics still previews from its best partial
/// render; only a file EMFKit cannot open at all throws, and Quick Look then
/// falls back to the generic icon.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Aspect-fit long-edge cap for the preview context, in points, at
    /// **Standard** sharpness. Held at 2048 so a near-square large-bounds file
    /// stays within a Quick Look extension's tight memory budget: 2048² is 4 MP
    /// (16 MP at 2x on Retina), versus the old 4096, leaving room for the parse
    /// array and any DIB decode before jetsam.
    private static let maxLongEdgeStandard = 2048
    /// The **High** sharpness cap (S1b-2b, Settings › Rendering › Quick Look).
    /// Raised to 3072 — a 2.25× area bump over Standard. Measured on a near-square
    /// 3000×3000 worst case: 3072 renders at 3000 (the Mac downscales only), a
    /// 34.3 MB bitmap / ~41 MB peak footprint, comfortably under the ~67 MB the old
    /// 4096 cap used (the one the Standard comment above rejected). A ≥3072 px file
    /// is capped at 3072 → 36 MB bitmap / ~43 MB peak. Only files whose natural
    /// long edge exceeds the Standard cap are affected; the Mac preview never
    /// upscales a smaller drawing.
    private static let maxLongEdgeHigh = 3072

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
        // Throws on a broken gzip wrapper; returns nil for an unrecognised or
        // header-less input — Quick Look then shows the generic icon. Anything
        // past a valid header renders.
        let opened = try OpenedMetafile.open(data)
        guard let prepared = MetafileRenderer.prepare(opened) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The user's Rendering + Quick Look choices from the App Group, read once
        // per request (S1b-2b). Previews stay white; High sharpness raises the cap.
        let shared = SharedRenderSettings.load(from: AppGroup.defaults())
        let cap = shared.previewSharpness == .high ? Self.maxLongEdgeHigh : Self.maxLongEdgeStandard
        let size = PreviewSizing.contextSize(
            for: prepared.naturalSize,
            maxLongEdge: cap
        )

        return QLPreviewReply(
            contextSize: size,
            isBitmap: true,
            drawUsing: { (context: CGContext, _: QLPreviewReply) in
                let target = CGRect(origin: .zero, size: size)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(target)
                _ = MetafileRenderer.render(prepared, into: context, target: target, options: shared.renderOptions)
            }
        )
    }
}
