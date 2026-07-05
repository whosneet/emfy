import CoreGraphics
import CoreText
import EMFParse
import Foundation

/// LOGFONT → CTFont resolution (primer §6 phase 4). Produces a `ResolvedFont`
/// carrying a base CTFont at a nominal size plus the attributes CoreText's font
/// object does not itself carry; the text drawer scales the base to the device
/// point size and applies underline/strike-out/rotation at draw time.
///
/// Resolution order:
///  1. Try `CTFontCreateWithName(faceName)`. CoreText silently substitutes a
///     fallback when a family is missing, so a MISS is detected by comparing
///     the created font's family name against the request (case- and
///     space-insensitive). On a miss, consult the substitution table.
///  2. Apply bold (lfWeight ≥ 600) and italic (lfItalic ≠ 0) as symbolic
///     traits; if the trait variant does not exist, keep the base (no log).
///
/// Every family that had to be substituted is reported ONCE to the caller via
/// `fontSubstituted(requested:used:)` (coalesced per requested family).
enum FontMapper {

    /// The nominal size the base CTFont is created at. The text drawer copies
    /// the base to the true device size, so this value only sets a starting
    /// point for trait resolution — it never reaches the canvas directly.
    static let nominalSize: CGFloat = 100

    /// The default point size when lfHeight is 0 ([MS-EMF] §2.2.13 / primer:
    /// "font mapper default"), in logical units before the transform scale.
    static let defaultHeight: CGFloat = 12

    /// The ceiling on a resolved device point size. A glyph cannot usefully
    /// exceed the canvas (capped at `EMFRenderer.canvasDimensionCap`, 16384 per
    /// side), so anything larger only feeds CoreText/CTLine an enormous size to
    /// flatten glyph outlines at before CG clips — a slow, large-allocation path
    /// from a single hostile EMR_EXTCREATEFONTINDIRECTW with, say,
    /// `lfHeight = -2_000_000_000` (§8: never hang). Half the canvas cap is
    /// still far larger than any glyph a real file draws (normal sizes are a few
    /// hundred points at most), so legitimate text is untouched.
    static let maxDevicePointSize: CGFloat = 8192

    /// The default substitution when a requested family neither resolves
    /// directly nor has a table entry.
    static let defaultFamily = "Helvetica Neue"

    /// The system font, used for stock FONT selections. Created once per call;
    /// CoreText caches descriptors internally, so this is cheap.
    static func systemBaseFont() -> CTFont {
        CTFontCreateUIFontForLanguage(.system, nominalSize, nil)
            ?? CTFontCreateWithName(defaultFamily as CFString, nominalSize, nil)
    }

    /// Resolves a LogFont ([MS-EMF] §2.2.13) to a `ResolvedFont`, appending one
    /// coalesced `fontSubstituted` entry per requested family that had to be
    /// remapped.
    static func resolve(_ logFont: LogFont, log: inout EMFRenderLog) -> ResolvedFont {
        let requested = logFont.faceName.trimmingCharacters(in: .whitespaces)
        let base = baseFont(forFamily: requested, log: &log)

        let bold = logFont.weight >= 600
        let italic = logFont.italic != 0
        let styled = applyTraits(to: base, bold: bold, italic: italic)

        return ResolvedFont(
            base: styled,
            logicalHeight: logFont.height,
            escapementTenths: logFont.escapement,
            underline: logFont.underline != 0,
            strikeOut: logFont.strikeOut != 0
        )
    }

    // MARK: - Family resolution

    /// The base CTFont for a requested family name, at `nominalSize`, applying
    /// the substitution table on a CoreText miss. Logs (coalesced) any
    /// substitution.
    private static func baseFont(forFamily requested: String, log: inout EMFRenderLog) -> CTFont {
        // An empty face name goes straight to the default (font mapper choice).
        guard !requested.isEmpty else {
            log.noteFontSubstituted(requested: requested, used: defaultFamily)
            return CTFontCreateWithName(defaultFamily as CFString, nominalSize, nil)
        }

        // Direct try. If CoreText returns a font whose family matches the
        // request, use it as-is (Arial, Times New Roman, Tahoma, … resolve
        // directly on macOS; Calibri resolves too when Office is installed).
        let direct = CTFontCreateWithName(requested as CFString, nominalSize, nil)
        if familyMatches(direct, requested) {
            return direct
        }

        // Miss: CoreText silently substituted. Consult the table.
        let replacement = substitution(for: requested)
        log.noteFontSubstituted(requested: requested, used: replacement)
        return CTFontCreateWithName(replacement as CFString, nominalSize, nil)
    }

    /// The substitution-table target for a Windows family CoreText could not
    /// resolve. CJK families (MS Gothic/Mincho, SimSun, Batang) map to the
    /// default and rely on CTLine's font cascade to supply CJK glyphs from a
    /// system fallback (primer §6). Matched case- and space-insensitively.
    private static func substitution(for requested: String) -> String {
        switch normalise(requested) {
        case "calibri":
            return "Helvetica Neue"
        case "mssansserif", "microsoftsansserif":
            return "Helvetica"
        case "tahoma":
            return "Helvetica Neue"
        default:
            // MS Gothic / MS Mincho / SimSun / Batang and everything else:
            // the default face; CTLine font cascading covers CJK glyphs.
            return defaultFamily
        }
    }

    /// True when `font`'s family name equals `requested` ignoring case and
    /// whitespace — the CoreText-miss detector (CoreText returns a fallback
    /// with a DIFFERENT family name when the requested one is absent).
    private static func familyMatches(_ font: CTFont, _ requested: String) -> Bool {
        let family = CTFontCopyFamilyName(font) as String
        return normalise(family) == normalise(requested)
    }

    private static func normalise(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - Traits

    /// Applies bold/italic symbolic traits, keeping the base font when the
    /// styled variant does not exist (common — many faces lack a bold-italic).
    private static func applyTraits(to font: CTFont, bold: Bool, italic: Bool) -> CTFont {
        guard bold || italic else { return font }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        // The mask restricts the copy to the traits we set, leaving others
        // untouched. A nil result means the variant is unavailable → keep base.
        return CTFontCreateCopyWithSymbolicTraits(font, nominalSize, nil, traits, traits)
            ?? font
    }

    // MARK: - Sizing (used by the text drawer)

    /// The point size for a resolved font in the space `logicalToDrawSpace`
    /// maps logical units into (the renderer sizes in device space, then a
    /// canvas-fit transform scales device→target uniformly). lfHeight is in
    /// LOGICAL units and scales by that transform's average axis scale (same
    /// approximation family as geometric pen widths, StrokeMapper.averageScale).
    /// Sign convention ([MS-EMF] §2.2.13): NEGATIVE = character (em) height →
    /// point size = |height|; POSITIVE = cell height → em ≈ 0.9 × height (an
    /// approximation — real emitters overwhelmingly write negative heights);
    /// 0 → the 12pt default.
    static func devicePointSize(
        logicalHeight: Int32,
        logicalToTarget logicalToDrawSpace: CGAffineTransform
    ) -> CGFloat {
        let scale = StrokeMapper.averageScale(logicalToDrawSpace)
        let logicalPoints: CGFloat
        if logicalHeight < 0 {
            logicalPoints = CGFloat(-Int(logicalHeight))
        } else if logicalHeight > 0 {
            logicalPoints = 0.9 * CGFloat(Int(logicalHeight))
        } else {
            logicalPoints = defaultHeight
        }
        let sized = logicalPoints * scale
        // A degenerate (zero/negative) result would make CoreText unhappy;
        // floor at 1 device point so text never vanishes to nothing.
        guard sized.isFinite && sized >= 1 else { return max(defaultHeight, 1) }
        // Ceiling: a glyph larger than the canvas is never useful and feeds
        // CoreText an enormous outline-flattening size (the anti-hang for a
        // hostile lfHeight). Normal sizes are far below the cap, so untouched.
        return min(sized, maxDevicePointSize)
    }
}
