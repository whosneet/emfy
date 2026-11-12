import CoreGraphics

// MARK: - Derived text bounds (F3b)
//
// Many real EMF files draw text with EXTTEXTOUTW whose optional bounding rectangle is zero
// (the glyphs are positioned from the reference point + per-glyph advances, not a rect), so
// the renderer's text op — and the imported scene element — carry no usable device bounds.
// Find highlighting needs a box per run, so this derives a tight one from the run's own
// metrics: the reference point, the em size, the advances and the alignment, mapped through
// the run's logical→device transform. It mirrors the editor's text-box convention (reference
// point in the element's pre-transform space; `EMFEdit.SceneFactory.textBox`), so a highlight
// lands where the editor places the run. Pure CoreGraphics, so it tests anywhere.

enum DrawingTextBounds {

    /// A device-space box for a text run, from its reference point (in the run's logical /
    /// pre-transform space), em size, per-glyph advances, alignment mask and the run's
    /// logical→device transform. Returns `.null` when the em size is non-positive (unknown),
    /// so callers keep whatever bounds they already had.
    static func deviceBox(
        referenceLogical: CGPoint,
        emLogical: Double,
        advancesLogical: [UInt32],
        utf16Count: Int,
        alignRawValue: UInt32,
        transform: CGAffineTransform
    ) -> CGRect {
        let em = abs(emLogical)
        guard em > 0 else { return .null }

        // Width: the exact sum of the per-glyph advances when the run carried them (summed in
        // Double so a hostile advance array can't overflow), else a glyph-width estimate.
        let width: Double = advancesLogical.isEmpty
            ? Double(max(1, utf16Count)) * em * 0.6
            : advancesLogical.reduce(0.0) { $0 + Double($1) }
        let safeWidth = max(width, em * 0.3)

        let refX = Double(referenceLogical.x)
        let refY = Double(referenceLogical.y)

        // Horizontal alignment (TA_LEFT / TA_RIGHT / TA_CENTER, [MS-EMF] §2.3.11.25).
        let x0: Double
        switch alignRawValue & 0x6 {
        case 0x2: x0 = refX - safeWidth          // TA_RIGHT
        case 0x6: x0 = refX - safeWidth / 2      // TA_CENTER
        default:  x0 = refX                       // TA_LEFT
        }

        // Vertical alignment (TA_TOP / TA_BASELINE / TA_BOTTOM). The box covers the cell with
        // a little slack so the highlight comfortably contains the glyphs.
        let top: Double
        switch alignRawValue & 0x18 {
        case 0x18: top = refY - em * 0.9         // TA_BASELINE
        case 0x08: top = refY - em * 1.15        // TA_BOTTOM
        default:   top = refY                     // TA_TOP
        }
        let height = em * 1.25

        let box = CGRect(x: x0, y: top, width: safeWidth, height: height)
        // CGRect.applying returns the bounding box of the transformed rect, so a rotated or
        // scaled logical→device transform yields correct device bounds.
        return box.applying(transform)
    }
}
