import Foundation
import FoundationModels

// MARK: - Auto title and tags (A1b Part 1)
//
// An on-device, structured-output summary of a drawing: a short descriptive title
// (≤ 6 words) and 3–5 lowercase keyword tags, generated from the bounded, sanitised
// `DrawingAIContext` via `@Generable`. The file name is never renamed — the AI title
// is a SECONDARY line under it — so this is purely additive metadata.
//
// Security (CLAUDE.md §8): the drawing's own text is UNTRUSTED. It reaches the model
// only inside the data-fenced block (`DrawingAIPrompt.dataBlock`), and the model's
// output is sanitised and hard-capped here (control characters stripped; title ≤ 60
// characters and ≤ 6 words; tags lowercased and ≤ 24 characters each) before it is
// stored, shown, or fed to Spotlight.

/// The sanitised, capped title + tags stored with a recents entry.
struct DrawingTitleTags: Equatable, Sendable, Codable {
    var title: String
    var tags: [String]

    var isEmpty: Bool { title.isEmpty && tags.isEmpty }
}

/// The model's raw structured output. Gated to macOS 26 / iOS 26; the sanitiser and
/// caps below are OS-agnostic so they're unit-tested without a model.
@available(macOS 26, iOS 26, *)
@Generable
struct DrawingTitleTagsOutput {
    @Guide(description: "A short, descriptive title for the drawing in Title Case, at most 6 words. No quotes, no file extension, no trailing punctuation.")
    var title: String
    @Guide(description: "Three to five short, lowercase keyword tags describing the drawing's subject or kind (for example: diagram, invoice, flowchart, logo). One or two words each, no '#'.")
    var tags: [String]
}

// MARK: - Sanitising and caps (pure)

enum DrawingTitleTagsSanitizer {
    /// Title length cap, in characters (brief: ≤ 60).
    static let maxTitleCharacters = 60
    /// Title word cap (brief Part 1: ≤ 6 words).
    static let maxTitleWords = 6
    /// Per-tag length cap, in characters (brief: ≤ 24).
    static let maxTagCharacters = 24
    /// At most this many tags are kept (brief: 3–5).
    static let maxTags = 5

    /// Sanitises and caps a raw model title + tags into what Emfy stores and shows.
    static func sanitize(title rawTitle: String, tags rawTags: [String]) -> DrawingTitleTags {
        DrawingTitleTags(title: sanitizeTitle(rawTitle), tags: sanitizeTags(rawTags))
    }

    /// Strips control/format characters, collapses whitespace, caps to 6 words then
    /// 60 characters, and removes stray wrapping quotes.
    static func sanitizeTitle(_ raw: String) -> String {
        var text = collapseWhitespace(stripControl(raw))
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        var words = text.split(separator: " ")
        if words.count > maxTitleWords { words = Array(words.prefix(maxTitleWords)) }
        text = words.joined(separator: " ")
        if text.count > maxTitleCharacters {
            text = String(text.prefix(maxTitleCharacters)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Lowercases, strips control/format characters and leading markup, de-duplicates,
    /// drops blanks, caps each tag to 24 characters and the list to 5 tags.
    static func sanitizeTags(_ raw: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawTag in raw {
            var tag = collapseWhitespace(stripControl(rawTag)).lowercased()
            tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#.,;:!?\"'“”‘’ "))
            guard !tag.isEmpty else { continue }
            if tag.count > maxTagCharacters {
                tag = String(tag.prefix(maxTagCharacters)).trimmingCharacters(in: .whitespaces)
            }
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == maxTags { break }
        }
        return out
    }

    /// Removes control (Cc) and format (Cf) characters, but keeps whitespace controls
    /// (tab, newline) as a space so adjacent words aren't merged; `collapseWhitespace`
    /// then normalises the spacing.
    static func stripControl(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
            let isFormat = scalar.properties.generalCategory == .format
            if isControl || isFormat {
                if scalar.properties.isWhitespace { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Collapses any run of whitespace to a single space and trims the ends.
    static func collapseWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Prompt

extension DrawingAIPrompt {
    /// The title + tags prompt, grounding the model on the (data-fenced) drawing and
    /// asking for a short title and keyword tags via the `@Generable` schema.
    static func titleTagsPrompt(for context: DrawingAIContext) -> String {
        """
        Give this drawing a short descriptive title and keyword tags, for a file \
        library. The title names what the drawing is (≤ 6 words, Title Case); the tags \
        are lowercase keywords for searching. Base them only on the facts and text \
        below.
        \(dataBlock(for: context))\(truncationInstruction(for: context))
        """
    }
}
