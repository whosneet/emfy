import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Verifies FontMapper's substitution targets resolve to real, installed fonts —
/// not CoreText's `.LastResort` ultimate fallback — on whatever platform the
/// suite runs on. It exists for the iOS gate (v3-plan I0): iOS ships a different
/// font set from macOS, so every family the mapper falls back to must be present
/// there too. It runs on macOS as well, where it is a standing guard that the
/// fallbacks stay real.
///
/// macOS behaviour is untouched: this only reads what the existing mapper
/// resolves; it changes neither the table nor any rendering path.
@Suite("FontMapper substitution resolves to installed fonts (iOS gate)")
struct FontMapperResolutionTests {

    private static func resolve(_ family: String) -> (font: CTFont, substituted: String?) {
        var log = EMFRenderLog()
        let font = FontMapper.resolveFamily(family, bold: false, italic: false, log: &log)
        if case .fontSubstituted(_, let used, _) = log.entries.first {
            return (font, used)
        }
        return (font, nil)
    }

    private static func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private static func familyName(_ font: CTFont) -> String {
        (CTFontCopyFamilyName(font) as String)
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }

    /// CoreText's ultimate fallback when nothing resolves. A resolved font whose
    /// family or PostScript name is LastResort means the requested fallback is
    /// absent on this platform — the exact failure this gate catches.
    private static func isLastResort(_ font: CTFont) -> Bool {
        let family = normalise(familyName(font))
        let ps = normalise(postScriptName(font))
        return family.contains("lastresort") || ps.contains("lastresort")
    }

    /// Every family FontMapper falls back TO (mirrors `FontMapper.substitution`'s
    /// targets): the default, plus the explicit MS-Sans-Serif target. Each must
    /// resolve directly to itself on this platform — proving it is installed, not
    /// LastResort-substituted.
    @Test("each substitution-table target is an installed, non-LastResort family")
    func fallbackTargetsAreInstalled() {
        let targets = [FontMapper.defaultFamily, "Helvetica"]
        for target in targets {
            let (font, substituted) = Self.resolve(target)
            #expect(!Self.isLastResort(font), "\(target) resolved to LastResort — it is not installed here")
            // A real fallback target resolves directly (no substitution), i.e. the
            // created font's family equals the requested target.
            #expect(
                substituted == nil && Self.normalise(Self.familyName(font)) == Self.normalise(target),
                "\(target) did not resolve to itself: family=\(Self.familyName(font)) substituted=\(substituted ?? "nil")"
            )
        }
    }

    /// Every Windows family that reaches the table (whether it resolves directly
    /// or is substituted) must end on a non-LastResort font. This covers each
    /// table branch — Calibri/Tahoma → default, MS/Microsoft Sans Serif →
    /// Helvetica, and the CJK/unknown default branch — plus the direct faces. The
    /// resolution table is printed for the record.
    @Test("no mapped Windows family resolves to LastResort; print the table")
    func mappedFamiliesNeverLastResort() {
        // Direct faces, explicit table entries, and default-branch families
        // (CJK + symbol + unknown). The CJK families resolve their BASE to the
        // default here; real CJK glyphs come from CTLine's cascade at draw time.
        let requested = [
            "Arial", "Times New Roman", "Courier New", "Georgia", "Verdana",
            "Trebuchet MS", "Helvetica", "Helvetica Neue",
            "Calibri", "Tahoma", "MS Sans Serif", "Microsoft Sans Serif",
            "Segoe UI", "Symbol", "Wingdings",
            "MS Gothic", "MS Mincho", "SimSun", "Batang", "Malgun Gothic",
        ]
        print("[fontmap] requested family -> resolved PostScript name (family) [substituted target]")
        for family in requested {
            let (font, substituted) = Self.resolve(family)
            let ps = Self.postScriptName(font)
            let fam = Self.familyName(font)
            let note = substituted.map { " [sub -> \($0)]" } ?? " [direct]"
            print("[fontmap] \(family) -> \(ps) (\(fam))\(note)")
            #expect(!Self.isLastResort(font), "\(family) resolved to LastResort font")
            #expect(!ps.isEmpty, "\(family) resolved to an empty PostScript name")
        }
    }
}
