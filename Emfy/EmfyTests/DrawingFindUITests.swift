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
