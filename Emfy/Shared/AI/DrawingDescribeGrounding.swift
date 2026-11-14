import Foundation

// MARK: - Describe faithfulness: quote grounding (F3 / describe faithfulness)
//
// A deterministic post-check for any drawing description: the small on-device model
// sometimes puts quotation marks around text it did NOT read from the drawing (a
// paraphrase, a label it inferred), which reads as a verbatim quote and is a
// faithfulness failure. This removes the quotation marks from any double-quoted span
// whose inner text does not actually appear in the drawing's own text runs — so an
// invented "quote" becomes plain, unquoted words, and only text genuinely present stays
// quoted. It never adds or rewrites words; it only strips marks.
//
// The comparison is case-insensitive and whitespace-normalised (runs of whitespace,
// including the newlines between runs, collapse to a single space), so a quote that spans
// two text runs or differs only in spacing still counts as present. This lives in the
// shared AI layer and runs after `DrawingAIOutputSanitiser` wherever a description is
// shown (Describe, on-device and provider) and in the eval, so the gate measures exactly
// what ships.
enum DrawingDescribeGrounding {
    /// Lowercased, with every run of whitespace collapsed to one space, trimmed.
    static func normalise(_ string: String) -> String {
        let collapsed = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether `quote` appears (normalised, case-insensitive) in the drawing's text runs.
    /// An empty/whitespace-only quote is treated as present (nothing to ground).
    static func isQuoteSupported(_ quote: String, inDrawingText lines: [String]) -> Bool {
        let needle = normalise(quote)
        guard !needle.isEmpty else { return true }
        return normalise(lines.joined(separator: " ")).contains(needle)
    }

    /// Returns `description` with the quotation marks removed from every double-quoted span
    /// (straight `"…"` or smart `“…”`) whose inner text is not present in `drawingText`.
    /// Supported quotes keep their marks; the words are never changed.
    static func groundQuotes(in description: String, drawingText lines: [String]) -> String {
        let haystack = normalise(lines.joined(separator: " "))
        let characters = Array(description)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let closer = closingQuote(for: character),
               let end = nextIndex(of: closer, in: characters, after: index) {
                let inner = String(characters[(index + 1) ..< end])
                let needle = normalise(inner)
                if !needle.isEmpty && !haystack.contains(needle) {
                    result += inner          // invented quote → drop only the marks
                } else {
                    result += String(character) + inner + String(closer)
                }
                index = end + 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// The matching closing quote for an opening double-quote character, or nil when the
    /// character isn't an opening double quote.
    private static func closingQuote(for character: Character) -> Character? {
        switch character {
        case "\"": return "\""
        case "\u{201C}": return "\u{201D}"   // “ → ”
        default: return nil
        }
    }

    private static func nextIndex(of character: Character, in characters: [Character], after start: Int) -> Int? {
        var i = start + 1
        while i < characters.count {
            if characters[i] == character { return i }
            i += 1
        }
        return nil
    }
}
