import CoreGraphics
import Foundation
import Testing
#if os(macOS)
import AppKit
#endif

// F3b unit tests for the find UI's pure state and geometry: the view-space highlight
// mapping (`FindHighlightGeometry`), the find bar's query/navigation state
// (`DrawingFindModel`), Copy All Text enablement, and the ⌘F/⌘G menu audit.

@Suite struct DrawingFindUITests {

    private func run(_ text: String, _ rect: CGRect, _ source: DrawingTextRun.Source = .drawing) -> DrawingTextRun {
        DrawingTextRun(text: text, boundsDevice: rect, fontFamily: nil, fontSize: nil, source: source)
    }

    /// A run carrying glyph-layout metrics (GDI-style), so Find derives per-match
    /// substring boxes from its Dx advances and transform (P3).
    private func layoutRun(
        _ text: String,
        advances: [UInt32],
        em: Double = 10,
        reference: CGPoint = .zero,
        align: UInt32 = 0,
        transform: CGAffineTransform = .identity,
        family: String? = nil,
        rect: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    ) -> DrawingTextRun {
        DrawingTextRun(
            text: text, boundsDevice: rect, fontFamily: family, fontSize: em, source: .drawing,
            layout: TextRunLayout(
                referenceLogical: reference, emLogical: em, advancesLogical: advances,
                alignRawValue: align, transform: transform, bold: false, italic: false))
    }

    // A straight device→view mapping: a 100×100 device page onto a 200×200 view, no y-flip,
    // so a device point (x,y) maps to (2x, 2y) — easy to reason about in tests.
    private var mapping: EditorCanvasMapping {
        EditorCanvasMapping(
            pageBoundsDevice: CGRect(x: 0, y: 0, width: 100, height: 100),
            target: CGRect(x: 0, y: 0, width: 200, height: 200),
            flipY: false
        )
    }

    // MARK: FindHighlightGeometry

    @Test func viewRectsMapThroughTheMapping() {
        let matches = [
            DrawingTextFind.Match(runIndex: 0, boundsDevice: CGRect(x: 10, y: 20, width: 30, height: 10), source: .drawing, occurrence: 0),
        ]
        let rects = FindHighlightGeometry.allViewRects(matches, mapping: mapping)
        #expect(rects.count == 1)
        // (x,y,w,h) scale ×2 through the mapping.
        #expect(rects.first == CGRect(x: 20, y: 40, width: 60, height: 20))
    }

    @Test func duplicateBoundsCollapseToOneFill() {
        // Two occurrences in one run share the run's bounds → one highlight rect.
        let bounds = CGRect(x: 5, y: 5, width: 20, height: 8)
        let matches = [
            DrawingTextFind.Match(runIndex: 0, boundsDevice: bounds, source: .drawing, occurrence: 0),
            DrawingTextFind.Match(runIndex: 0, boundsDevice: bounds, source: .drawing, occurrence: 1),
        ]
        #expect(FindHighlightGeometry.allViewRects(matches, mapping: mapping).count == 1)
    }

    @Test func nullBoundsAreDropped() {
        let matches = [
            DrawingTextFind.Match(runIndex: 0, boundsDevice: .null, source: .drawing, occurrence: 0),
        ]
        #expect(FindHighlightGeometry.allViewRects(matches, mapping: mapping).isEmpty)
        #expect(FindHighlightGeometry.currentViewRect(matches, current: 0, mapping: mapping) == nil)
        #expect(FindHighlightGeometry.matchDeviceRect(matches, current: 0) == nil)
    }

    @Test func currentViewRectTracksTheCurrentIndex() {
        let matches = [
            DrawingTextFind.Match(runIndex: 0, boundsDevice: CGRect(x: 0, y: 0, width: 10, height: 10), source: .drawing, occurrence: 0),
            DrawingTextFind.Match(runIndex: 1, boundsDevice: CGRect(x: 50, y: 50, width: 10, height: 10), source: .drawing, occurrence: 0),
        ]
        #expect(FindHighlightGeometry.currentViewRect(matches, current: 1, mapping: mapping) == CGRect(x: 100, y: 100, width: 20, height: 20))
        #expect(FindHighlightGeometry.currentViewRect(matches, current: nil, mapping: mapping) == nil)
    }

    @Test func zoomToFitOnlyShrinksAnOversizeMatch() {
        // A device rect 80×80 maps to a view rect 160×160. In a 200×200 viewport (margin 24
        // → 152 available) it overflows at 1×, so a zoom < 1 is returned.
        let big = CGRect(x: 10, y: 10, width: 80, height: 80)
        let z = FindHighlightGeometry.zoomToFit(
            deviceRect: big, mapping: mapping, viewport: CGSize(width: 200, height: 200),
            currentZoom: 1, minZoom: 0.1)
        #expect(z != nil)
        #expect((z ?? 1) < 1)
        // A small match that already fits returns nil (no zoom change).
        let small = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(FindHighlightGeometry.zoomToFit(
            deviceRect: small, mapping: mapping, viewport: CGSize(width: 200, height: 200),
            currentZoom: 1, minZoom: 0.1) == nil)
    }

    @Test func zoomToFitNeverZoomsIn() {
        // Even an oversize match never returns a zoom above the current one.
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        let z = FindHighlightGeometry.zoomToFit(
            deviceRect: big, mapping: mapping, viewport: CGSize(width: 50, height: 50),
            currentZoom: 0.5, minZoom: 0.05)
        #expect((z ?? 0) <= 0.5)
    }

    // MARK: DrawingTextBounds

    @Test func derivedTextBoxFromMetrics() {
        // TA_LEFT | TA_TOP, identity transform, no advances: width = count*em*0.6.
        let box = DrawingTextBounds.deviceBox(
            referenceLogical: CGPoint(x: 10, y: 20), emLogical: 10, advancesLogical: [],
            utf16Count: 5, alignRawValue: 0, transform: .identity)
        #expect(box.minX == 10)
        #expect(box.minY == 20)
        #expect(box.width == 30)          // 5 * 10 * 0.6
        #expect(box.height == 12.5)       // em * 1.25
    }

    @Test func derivedTextBoxUsesAdvancesAndRightAlign() {
        // TA_RIGHT (0x2): the reference point is the run's right edge.
        let box = DrawingTextBounds.deviceBox(
            referenceLogical: CGPoint(x: 100, y: 0), emLogical: 10, advancesLogical: [20, 20, 20],
            utf16Count: 3, alignRawValue: 0x2, transform: .identity)
        #expect(box.width == 60)          // sum of advances
        #expect(box.maxX == 100)          // right edge at the reference
    }

    @Test func derivedTextBoxNullForUnknownEm() {
        #expect(DrawingTextBounds.deviceBox(
            referenceLogical: .zero, emLogical: 0, advancesLogical: [],
            utf16Count: 3, alignRawValue: 0, transform: .identity).isNull)
    }

    @Test func derivedTextBoxMapsThroughTransform() {
        // A ×2 scale doubles the box's device extent.
        let box = DrawingTextBounds.deviceBox(
            referenceLogical: CGPoint(x: 5, y: 5), emLogical: 10, advancesLogical: [10, 10],
            utf16Count: 2, alignRawValue: 0, transform: CGAffineTransform(scaleX: 2, y: 2))
        #expect(box.minX == 10)
        #expect(box.width == 40)          // 20 logical * 2
    }

    // MARK: DrawingTextBounds.substringBox (P3)

    @Test func substringBoxOffsetsByLeadAndWidth() {
        // Whole run width 60, substring "cd" at lead 20, width 20, TA_LEFT/TOP.
        let box = DrawingTextBounds.substringBox(
            referenceLogical: .zero, emLogical: 10, totalWidthLogical: 60,
            leadLogical: 20, matchWidthLogical: 20, alignRawValue: 0, transform: .identity)
        #expect(box.minX == 20)
        #expect(box.width == 20)
        #expect(box.minY == 0)
        #expect(box.height == 12.5)   // em * 1.25
    }

    @Test func substringBoxRightAlignUsesTotalWidth() {
        // TA_RIGHT (0x2): the run's right edge is the reference; the run starts at
        // refX - total, and the substring offsets from there.
        let box = DrawingTextBounds.substringBox(
            referenceLogical: CGPoint(x: 100, y: 0), emLogical: 10, totalWidthLogical: 60,
            leadLogical: 0, matchWidthLogical: 20, alignRawValue: 0x2, transform: .identity)
        #expect(box.minX == 40)       // 100 - 60
        #expect(box.width == 20)
    }

    @Test func substringBoxMapsThroughTransform() {
        // A ×2 scale doubles the device extent and offset.
        let box = DrawingTextBounds.substringBox(
            referenceLogical: .zero, emLogical: 10, totalWidthLogical: 40,
            leadLogical: 10, matchWidthLogical: 10, alignRawValue: 0,
            transform: CGAffineTransform(scaleX: 2, y: 2))
        #expect(box.minX == 20)       // 10 * 2
        #expect(box.width == 20)      // 10 * 2
    }

    @Test func substringBoxNullForUnknownEm() {
        #expect(DrawingTextBounds.substringBox(
            referenceLogical: .zero, emLogical: 0, totalWidthLogical: 10,
            leadLogical: 0, matchWidthLogical: 5, alignRawValue: 0, transform: .identity).isNull)
    }

    // MARK: FindMatchBoxes (P3)

    @Test func twoMatchesInOneRunGetTwoDistinctBoxes() {
        // "abcabc" with uniform 10-unit advances: "abc" matches twice, at lead 0
        // and lead 30 — two distinct, non-overlapping highlight boxes.
        let run = layoutRun("abcabc", advances: [10, 10, 10, 10, 10, 10])
        let raw = DrawingTextFind.matches(of: "abc", in: [run])
        #expect(raw.count == 2)
        let refined = FindMatchBoxes.refined(raw, orderedRuns: DrawingTextExtractor.readingOrder([run]))
        #expect(refined.count == 2)
        #expect(refined[0].boundsDevice == CGRect(x: 0, y: 0, width: 30, height: 12.5))
        #expect(refined[1].boundsDevice == CGRect(x: 30, y: 0, width: 30, height: 12.5))
        #expect(refined[0].boundsDevice != refined[1].boundsDevice)
    }

    @Test func dxAdvancesArePerMatchHonoured() {
        // Condensed then expanded spacing: "AB" first (5+5), "AB" second (20+20).
        // The two "AB" matches get boxes of DIFFERENT widths from the Dx array.
        let run = layoutRun("ABAB", advances: [5, 5, 20, 20])
        let raw = DrawingTextFind.matches(of: "AB", in: [run])
        let refined = FindMatchBoxes.refined(raw, orderedRuns: DrawingTextExtractor.readingOrder([run]))
        #expect(refined.count == 2)
        #expect(refined[0].boundsDevice.width == 10)   // 5 + 5
        #expect(refined[1].boundsDevice.width == 40)   // 20 + 20
        #expect(refined[1].boundsDevice.minX == 10)    // after the first pair
    }

    @Test func rotatedRunProducesDistinctFiniteBoxes() {
        // A 90° rotation: the per-match boxes are still distinct and finite.
        let rot = CGAffineTransform(rotationAngle: .pi / 2)
        let run = layoutRun("abcabc", advances: [10, 10, 10, 10, 10, 10], transform: rot)
        let raw = DrawingTextFind.matches(of: "abc", in: [run])
        let refined = FindMatchBoxes.refined(raw, orderedRuns: DrawingTextExtractor.readingOrder([run]))
        #expect(refined.count == 2)
        let a = refined[0].boundsDevice, b = refined[1].boundsDevice
        #expect(!a.isNull && !b.isNull)
        #expect(a.width.isFinite && a.height.isFinite && b.width.isFinite && b.height.isFinite)
        // Rotation swaps the long axis onto y, so the boxes separate vertically.
        #expect(abs(a.minY - b.minY) > 1)
        #expect(a != b)
    }

    @Test func noDxFallsBackToFontMeasurement() {
        // No Dx array: FindMatchBoxes measures the resolved font (FontMapper) so the
        // two "a" matches still get distinct, left-to-right boxes.
        let run = layoutRun("aba", advances: [], em: 20, family: "Helvetica")
        let raw = DrawingTextFind.matches(of: "a", in: [run])
        #expect(raw.count == 2)
        let refined = FindMatchBoxes.refined(raw, orderedRuns: DrawingTextExtractor.readingOrder([run]))
        #expect(refined.count == 2)
        #expect(refined[0].boundsDevice.minX < refined[1].boundsDevice.minX)
        #expect(!refined[0].boundsDevice.isNull && !refined[1].boundsDevice.isNull)
    }

    @Test func runWithoutLayoutKeepsWholeRunBounds() {
        // An OCR/EMF+ run carries no layout; both matches keep the whole-run box.
        let bounds = CGRect(x: 5, y: 5, width: 40, height: 10)
        let plain = run("x y x", bounds)
        let raw = DrawingTextFind.matches(of: "x", in: [plain])
        let refined = FindMatchBoxes.refined(raw, orderedRuns: DrawingTextExtractor.readingOrder([plain]))
        #expect(refined.count == 2)
        #expect(refined.allSatisfy { $0.boundsDevice == bounds })
    }

    @Test func matchesCarryCharacterRanges() {
        let run = layoutRun("abcabc", advances: [10, 10, 10, 10, 10, 10])
        let raw = DrawingTextFind.matches(of: "abc", in: [run])
        #expect(raw[0].characterRangeUTF16 == 0..<3)
        #expect(raw[1].characterRangeUTF16 == 3..<6)
    }

    // MARK: DrawingFindModel

    @MainActor
    @Test func modelFindsAndNavigates() {
        let model = DrawingFindModel()
        let runs = [
            run("alpha beta", CGRect(x: 0, y: 0, width: 40, height: 10)),
            run("beta gamma", CGRect(x: 0, y: 20, width: 40, height: 10)),
        ]
        model.setRuns(runs, contentID: 1)
        #expect(model.hasText)
        model.query = "beta"
        model.applyQuery()
        #expect(model.matches.count == 2)
        #expect(model.current == 0)
        #expect(model.statusText == "1 of 2")
        model.goNext()
        #expect(model.current == 1)
        #expect(model.statusText == "2 of 2")
        model.goNext()   // wraps
        #expect(model.current == 0)
        model.goPrevious()   // wraps back
        #expect(model.current == 1)
    }

    @MainActor
    @Test func emptyQueryClearsMatches() {
        let model = DrawingFindModel()
        model.setRuns([run("hello", CGRect(x: 0, y: 0, width: 10, height: 10))], contentID: 1)
        model.query = "hello"
        model.applyQuery()
        #expect(model.matches.count == 1)
        model.query = ""
        model.applyQuery()
        #expect(model.matches.isEmpty)
        #expect(model.current == nil)
        #expect(model.statusText == "")
    }

    @MainActor
    @Test func dismissClearsQueryButKeepsRuns() {
        let model = DrawingFindModel()
        model.setRuns([run("keep me", CGRect(x: 0, y: 0, width: 10, height: 10))], contentID: 1)
        model.query = "keep"
        model.applyQuery()
        model.present()
        model.dismiss()
        #expect(!model.isPresented)
        #expect(model.query == "")
        #expect(model.matches.isEmpty)
        #expect(model.hasText)   // runs retained, so reopening is instant
    }

    @MainActor
    @Test func copyAllTextAndEnablement() {
        let model = DrawingFindModel()
        #expect(!model.hasText)
        #expect(model.copyAllText().isEmpty)
        let runs = [
            run("second line", CGRect(x: 0, y: 20, width: 40, height: 10)),
            run("first line", CGRect(x: 0, y: 0, width: 40, height: 10)),
        ]
        model.setRuns(runs, contentID: 1)
        #expect(model.hasText)
        // Copy All Text joins in reading order (top-to-bottom), not insertion order.
        #expect(model.copyAllText() == "first line\nsecond line")
    }

    // MARK: Picture (OCR) run merging (F3c)

    @MainActor
    @Test func pictureRunsMergeIntoMatchesAndCopy() {
        let model = DrawingFindModel()
        model.setRuns([run("invoice heading", CGRect(x: 0, y: 0, width: 40, height: 10))], contentID: 7)
        model.query = "invoice"
        model.applyQuery()
        #expect(model.matches.count == 1)

        // OCR finds another "invoice" inside a picture; it merges into the matches.
        model.beginReadingPictures()
        #expect(model.isReadingPictures)
        model.setPictureRuns([run("INVOICE 2026", CGRect(x: 0, y: 50, width: 60, height: 12), .picture)], contentID: 7)
        #expect(!model.isReadingPictures)
        #expect(model.matches.count == 2)
        // The picture match is tagged so the bar can show "in picture".
        #expect(model.matches.contains { $0.source == .picture })
        // Copy All Text groups picture text under its heading.
        #expect(model.copyAllText() == "invoice heading\n\nText in pictures:\nINVOICE 2026")
    }

    @MainActor
    @Test func stalePictureRunsForAnotherDrawingAreIgnored() {
        let model = DrawingFindModel()
        model.setRuns([run("page one", CGRect(x: 0, y: 0, width: 40, height: 10))], contentID: 1)
        // A late OCR result keyed to a DIFFERENT drawing must not leak in.
        model.setPictureRuns([run("stale", CGRect(x: 0, y: 0, width: 10, height: 10), .picture)], contentID: 99)
        #expect(model.pictureRuns.isEmpty)
    }

    @MainActor
    @Test func changingDrawingDropsPreviousPictureRuns() {
        let model = DrawingFindModel()
        model.setRuns([run("first", CGRect(x: 0, y: 0, width: 40, height: 10))], contentID: 1)
        model.setPictureRuns([run("pic", CGRect(x: 0, y: 30, width: 20, height: 10), .picture)], contentID: 1)
        #expect(!model.pictureRuns.isEmpty)
        // A new drawing clears the old picture text immediately.
        model.setRuns([run("second", CGRect(x: 0, y: 0, width: 40, height: 10))], contentID: 2)
        #expect(model.pictureRuns.isEmpty)
    }

    @MainActor
    @Test func clearingPictureRunsReMatchesDrawingTextAlone() {
        let model = DrawingFindModel()
        model.setRuns([run("report total", CGRect(x: 0, y: 0, width: 40, height: 10))], contentID: 1)
        model.setPictureRuns([run("TOTAL 99", CGRect(x: 0, y: 30, width: 30, height: 10), .picture)], contentID: 1)
        model.query = "total"
        model.applyQuery()
        #expect(model.matches.count == 2)
        model.clearPictureRuns()   // the toggle turned OCR off
        #expect(model.matches.count == 1)
        #expect(model.pictureRuns.isEmpty)
    }

    // MARK: Menu audit (⌘F / ⌘G)

    #if os(macOS)
    @MainActor
    @Test func menuAuditCountsEachFindShortcutOnce() {
        let menu = NSMenu()
        let edit = NSMenuItem()
        let editSub = NSMenu(title: "Edit")
        let findItem = NSMenuItem(title: "Find…", action: nil, keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command]
        let nextItem = NSMenuItem(title: "Find Next", action: nil, keyEquivalent: "g")
        nextItem.keyEquivalentModifierMask = [.command]
        let prevItem = NSMenuItem(title: "Find Previous", action: nil, keyEquivalent: "g")
        prevItem.keyEquivalentModifierMask = [.command, .shift]
        editSub.addItem(findItem)
        editSub.addItem(nextItem)
        editSub.addItem(prevItem)
        edit.submenu = editSub
        menu.addItem(edit)

        #expect(MenuShortcutAudit.count(key: "f", modifiers: [.command], in: menu) == 1)
        #expect(MenuShortcutAudit.count(key: "g", modifiers: [.command], in: menu) == 1)
        #expect(MenuShortcutAudit.count(key: "g", modifiers: [.command, .shift], in: menu) == 1)
    }
    #endif
}
