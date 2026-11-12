import CoreGraphics
import Foundation
import Observation

// MARK: - Find UI state (F3b)
//
// The per-viewer state behind the Mac find bar (⌘F) and the iOS find bar: the query, the
// matches computed over the drawing's text runs, and the current match for Find
// Next/Previous. Both platforms share it so the find bar, the highlight overlay and
// scroll-into-view all read one source. The matching and navigation maths live in the
// pure `DrawingTextFind`; this type only holds state and sequences those calls, so it
// stays trivial to reason about (and testable on the main actor).
//
// The runs come from the viewer: the renderer's `PlaybackObservation` in viewer mode, the
// edited `Scene` in edit mode. This model never re-interprets a metafile — it is handed
// runs and keyed by a content id so it recomputes only when the drawing actually changes.

@MainActor
@Observable
final class DrawingFindModel {
    /// Whether the find bar is shown.
    var isPresented = false
    /// The live query, bound to the search field. Typing calls `applyQuery()` (debounced
    /// by the UI); clearing it empties the matches.
    var query = ""

    /// The drawing's own text runs (GDI/EMF+ text). Set by the viewer; find and Copy All
    /// Text read it alongside `pictureRuns`.
    private(set) var runs: [DrawingTextRun] = []
    /// Text recognised inside embedded pictures (OCR, `source == .picture`). Arrives
    /// asynchronously after `runs`, merged into the matches when it does (F3c).
    private(set) var pictureRuns: [DrawingTextRun] = []
    /// True while the OCR pass for the current drawing is still running, so the find bar can
    /// show a "Reading text in pictures…" hint. Cleared when the picture runs arrive or the
    /// drawing changes.
    var isReadingPictures = false
    /// The matches for the current query, in reading order. Empty when the query is empty
    /// or nothing matches.
    private(set) var matches: [DrawingTextFind.Match] = []
    /// The current match: a 0-based index into `matches`, or nil when there are none.
    private(set) var current: Int?

    /// The content identity the current `runs` were computed for, so re-handing the same
    /// drawing's runs is a no-op (it doesn't reset the query or the current match).
    @ObservationIgnored private var runsContentID: Int?

    /// Drawing text and picture text together — the universe Find and Copy All Text search.
    private var allRuns: [DrawingTextRun] { runs + pictureRuns }

    /// Whether the drawing carries any extractable text — drives Copy All Text enablement
    /// and whether Find has anything to search.
    var hasText: Bool { !runs.isEmpty || !pictureRuns.isEmpty }

    /// Whether the current match was recognised inside a picture (shown as "in picture").
    var isCurrentMatchInPicture: Bool { activeMatch?.source == .picture }

    /// The "n of m" status for the bar, or "" when there are no matches.
    var statusText: String { DrawingTextFind.status(current: current, total: matches.count) }

    /// The current match value, or nil.
    var activeMatch: DrawingTextFind.Match? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    /// The text of the run containing the current match, in reading order, for Translate
    /// (F3d). `nil` when there is no current match, so Translate falls back to all text.
    var currentMatchRunText: String? {
        guard let match = activeMatch else { return nil }
        let ordered = DrawingTextExtractor.readingOrder(allRuns)
        guard ordered.indices.contains(match.runIndex) else { return nil }
        return ordered[match.runIndex].text
    }

    // MARK: Runs

    /// Hands the model the drawing's runs. When the drawing is unchanged (`contentID`
    /// matches) and the runs are identical this is a no-op, preserving the open query and
    /// current match. When the runs change (a different drawing, or an edit) the matches
    /// are recomputed against the live query, keeping the current match clamped in range.
    func setRuns(_ newRuns: [DrawingTextRun], contentID: Int) {
        if runsContentID == contentID, newRuns == runs { return }
        let drawingChanged = runsContentID != contentID
        runs = newRuns
        runsContentID = contentID
        if drawingChanged {
            // A brand-new drawing: its predecessor's picture text no longer applies.
            pictureRuns = []
            isReadingPictures = false
            recompute(resetToFirst: true)
        } else {
            // The same drawing edited: keep the user's place when it still exists.
            recompute(resetToFirst: false)
        }
    }

    /// Marks the picture-OCR pass as running for the current drawing, so the bar shows the
    /// progress hint until `setPictureRuns` (or a drawing change) clears it.
    func beginReadingPictures() { isReadingPictures = true }

    /// Merges the OCR picture runs into the matches, if they still belong to the current
    /// drawing (`contentID` matches). A stale result from a previous drawing is ignored. The
    /// user's current match is kept when it still exists.
    func setPictureRuns(_ newRuns: [DrawingTextRun], contentID: Int) {
        guard runsContentID == contentID else { return }
        isReadingPictures = false
        guard newRuns != pictureRuns else { return }
        pictureRuns = newRuns
        recompute(resetToFirst: false)
    }

    /// Drops the picture runs (the Settings toggle turning OCR off), re-matching the drawing
    /// text alone.
    func clearPictureRuns() {
        isReadingPictures = false
        guard !pictureRuns.isEmpty else { return }
        pictureRuns = []
        recompute(resetToFirst: false)
    }

    // MARK: Presentation

    /// Shows the find bar. The caller focuses the field.
    func present() { isPresented = true }

    /// Hides the find bar and clears the query and matches, so the highlight overlay
    /// empties (the runs are kept, so reopening is instant).
    func dismiss() {
        isPresented = false
        query = ""
        matches = []
        current = nil
    }

    // MARK: Query + navigation

    /// Recomputes the matches for the live query and selects the first one. Called (after
    /// the UI's ~150 ms debounce) whenever the query changes.
    func applyQuery() { recompute(resetToFirst: true) }

    /// Advances to the next match, wrapping past the end.
    func goNext() { current = DrawingTextFind.next(current: current, total: matches.count) }

    /// Steps to the previous match, wrapping past the start.
    func goPrevious() { current = DrawingTextFind.previous(current: current, total: matches.count) }

    private func recompute(resetToFirst: Bool) {
        matches = DrawingTextFind.matches(of: query, in: allRuns)
        if matches.isEmpty {
            current = nil
        } else if resetToFirst {
            current = 0
        } else if let c = current {
            current = min(c, matches.count - 1)
        } else {
            current = 0
        }
    }

    // MARK: Copy All Text

    /// Every run's text in reading order as plain text (drawing text, then picture text),
    /// for the "Copy All Text" command. Empty when the drawing has no text.
    func copyAllText() -> String { DrawingTextExtractor.copyAllText(allRuns) }
}
