import CoreGraphics
import EMFRender
import Foundation

// MARK: - Per-match highlight boxes (P3)
//
// Refines the find matches so each occurrence highlights the MATCHED SUBSTRING,
// not the whole text run — two matches in one run then get two distinct boxes,
// and the current-match outline lands on exactly the glyphs found. The width of
// each run's characters comes from the file's own Dx advances where it carries
// them ([MS-EMF] §2.2.5 EmrText.offDx); otherwise the run's resolved font is
// measured through `EMFRender.TextRunMeasure` (FontMapper — never a CTFont
// created here). Runs with no layout metrics (EMF+ playback, OCR) keep their
// whole-run bounds. The box is mapped to device space through the run's
// transform, so a rotated run is handled.

enum FindMatchBoxes {

    /// Returns `matches` with each match's `boundsDevice` replaced by a tight
    /// per-substring box when the run (identified by `runIndex` into the SAME
    /// reading-ordered list `DrawingTextFind.matches` produced) carries layout
    /// metrics and the match carries its character range; otherwise the match is
    /// unchanged. Font measurement (the no-Dx path) is done at most once per run.
    static func refined(_ matches: [DrawingTextFind.Match], orderedRuns: [DrawingTextRun]) -> [DrawingTextFind.Match] {
        guard !matches.isEmpty else { return matches }
        // Cache the measured cumulative offsets per run index — only runs WITHOUT a
        // Dx array are measured, and a run's measurement is shared by its matches.
        var measuredOffsets: [Int: [CGFloat]?] = [:]

        return matches.map { match in
            guard orderedRuns.indices.contains(match.runIndex),
                  let range = match.characterRangeUTF16,
                  let layout = orderedRuns[match.runIndex].layout,
                  abs(layout.emLogical) > 0
            else { return match }

            let run = orderedRuns[match.runIndex]
            let utf16Count = run.text.utf16.count
            guard range.lowerBound >= 0, range.upperBound <= utf16Count,
                  range.lowerBound <= range.upperBound else { return match }

            let widths: (lead: Double, match: Double, total: Double)
            if layout.advancesLogical.count == utf16Count, !layout.advancesLogical.isEmpty {
                // The file positioned the run from its own Dx advances: sum them (in
                // Double, so a hostile advance array can't overflow).
                let adv = layout.advancesLogical
                let total = adv.reduce(0.0) { $0 + Double($1) }
                let lead = adv[0..<range.lowerBound].reduce(0.0) { $0 + Double($1) }
                let span = adv[range.lowerBound..<range.upperBound].reduce(0.0) { $0 + Double($1) }
                widths = (lead, span, total)
            } else {
                // No Dx: measure the resolved font's advances via FontMapper.
                let offsets: [CGFloat]?
                if let cached = measuredOffsets[match.runIndex] {
                    offsets = cached
                } else {
                    offsets = TextRunMeasure.cumulativeOffsets(
                        string: run.text,
                        family: run.fontFamily ?? "",
                        bold: layout.bold,
                        italic: layout.italic,
                        emSize: abs(layout.emLogical))
                    measuredOffsets[match.runIndex] = offsets
                }
                guard let offsets, offsets.count == utf16Count + 1 else { return match }
                let lead = Double(offsets[range.lowerBound])
                let span = Double(offsets[range.upperBound] - offsets[range.lowerBound])
                widths = (lead, span, Double(offsets[utf16Count]))
            }

            let box = DrawingTextBounds.substringBox(
                referenceLogical: layout.referenceLogical,
                emLogical: layout.emLogical,
                totalWidthLogical: widths.total,
                leadLogical: widths.lead,
                matchWidthLogical: widths.match,
                alignRawValue: layout.alignRawValue,
                transform: layout.transform)
            guard !box.isNull, !box.isEmpty, box.width.isFinite, box.height.isFinite else { return match }

            var refined = match
            refined.boundsDevice = box
            return refined
        }
    }
}
