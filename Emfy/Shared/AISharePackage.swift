import CoreGraphics
import EMFEdit
import EMFRender
import Foundation

// MARK: - "Send to AI…" package (A3b)
//
// Packages the open drawing for an AI app the user already has (ChatGPT, Claude, …)
// and hands it to the SYSTEM share sheet. Emfy itself sends nothing over the network
// (CLAUDE.md §10 security): it only assembles a PNG render, a plain-text summary, and
// — only when the user opts in — the original file, then lets the system share sheet
// route them to whichever app the user picks.
//
// Everything here is pure and off-main-safe: the summary format, the text cap, the
// 2× / 4096 px render-scale rule, the OCR-included rule, and the edited-vs-original
// source decision. The platform glue (NSSharingServicePicker on Mac, a
// UIActivityViewController on iOS) lives in the per-platform viewers and calls in here
// for the bytes. Drawing text is untrusted input to any model, so the summary carries
// only the sanitised, bounded Copy All Text output the rest of F3 already produces.

enum AISharePackage {
    /// The render multiplier for the shared PNG (a crisp 2×), before the long-side cap.
    static let pngScale: CGFloat = 2
    /// The hard cap on the PNG's long side in pixels, so a large drawing can't produce
    /// an enormous attachment (§8 — a bound on what leaves the app).
    static let maxLongSidePixels: CGFloat = 4096
    /// The cap on the summary's drawing text, matching the "Use Model"-friendly size a
    /// share target expects. Past it the text is truncated with a note.
    static let maxTextCharacters = 20_000

    // MARK: Render scale

    /// The effective render scale for `naturalSize`: 2×, reduced so the long side never
    /// exceeds `maxLongSidePixels`. A degenerate (zero) size falls back to 2×.
    static func renderScale(naturalSize: CGSize) -> CGFloat {
        let longSide = max(naturalSize.width, naturalSize.height)
        guard longSide > 0 else { return pngScale }
        return min(pngScale, maxLongSidePixels / longSide)
    }

    // MARK: Source decision

    /// The source for the shared render: always the WHOLE drawing — the edited scene
    /// when editing has diverged, else the original metafile. Send to AI never narrows
    /// to a canvas selection (unlike Copy), so this is `OutputSource.wholeDrawing`.
    static func outputSource(isEditing: Bool, hasDiverged: Bool) -> OutputSource {
        OutputSource.wholeDrawing(isEditing: isEditing, hasDiverged: hasDiverged)
    }

    // MARK: OCR-included rule

    /// Whether recognised picture text joins the summary: only when the OCR toggle is on
    /// AND results are already cached for this drawing. Send to AI never forces an OCR
    /// run — it includes picture text only when the viewer already has it.
    static func shouldIncludeOCR(ocrEnabled: Bool, hasCachedPictureText: Bool) -> Bool {
        ocrEnabled && hasCachedPictureText
    }

    /// The Copy All Text output for the summary, folding in picture (OCR) runs only when
    /// `includeOCR` is set. Picture runs land under copyAllText's own "Text in pictures:"
    /// heading; drawing runs always lead.
    static func combinedText(
        drawingRuns: [DrawingTextRun],
        pictureRuns: [DrawingTextRun],
        includeOCR: Bool
    ) -> String {
        DrawingTextExtractor.copyAllText(includeOCR ? drawingRuns + pictureRuns : drawingRuns)
    }

    // MARK: Text cap

    /// Truncates the drawing text to `maxTextCharacters`, reporting whether it was cut so
    /// the summary can append a note. Counts in characters, matching the documented cap.
    static func cappedText(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxTextCharacters else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: maxTextCharacters)
        return (String(text[..<end]), true)
    }

    // MARK: Summary text

    /// The plain-text summary that accompanies the PNG: file name, format, page size in
    /// millimetres (EMF only), the record count, then the drawing's text (capped). This
    /// is the exact text handed to the share sheet as an `NSString` / activity item.
    static func summary(
        fileName: String,
        format: String,
        pageSizeMM: CGSize?,
        recordCount: Int,
        allText: String
    ) -> String {
        var lines: [String] = [fileName, ""]
        lines.append("Format: \(format)")
        if let pageSizeMM {
            lines.append("Page size: \(mm(pageSizeMM.width)) × \(mm(pageSizeMM.height)) mm")
        }
        lines.append("Records: \(recordCount)")
        lines.append("")
        lines.append("Text in the drawing:")
        let capped = cappedText(allText)
        if capped.text.isEmpty {
            lines.append("(no text)")
        } else {
            lines.append(capped.text)
            if capped.truncated {
                lines.append("")
                lines.append("[Text truncated at \(maxTextCharacters) characters.]")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func mm(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

// MARK: - Shared PNG render for the package

/// Renders the Send-to-AI PNG from the chosen `OutputSource` at the package's 2× /
/// 4096 px scale, off-main and cross-platform (no AppKit/UIKit). The edited scene is
/// used when the source calls for it, else the prepared original — the same F1 rule
/// Copy and Print follow.
enum AISharePackageRender {
    /// The PNG bytes for `source`, or nil if the render fails. `background` and
    /// `options` carry the Export / render settings into the raster.
    static func pngData(
        source: OutputSource,
        prepared: MetafileRenderer.Prepared,
        editedScene: Scene?,
        background: RenderBackground,
        options: RenderOptions
    ) -> Data? {
        switch source {
        case .editedScene:
            if let scene = editedScene, let data = scenePNG(scene) { return data }
            return originalPNG(prepared, background: background, options: options)
        case .selectionSubset:
            // Send to AI never narrows to a subset; treat it as the whole original.
            return originalPNG(prepared, background: background, options: options)
        case .original:
            return originalPNG(prepared, background: background, options: options)
        }
    }

    private static func scenePNG(_ scene: Scene) -> Data? {
        let scale = AISharePackage.renderScale(naturalSize: scene.pageSizeDevice)
        return SceneRenderer.makeImage(scene, scale: scale).flatMap { EMFExport.pngData(from: $0) }
    }

    private static func originalPNG(
        _ prepared: MetafileRenderer.Prepared, background: RenderBackground, options: RenderOptions
    ) -> Data? {
        let scale = AISharePackage.renderScale(naturalSize: prepared.naturalSize)
        guard let (image, _) = MetafileRenderer.makeImage(
            prepared, scale: scale, background: background, options: options) else { return nil }
        return EMFExport.pngData(from: image)
    }
}
