import Foundation

// MARK: - Display-side sanitiser for model prose (X1b item 0)
//
// A weaker on-device model sometimes echoes the grounding scaffolding — the
// `<drawing-content>` data fence and the `<<<DRAWING_ANALYSIS_DATA … >>>` analysis
// sentinel block — back before its answer. The prompts already tell the model to treat
// that region strictly as data, but when it leaks through we must never show it to the
// user. Every place that displays model prose (Summarise, Ask, Describe, Explain) runs
// its streamed text through this before showing it.
//
// This is defensive display cleanup only. It removes a whole echoed block, content
// included, and any stray marker left behind, then trims. A clean answer is returned
// unchanged.
enum DrawingAIOutputSanitiser {
    /// The untrusted-content fence the prompts use (mirrors `DrawingAIPrompt.openMarker`
    /// / `closeMarker`).
    static let openFence = "<drawing-content>"
    static let closeFence = "</drawing-content>"
    /// The analysis data sentinels (mirrors `DrawingAnalysisReport.summaryData()` in
    /// EMFEdit). The opener carries trailing text, so it is matched by prefix.
    static let analysisOpenPrefix = "<<<DRAWING_ANALYSIS_DATA"
    static let analysisClose = "<<<END_DRAWING_ANALYSIS_DATA>>>"

    /// Strips any echoed grounding scaffolding from `raw` and trims the result. A clean
    /// answer (no markers) comes back identical except for surrounding whitespace.
    static func sanitise(_ raw: String) -> String {
        var text = raw
        // 1. Whole analysis sentinel blocks, enclosed content included.
        text = removeBlocks(in: text, openPrefix: analysisOpenPrefix, close: analysisClose)
        // 2. Whole drawing-content fence blocks, enclosed content included — this is the
        //    "fence and the fenced data before the answer" leak.
        text = removeBlocks(in: text, openPrefix: openFence, close: closeFence)
        // 3. A stray analysis opener with no closer: drop from the opener to end of line.
        text = removeOpenerLines(in: text, prefix: analysisOpenPrefix)
        // 4. Any remaining unpaired markers.
        for token in [closeFence, openFence, analysisClose] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // 5. Collapse the blank gap the removals leave, then trim.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes every `openPrefix … close` span (inclusive) where a closer follows an
    /// opener. `openPrefix` is matched as a prefix so the analysis opener's trailing text
    /// is covered.
    private static func removeBlocks(in text: String, openPrefix: String, close: String) -> String {
        var result = text
        while let openRange = result.range(of: openPrefix),
              let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result
    }

    /// Drops any line that begins an analysis sentinel but was never closed (a partial
    /// echo), from the marker to the end of its line.
    private static func removeOpenerLines(in text: String, prefix: String) -> String {
        var result = text
        while let range = result.range(of: prefix) {
            let lineEnd = result[range.lowerBound...].firstIndex(of: "\n") ?? result.endIndex
            result.removeSubrange(range.lowerBound..<lineEnd)
        }
        return result
    }
}

/// Coalesces streaming UI updates to a modest refresh rate so a fast token stream
/// doesn't drive one O(n) sanitise/ground + SwiftUI invalidation per token (P14). The
/// snapshots are cumulative, so skipping an intermediate one loses nothing; the caller
/// always does a FINAL flush when the stream ends, so the shown text is identical to the
/// per-token result.
struct StreamFlushGate {
    private var last: ContinuousClock.Instant?
    private let interval: Duration

    /// `hz` flushes per second (default ~15 Hz, imperceptible yet far below a token rate).
    init(hz: Double = 15) {
        interval = .milliseconds(Int(1000 / Swift.max(1, hz)))
    }

    /// True at most once per `interval`; the caller flushes the UI only when it returns true.
    mutating func shouldFlush(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}
