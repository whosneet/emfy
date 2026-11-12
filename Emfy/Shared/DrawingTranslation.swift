import Foundation

// MARK: - Translate text selection (F3d)
//
// The pure text selection behind the system Translate overlay: the current Find match's run
// text when a match exists, else the whole drawing's text in Copy All Text order. Either is
// truncated to about 4000 characters at a word boundary, so the overlay gets a readable
// passage rather than a whole document. The overlay itself is presented by
// `DrawingTranslationModifier` (gated to macOS 14.4 / iOS 17.4); this type is pure and tested.

enum DrawingTranslation {
    /// The soft character cap on the translated passage. The system overlay is built for
    /// short passages, so a whole drawing is truncated to roughly this many characters.
    static let maxCharacters = 4000

    /// The text to hand the Translate overlay: the current Find match's run text when one
    /// exists (and isn't blank), else `allText` (Copy All Text order). The result is
    /// truncated to `maxCharacters` at a word boundary.
    static func text(currentMatch: String?, allText: String) -> String {
        let trimmedMatch = currentMatch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (trimmedMatch?.isEmpty == false) ? trimmedMatch! : allText
        return truncate(source, to: maxCharacters)
    }

    /// Truncates `text` to at most `limit` characters, backing up to the last whitespace so a
    /// word is never split. Falls back to a hard cut when the first `limit` characters hold no
    /// whitespace to break on.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let hardEnd = text.index(text.startIndex, offsetBy: limit)
        let head = text[text.startIndex..<hardEnd]
        if let lastBreak = head.lastIndex(where: { $0.isWhitespace }) {
            let trimmed = head[head.startIndex..<lastBreak]
            if !trimmed.isEmpty {
                return String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(head)
    }
}
