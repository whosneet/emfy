import CoreGraphics
import CoreText
import Foundation

// MARK: - Text-run advance measurement (P3: Find substring highlights)
//
// A small public entry point so the app's find-highlight geometry can measure a
// run's per-character advances WITHOUT creating CoreText fonts itself. Font
// creation goes through `FontMapper` (the one resolution/substitution path, and
// the macOS 27.2 font-lookup-deadlock-safe `FontLookupQueue`), so the app never
// touches CTFont directly — the same discipline the renderer keeps internally.
//
// It is only used when a GDI text run carries NO explicit Dx advance array
// ([MS-EMF] §2.2.5 EmrText.offDx); a run that carries one is positioned from it
// exactly and needs no measurement.

public enum TextRunMeasure {

    /// The cumulative horizontal advance at each UTF-16 boundary of `string`,
    /// measured with the run's resolved font at `emSize` logical units. The result
    /// has `string.utf16.count + 1` elements: element *i* is the typographic width
    /// of the first *i* code units (element 0 is 0, the last is the whole-run
    /// width), in the SAME logical units as `emSize` — so a caller maps it to
    /// device space through the run's logical→device transform.
    ///
    /// Returns `nil` when `emSize` is non-positive, the string is empty, or the
    /// line cannot be typeset. All CoreText work (font copy + line typesetting,
    /// which can trigger the glyph-cascade lookup) runs on `FontLookupQueue`, so a
    /// wedged font provider yields `nil` rather than hanging (§8).
    public static func cumulativeOffsets(
        string: String,
        family: String,
        bold: Bool,
        italic: Bool,
        emSize: Double
    ) -> [CGFloat]? {
        guard emSize.isFinite, emSize > 0, !string.isEmpty else { return nil }
        let size = min(CGFloat(emSize), FontMapper.maxDevicePointSize)
        // `resolveFamily` already resolves on the lookup queue and applies traits.
        var log = EMFRenderLog()
        let base = FontMapper.resolveFamily(family, bold: bold, italic: italic, log: &log)
        let utf16Count = string.utf16.count

        return FontLookupQueue.run(fallback: nil) { () -> [CGFloat]? in
            let font = CTFontCreateCopyWithAttributes(base, size, nil, nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font]
            guard let attributed = CFAttributedStringCreate(
                nil, string as CFString, attributes as CFDictionary
            ) else { return nil }
            let line = CTLineCreateWithAttributedString(attributed)
            var offsets = [CGFloat](repeating: 0, count: utf16Count + 1)
            for i in 0 ... utf16Count {
                offsets[i] = CTLineGetOffsetForStringIndex(line, i, nil)
            }
            return offsets
        }
    }
}
