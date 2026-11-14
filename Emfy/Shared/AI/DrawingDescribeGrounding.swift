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

    /// Whether `quote` appears (normalised, case-insensitive) in the drawing's text runs
    /// as whole words. An empty/whitespace-only quote is treated as present (nothing to
    /// ground).
    static func isQuoteSupported(_ quote: String, inDrawingText lines: [String]) -> Bool {
        let needle = normalise(quote)
        guard !needle.isEmpty else { return true }
        return haystackContainsPhrase(needle, in: haystack(for: lines))
    }

    /// Whether `needle` (already normalised) appears in `haystack` (already normalised)
    /// as whole words — bounded by a non-alphanumeric character or a string edge on each
    /// side — so a short quote isn't counted as present merely for sitting inside a larger
    /// word (FM-6: match on word boundaries).
    static func haystackContainsPhrase(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let hay = Array(haystack)
        let need = Array(needle)
        guard need.count <= hay.count else { return false }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var i = 0
        let last = hay.count - need.count
        while i <= last {
            if Array(hay[i ..< i + need.count]) == need {
                let beforeOK = i == 0 || !isWord(hay[i - 1])
                let afterIndex = i + need.count
                let afterOK = afterIndex == hay.count || !isWord(hay[afterIndex])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// The normalised search text for `lines` — build it ONCE per stream and pass it to
    /// `groundQuotes(in:normalisedHaystack:)` so a streamed description doesn't re-join and
    /// re-normalise the whole drawing text on every token (P14).
    static func haystack(for lines: [String]) -> String {
        normalise(lines.joined(separator: " "))
    }

    /// Returns `description` with the quotation marks removed from every double-quoted span
    /// (straight `"…"` or smart `“…”`) whose inner text is not present in `drawingText`.
    /// Supported quotes keep their marks; the words are never changed.
    static func groundQuotes(in description: String, drawingText lines: [String]) -> String {
        groundQuotes(in: description, normalisedHaystack: haystack(for: lines))
    }

    /// `groundQuotes` over a pre-normalised haystack (see `haystack(for:)`).
    static func groundQuotes(in description: String, normalisedHaystack haystack: String) -> String {
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
                if !needle.isEmpty && !haystackContainsPhrase(needle, in: haystack) {
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
        case "\u{2018}": return "\u{2019}"   // ‘ → ’ (FM-6)
        case "\u{00AB}": return "\u{00BB}"   // « → » (FM-6)
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
