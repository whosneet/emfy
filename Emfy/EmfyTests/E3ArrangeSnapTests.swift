import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3e unit tests for the pure align/distribute maths, the snap solver (including its
// threshold edges and the per-event perf budget), the fix-B editor re-fit maths, and the
// DocumentSession align/distribute integration (one undo per action, single-element vs
// page reference). All pure except the session tests, which drive an injected-scene
// session like DocumentEditingTests.

// MARK: - Fixtures

private func box(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> EditorArrange.Box {
    EditorArrange.Box(id: id, rect: CGRect(x: x, y: y, width: w, height: h))
}

// MARK: - Align

@Suite struct EditorArrangeAlignTests {

    @Test func alignLeftRightCentreToReference() {
        let boxes = [box(1, 10, 0, 20, 10), box(2, 50, 0, 40, 10)]
        let ref = EditorArrange.union(of: boxes)   // minX 10, maxX 90, midX 50
        let left = EditorArrange.alignDeltas(boxes, to: ref, .left)
        #expect(left.first { $0.id == 1 }?.dx == 0)
        #expect(left.first { $0.id == 2 }?.dx == -40)   // 10 - 50
        let right = EditorArrange.alignDeltas(boxes, to: ref, .right)
        #expect(right.first { $0.id == 1 }?.dx == 60)   // 90 - 30
        #expect(right.first { $0.id == 2 }?.dx == 0)
        let centre = EditorArrange.alignDeltas(boxes, to: ref, .centreHorizontal)
        #expect(centre.first { $0.id == 1 }?.dx == 30)  // 50 - 20
        #expect(centre.first { $0.id == 2 }?.dx == -20) // 50 - 70
        // Horizontal align never moves y.
        #expect(left.allSatisfy { $0.dy == 0 })
    }

    @Test func alignTopMiddleBottomToReference() {
        let boxes = [box(1, 0, 10, 10, 20), box(2, 0, 50, 10, 40)]
        let ref = EditorArrange.union(of: boxes)   // minY 10, maxY 90, midY 50
        let top = EditorArrange.alignDeltas(boxes, to: ref, .top)
        #expect(top.first { $0.id == 1 }?.dy == 0)
        #expect(top.first { $0.id == 2 }?.dy == -40)
        let bottom = EditorArrange.alignDeltas(boxes, to: ref, .bottom)
        #expect(bottom.first { $0.id == 1 }?.dy == 60)
        #expect(bottom.first { $0.id == 2 }?.dy == 0)
        let middle = EditorArrange.alignDeltas(boxes, to: ref, .centreVertical)
        #expect(middle.first { $0.id == 1 }?.dy == 30)
        #expect(middle.first { $0.id == 2 }?.dy == -20)
        #expect(top.allSatisfy { $0.dx == 0 })
    }

    @Test func singleElementAlignsToAnExplicitReferenceRect() {
        // A single element aligns to the given reference (the caller passes the page bounds).
        let page = CGRect(x: 0, y: 0, width: 200, height: 100)
        let one = [box(1, 40, 40, 20, 20)]
        let centreH = EditorArrange.alignDeltas(one, to: page, .centreHorizontal)
        #expect(centreH.first?.dx == 50)    // page.midX 100 - box.midX 50
        let left = EditorArrange.alignDeltas(one, to: page, .left)
        #expect(left.first?.dx == -40)      // 0 - 40
    }

    @Test func degenerateBoxesSkipped() {
        let boxes = [box(1, 0, 0, 10, 10), EditorArrange.Box(id: 2, rect: .null)]
        let deltas = EditorArrange.alignDeltas(boxes, to: CGRect(x: 0, y: 0, width: 100, height: 100), .left)
        #expect(deltas.count == 1)
        #expect(deltas.first?.id == 1)
    }
}

// MARK: - Distribute

@Suite struct EditorArrangeDistributeTests {

    @Test func distributeHorizontallyEqualisesGapsAndFixesExtremes() {
        // Three boxes, uneven spacing. Widths 20/10/20, span 0…120.
        let boxes = [box(1, 0, 0, 20, 10), box(2, 30, 0, 10, 10), box(3, 100, 0, 20, 10)]
        let deltas = EditorArrange.distributeDeltas(boxes, .horizontal)
        // Extremes stay put.
        #expect(deltas.first { $0.id == 1 }?.dx == 0)
        #expect(deltas.first { $0.id == 3 }?.dx == 0)
        // gap = (120 - 50) / 2 = 35 → middle box minX = 0 + 20 + 35 = 55; was 30 → dx 25.
        #expect(deltas.first { $0.id == 2 }?.dx == 25)
        #expect(deltas.allSatisfy { $0.dy == 0 })
    }

    @Test func distributeVerticallyEqualisesGaps() {
        let boxes = [box(1, 0, 0, 10, 20), box(2, 0, 30, 10, 10), box(3, 0, 100, 10, 20)]
        let deltas = EditorArrange.distributeDeltas(boxes, .vertical)
        #expect(deltas.first { $0.id == 1 }?.dy == 0)
        #expect(deltas.first { $0.id == 3 }?.dy == 0)
        #expect(deltas.first { $0.id == 2 }?.dy == 25)
        #expect(deltas.allSatisfy { $0.dx == 0 })
    }

    @Test func distributeNeedsThreeElements() {
        #expect(EditorArrange.distributeDeltas([box(1, 0, 0, 10, 10), box(2, 50, 0, 10, 10)], .horizontal).isEmpty)
        #expect(EditorArrange.distributeDeltas([box(1, 0, 0, 10, 10)], .vertical).isEmpty)
    }
}

// MARK: - Snap solver

@Suite struct EditorSnapTests {

    @Test func snapsMovingEdgeToNearestLineWithinThreshold() {
        let candidates = EditorSnap.Candidates(xs: [100], ys: [], gridSpacing: nil)
        // A wide rect so only the LEFT edge is near the line (mid/right are far): left sits
        // 4 away from line 100, threshold 6 → snaps by +4.
        let rect = CGRect(x: 96, y: 0, width: 200, height: 10)
        let result = EditorSnap.snapMove(rect, candidates: candidates, threshold: 6)
        #expect(result.dx == 4)   // 100 - 96
        #expect(result.guideXs == [100])
        #expect(result.dy == 0)
    }

    @Test func thresholdEdgeInclusiveAndExclusive() {
        let candidates = EditorSnap.Candidates(xs: [100], ys: [], gridSpacing: nil)
        // A wide rect so only the left edge is in play. Exactly at threshold → snaps.
        let atEdge = EditorSnap.snapMove(CGRect(x: 94, y: 0, width: 200, height: 10), candidates: candidates, threshold: 6)
        #expect(atEdge.dx == 6)
        // Just beyond threshold → no snap.
        let beyond = EditorSnap.snapMove(CGRect(x: 93.9, y: 0, width: 200, height: 10), candidates: candidates, threshold: 6)
        #expect(beyond.dx == 0)
        #expect(beyond.guideXs.isEmpty)
    }

    @Test func closestEdgeOfTheMovingBoxWins() {
        // minX 96 (off 4 to 100), midX 101 (off −1), maxX 106 (off −6): the mid edge is
        // closest, so the whole box shifts by −1 and the guide shows at 100.
        let candidates = EditorSnap.Candidates(xs: [100], ys: [], gridSpacing: nil)
        let result = EditorSnap.snapMove(CGRect(x: 96, y: 0, width: 10, height: 10), candidates: candidates, threshold: 6)
        #expect(result.dx == -1)
        #expect(result.guideXs == [100])
    }

    @Test func closestCandidateWinsAcrossEdges() {
        // Left at 96 (line 100, off 4) vs right at 112 (line 110, off -2): the right wins.
        let candidates = EditorSnap.Candidates(xs: [100, 110], ys: [], gridSpacing: nil)
        let rect = CGRect(x: 96, y: 0, width: 16, height: 10)   // left 96, right 112
        let result = EditorSnap.snapMove(rect, candidates: candidates, threshold: 6)
        #expect(result.dx == -2)
    }

    @Test func snapsToGridAnalytically() {
        let candidates = EditorSnap.Candidates(xs: [], ys: [], gridSpacing: 50)
        // Left at 48 → nearest grid line 50, off 2.
        let rect = CGRect(x: 48, y: 148, width: 10, height: 10)
        let result = EditorSnap.snapMove(rect, candidates: candidates, threshold: 6)
        #expect(result.dx == 2)
        #expect(result.dy == 2)   // 148 → 150
        #expect(result.guideXs == [50])
        #expect(result.guideYs == [150])
    }

    @Test func noCandidatesNoSnap() {
        let result = EditorSnap.snapMove(CGRect(x: 10, y: 10, width: 5, height: 5), candidates: .empty, threshold: 6)
        #expect(!result.snapped)
    }

    @Test func axesAreIndependent() {
        let candidates = EditorSnap.Candidates(xs: [100], ys: [200], gridSpacing: nil)
        // A large rect so only the top-left corner edges are near their lines on each axis.
        let rect = CGRect(x: 97, y: 197, width: 300, height: 300)
        let result = EditorSnap.snapMove(rect, candidates: candidates, threshold: 6)
        #expect(result.dx == 3)   // 100 - 97
        #expect(result.dy == 3)   // 200 - 197
    }

    /// Perf budget (E3e design call 3): with the candidate set pre-collected once, each
    /// per-event snap must stay well under 4 ms on a 15.7k-element scene.
    @Test func perEventSnapUnderBudget() {
        let count = 15_700
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        xs.reserveCapacity(count * 3)
        ys.reserveCapacity(count * 3)
        for i in 0..<count {
            let x = CGFloat(i % 500) * 7 + 0.5
            let y = CGFloat(i % 500) * 9 + 0.5
            xs.append(contentsOf: [x, x + 5, x + 10])
            ys.append(contentsOf: [y, y + 5, y + 10])
        }
        let candidates = EditorSnap.Candidates(xs: xs, ys: ys, gridSpacing: 37)
        let iterations = 200
        let start = Date()
        var sink = 0
        for i in 0..<iterations {
            let rect = CGRect(x: CGFloat(i) * 3 + 1, y: CGFloat(i) * 2 + 1, width: 40, height: 30)
            let r = EditorSnap.snapMove(rect, candidates: candidates, threshold: 6)
            if r.snapped { sink += 1 }
        }
        let perEvent = Date().timeIntervalSince(start) / Double(iterations)
        #expect(perEvent < 0.004, "per-event snap \(perEvent * 1000) ms exceeds 4 ms budget")
        #expect(sink >= 0)
    }
}

// MARK: - Fix B re-fit maths

@Suite struct EditorRefitTests {
    private let content = CGSize(width: 800, height: 600)
    private func refit(
        viewport: CGSize, current: CGFloat, prevFit: CGFloat, fitted: Bool, changed: Bool
    ) -> CGFloat? {
        ViewerFit.editorRefitScale(
            content: content, viewport: viewport, insets: .zero, margin: 24,
            minScale: 0.01, maxScale: 8,
            currentMagnification: current, previousFitScale: prevFit,
            hasFittedBefore: fitted, viewportChanged: changed)
    }

    @Test func firstLayoutAlwaysFits() {
        let r = refit(viewport: CGSize(width: 400, height: 300), current: 1, prevFit: 0, fitted: false, changed: false)
        #expect(r != nil)
    }

    @Test func noViewportChangeKeepsCurrent() {
        #expect(refit(viewport: CGSize(width: 400, height: 300), current: 0.4, prevFit: 0.4, fitted: true, changed: false) == nil)
    }

    @Test func stillFittedFollowsNewViewport() {
        let prevFit = ViewerFit.fitScale(content: content, viewport: CGSize(width: 800, height: 600), insets: .zero, margin: 24, minScale: 0.01, maxScale: 8)
        let newFit = ViewerFit.fitScale(content: content, viewport: CGSize(width: 400, height: 600), insets: .zero, margin: 24, minScale: 0.01, maxScale: 8)
        let r = refit(viewport: CGSize(width: 400, height: 600), current: prevFit, prevFit: prevFit, fitted: true, changed: true)
        #expect(r == newFit)
    }

    @Test func manualZoomKeptWhenStillFits() {
        // A small manual zoom where the content still fits the (large) viewport → keep it.
        #expect(refit(viewport: CGSize(width: 2000, height: 2000), current: 0.5, prevFit: 0.3, fitted: true, changed: true) == nil)
    }

    @Test func manualZoomSnapsBackWhenOverflowing() {
        // Manually zoomed in (2×) then the viewport shrinks so the page overflows → re-fit.
        let r = refit(viewport: CGSize(width: 400, height: 300), current: 2, prevFit: 0.3, fitted: true, changed: true)
        #expect(r != nil)
        #expect(r! < 2)
    }
}

// MARK: - DocumentSession integration

@MainActor
private func alignScene() -> Scene {
    func rect(_ id: Int, _ r: CGRect) -> Element {
        let segs: [ScenePath.Segment] = [.move(CGPoint(x: r.minX, y: r.minY)), .line(CGPoint(x: r.maxX, y: r.minY)),
                                         .line(CGPoint(x: r.maxX, y: r.maxY)), .line(CGPoint(x: r.minX, y: r.maxY)), .close]
        var style = SceneStyle()
        style.fill = SceneFill(color: SceneColor(red: 0, green: 0, blue: 0), evenOdd: false)
        return Element(id: id, kind: .rect, geometryDevice: ScenePath(segments: segs), transform: .identity,
                       style: style, provenance: Provenance(sourceRecordIndices: [id]))
    }
    let elements = [rect(1, CGRect(x: 10, y: 10, width: 20, height: 20)),
                    rect(2, CGRect(x: 60, y: 40, width: 20, height: 20)),
                    rect(3, CGRect(x: 120, y: 70, width: 20, height: 20))]
    let layer = Layer(id: 0, name: "L", elements: elements)
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
    return Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 300, height: 200), layers: [layer], partition: partition, source: source)
}

@MainActor
private func makeAlignSession() async -> DocumentSession {
    let nonFiring: @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(86_400)) }
    let scene = alignScene()
    let session = DocumentSession(
        entryID: UUID(),
        resolve: { _ in Data([0x01]) },
        importScene: { _ in scene },
        documentFileName: { "drawing.emf" },
        autosave: AutosaveController(sleep: nonFiring))
    await session.beginEditing()
    return session
}

@MainActor
@Suite struct DocumentArrangeTests {

    @Test func alignTopIsOneUndoThatRevertsEveryElement() async {
        let session = await makeAlignSession()
        let before = session.editingScene!.elements
        let startCount = session.history?.undoCount ?? 0
        session.alignSelection([1, 2, 3], .top)
        // One undo entry for the whole action.
        #expect(session.history?.undoCount == startCount + 1)
        // Every element's top edge now equals the union top (minY 10).
        let aligned = session.editingScene!.elements
        for e in aligned { #expect(e.selectionBoundsDevice.minY == 10) }
        // A single undo (through the UndoManager, as the menu/⌘Z would) reverts all three.
        session.undoManager.undo()
        #expect(session.editingScene!.elements == before)
    }

    @Test func singleSelectionAlignsToThePage() async {
        let session = await makeAlignSession()
        // Element 1 at x 10, width 20 → centreH to page (width 300, midX 150): midX 20 → dx 130.
        session.alignSelection([1], .centreHorizontal)
        let e1 = session.editingScene!.elements.first { $0.id == 1 }!
        #expect(abs(e1.selectionBoundsDevice.midX - 150) < 0.001)
    }

    @Test func distributeHorizontallyIsOneUndo() async {
        let session = await makeAlignSession()
        let startCount = session.history?.undoCount ?? 0
        session.distributeSelection([1, 2, 3], .horizontal)
        #expect(session.history?.undoCount == startCount + 1)
    }

    @Test func distributeNeedsThreeSelected() async {
        let session = await makeAlignSession()
        let startCount = session.history?.undoCount ?? 0
        session.distributeSelection([1, 2], .horizontal)
        #expect(session.history?.undoCount == startCount)   // no-op
    }
}
