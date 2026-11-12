import CoreGraphics
import Foundation

// MARK: - Find in drawing text (F3)
//
// The pure matching engine behind the Mac find bar (⌘F / ⌘G) and the iOS find
// field. It is case- and diacritic-insensitive by default, runs over the
// extracted `DrawingTextRun`s (drawing text and OCR picture text alike), and
// reports matches in reading order so Find Next/Previous walk the drawing the way
// a reader would. The UI owns the highlight overlay and scroll-into-view; this
// type owns only the matching and the "n of m" navigation maths, so both
// platforms share one tested core.

enum DrawingTextFind {

    /// One occurrence of the query inside a run. The overlay highlights the run's
    /// `boundsDevice`; several matches in one run share those bounds (the fill is
    /// idempotent). `source` lets the UI tag a picture-OCR match "in picture".
    struct Match: Equatable, Sendable {
        /// Index into the reading-ordered run list the matches were produced from.
        var runIndex: Int
        var boundsDevice: CGRect
        var source: DrawingTextRun.Source
        /// 0-based occurrence within the run.
        var occurrence: Int
    }

    /// The search options: case- and diacritic-insensitive, matching the design.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every occurrence of `query` across the runs, in reading order (runs sorted
    /// top-to-bottom/left-to-right, then by occurrence within a run). An empty or
    /// whitespace-only query yields no matches.
    static func matches(of query: String, in runs: [DrawingTextRun]) -> [Match] {
        let needle = query
        guard !needle.isEmpty else { return [] }
        let ordered = DrawingTextExtractor.readingOrder(runs)
        var result: [Match] = []
        for (runIndex, run) in ordered.enumerated() {
            let occurrences = occurrenceCount(of: needle, in: run.text)
            for occurrence in 0..<occurrences {
                result.append(Match(runIndex: runIndex, boundsDevice: run.boundsDevice, source: run.source, occurrence: occurrence))
            }
        }
        return result
    }

    /// How many times `needle` appears in `haystack` under the find options.
    /// Non-overlapping, left-to-right.
    static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(of: needle, options: options, range: searchStart..<haystack.endIndex) {
            count += 1
            // Advance past the match; guard the degenerate empty-range case.
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : haystack.index(after: found.lowerBound)
        }
        return count
    }

    // MARK: Navigation

    /// The "n of m" status text for the bar, or "" when there are no matches.
    /// `current` is a 0-based index into the match list.
    static func status(current: Int?, total: Int) -> String {
        guard total > 0 else { return "" }
        let n = (current ?? 0) + 1
        return "\(n) of \(total)"
    }

    /// The next match index, wrapping past the end. nil when there are no
    /// matches. With no current selection, the first match is next.
    static func next(current: Int?, total: Int) -> Int? {
        guard total > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % total
    }

    /// The previous match index, wrapping past the start. nil when there are no
    /// matches. With no current selection, the last match is previous.
    static func previous(current: Int?, total: Int) -> Int? {
        guard total > 0 else { return nil }
        guard let current else { return total - 1 }
        return (current - 1 + total) % total
    }
}
