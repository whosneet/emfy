import CoreText
import Foundation
import NaturalLanguage

// MARK: - Translation target languages + source detection + width estimate (X2c)
//
// The curated target-language list for the "Translate…" edit, the sensible default (the
// system's preferred language, or English when the source already appears to be in that
// language), a best-effort source-language guess (NaturalLanguage, a system framework), and
// a font-aware width ratio so the preview can flag runs that will overflow after
// translation. All app-layer (CoreText measurement is fine here; EMFKit stays framework-pure).

/// A selectable target language.
struct TranslationLanguage: Identifiable, Hashable, Sendable {
    /// A BCP-47 primary subtag (`fr`, `zh-Hans`), used in the prompt and for source matching.
    let code: String
    /// The English display name for the picker.
    let englishName: String
    var id: String { code }

    /// Right-to-left scripts, so the preview can note that Emfy renders the characters but
    /// does not run a bidi layout engine.
    var isRightToLeft: Bool { ["ar", "he", "fa", "ur"].contains(code) }
}

enum TranslationLanguages {
    /// The offered targets (the brief's list), in a sensible menu order.
    static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "en", englishName: "English"),
        TranslationLanguage(code: "fr", englishName: "French"),
        TranslationLanguage(code: "de", englishName: "German"),
        TranslationLanguage(code: "es", englishName: "Spanish"),
        TranslationLanguage(code: "it", englishName: "Italian"),
        TranslationLanguage(code: "pt", englishName: "Portuguese"),
        TranslationLanguage(code: "nl", englishName: "Dutch"),
        TranslationLanguage(code: "ja", englishName: "Japanese"),
        TranslationLanguage(code: "zh-Hans", englishName: "Chinese (Simplified)"),
        TranslationLanguage(code: "ko", englishName: "Korean"),
        TranslationLanguage(code: "ar", englishName: "Arabic"),
        TranslationLanguage(code: "hi", englishName: "Hindi"),
    ]

    /// The system's preferred language among the offered list, else English.
    static func systemPreferred() -> TranslationLanguage {
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            if let match = match(languageCode: locale.language.languageCode?.identifier,
                                 script: locale.language.script?.identifier) {
                return match
            }
        }
        return all[0]
    }

    /// The default target: the system's preferred language, unless the source already appears
    /// to be in it — then English, or (when the source IS English) the next sensible option.
    static func defaultTarget(sourceCode: String?) -> TranslationLanguage {
        let preferred = systemPreferred()
        guard let sourceCode, sourceCode == preferred.code else { return preferred }
        if let english = all.first(where: { $0.code == "en" }), english.code != sourceCode {
            return english
        }
        return all.first { $0.code != sourceCode } ?? preferred
    }

    /// A best-effort guess of the dominant language of `text`, as one of our codes, or `nil`
    /// when NaturalLanguage can't decide or returns a language we don't offer.
    static func detectSource(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        // NLLanguage raw values are BCP-47 (`en`, `fr`, `zh-Hans`, …); match to the offered list.
        if let exact = all.first(where: { $0.code == dominant.rawValue }) { return exact.code }
        let base = dominant.rawValue.split(separator: "-").first.map(String.init)
        return all.first { $0.code == base || $0.code.hasPrefix((base ?? "") + "-") }?.code
    }

    private static func match(languageCode: String?, script: String?) -> TranslationLanguage? {
        guard let languageCode else { return nil }
        if languageCode == "zh" {
            // Default unqualified Chinese (and Traditional) to Simplified, the offered variant.
            return all.first { $0.code == "zh-Hans" }
        }
        return all.first { $0.code == languageCode }
    }
}

// MARK: - Overflow estimate

enum TextWidthRatio {
    /// The threshold above which a translated run is flagged as likely to overflow (~30%).
    static let overflowThreshold = 1.30

    /// The ratio of the rendered advance width of `candidate` to `original` in the run's
    /// font (point size cancels, so a fixed measurement size is used). Returns 1 when the
    /// original is empty or a font can't be built — i.e. "no overflow" rather than a false
    /// positive.
    static func ratio(original: String, candidate: String, family: String, bold: Bool, italic: Bool) -> Double {
        let originalWidth = width(original, family: family, bold: bold, italic: italic)
        guard originalWidth > 0.5 else { return 1 }
        let candidateWidth = width(candidate, family: family, bold: bold, italic: italic)
        let ratio = candidateWidth / originalWidth
        return ratio.isFinite ? ratio : 1
    }

    private static func width(_ string: String, family: String, bold: Bool, italic: Bool) -> Double {
        guard !string.isEmpty else { return 0 }
        let font = makeFont(family: family, bold: bold, italic: italic, size: 24)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func makeFont(family: String, bold: Bool, italic: Bool, size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName(family as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) else {
            return base
        }
        return styled
    }
}
