import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import Testing

// E2b unit tests for the pure editor tools: the view↔device mapping, hit testing,
// selection, resize/rotation maths, and the undo/round-trip guarantees a drag and a
// nudge must keep. All pure — scenes are built by hand (or imported from a byte
// fixture) so no canvas or window is needed.

// MARK: - Fixtures

private func makeScene(
    _ elements: [Element],
    layerHidden: Bool = false,
    layerLocked: Bool = false,
    page: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)
) -> Scene {
    let layer = Layer(id: 0, name: "L", elements: elements, hidden: layerHidden, locked: layerLocked)
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
    return Scene(pageBoundsDevice: page, layers: [layer], partition: partition, source: source)
}

private func rectElement(id: Int, rect: CGRect, filled: Bool = true, locked: Bool = false, hidden: Bool = false) -> Element {
    let segs: [ScenePath.Segment] = [
        .move(CGPoint(x: rect.minX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.maxY)),
        .line(CGPoint(x: rect.minX, y: rect.maxY)),
        .close,
    ]
    var style = SceneStyle()
    if filled { style.fill = SceneFill(color: SceneColor(red: 0, green: 0, blue: 0), evenOdd: false) }
    return Element(
        id: id, kind: .rect, geometryDevice: ScenePath(segments: segs),
        transform: .identity, style: style,
        provenance: Provenance(sourceRecordIndices: [id]), locked: locked, hidden: hidden
    )
}

private func lineElement(id: Int, from: CGPoint, to: CGPoint, width: Double = 2) -> Element {
    let segs: [ScenePath.Segment] = [.move(from), .line(to)]
    var style = SceneStyle()
    style.stroke = SceneStroke(
        color: SceneColor(red: 0, green: 0, blue: 0), isCosmetic: false, width: width,
        dash: .solid, cap: .round, join: .round, miterLimit: 10
    )
    return Element(
        id: id, kind: .line, geometryDevice: ScenePath(segments: segs),
        transform: .identity, style: style, provenance: Provenance(sourceRecordIndices: [id])
    )
}

private func passthroughElement(id: Int, rect: CGRect) -> Element {
    let e = rectElement(id: id, rect: rect)
    return Element(
        id: id, kind: .passthrough, geometryDevice: e.geometryDevice, transform: e.transform,
        style: e.style, provenance: Provenance(sourceRecordIndices: [id]),
        passthroughReason: .comment
    )
}

// MARK: - View ↔ device mapping

@Suite struct EditorCanvasMappingTests {

    @Test func roundTripsAtSeveralZoomsAndOffsets() {
        let page = CGRect(x: 0, y: 0, width: 200, height: 100)
        let targets = [
            CGRect(x: 0, y: 0, width: 200, height: 100),      // 1:1
            CGRect(x: 0, y: 0, width: 800, height: 400),      // 4×
            CGRect(x: 37, y: -19, width: 123, height: 61.5),  // scaled + offset
        ]
        let probes = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 73, y: 41)]
        for target in targets {
            let mapping = EditorCanvasMapping(pageBoundsDevice: page, target: target)
            for p in probes {
                let there = mapping.viewPoint(fromDevice: p)
                let back = mapping.devicePoint(fromView: there)
                #expect(abs(back.x - p.x) < 1e-6)
                #expect(abs(back.y - p.y) < 1e-6)
            }
        }
    }

    @Test func matchesSceneRendererDeviceToTargetIncludingTheYFlip() {
        // Device top (minY) must land at the view TOP for a y-up target, exactly as
        // SceneRenderer.deviceToTarget maps it.
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let mapping = EditorCanvasMapping(pageBoundsDevice: page, target: target)
        let deviceTop = mapping.viewPoint(fromDevice: CGPoint(x: 50, y: 0))
        let deviceBottom = mapping.viewPoint(fromDevice: CGPoint(x: 50, y: 100))
        #expect(abs(deviceTop.y - 100) < 1e-6)     // device minY → view maxY (y-up top)
        #expect(abs(deviceBottom.y - 0) < 1e-6)
    }

    @Test func deviceLengthScalesWithZoom() {
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        // At 1:1 a 4-point view tolerance is 4 device units; at 4× it is 1 device unit.
        let m1 = EditorCanvasMapping(pageBoundsDevice: page, target: CGRect(x: 0, y: 0, width: 100, height: 100))
        let m4 = EditorCanvasMapping(pageBoundsDevice: page, target: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(abs(m1.deviceLength(fromViewLength: 4) - 4) < 1e-6)
        #expect(abs(m4.deviceLength(fromViewLength: 4) - 1) < 1e-6)
    }

    @Test func nonFlippedMappingKeepsYDirectionForIOS() {
        // The iOS overlay is y-down like EMF device space, so flipY=false maps device
        // top (minY) to view top (minY) and round-trips.
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let m = EditorCanvasMapping(pageBoundsDevice: page, target: CGRect(x: 0, y: 0, width: 200, height: 200), flipY: false)
        #expect(abs(m.viewPoint(fromDevice: CGPoint(x: 50, y: 0)).y - 0) < 1e-6)
        #expect(abs(m.viewPoint(fromDevice: CGPoint(x: 50, y: 100)).y - 200) < 1e-6)
        let back = m.devicePoint(fromView: m.viewPoint(fromDevice: CGPoint(x: 30, y: 70)))
        #expect(abs(back.x - 30) < 1e-6 && abs(back.y - 70) < 1e-6)
    }

    @Test func conjugatedTranslationMovesInDeviceSpace() {
        // A pure view-space translation conjugates to a device-space translation with
        // the y component flipped (the mapping folds in the one y-flip).
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let mapping = EditorCanvasMapping(pageBoundsDevice: page, target: CGRect(x: 0, y: 0, width: 100, height: 100))
        let viewMove = CGAffineTransform(translationX: 5, y: 7)
        let deviceMove = mapping.deviceTransform(fromView: viewMove)
        let moved = CGPoint(x: 10, y: 10).applying(deviceMove)
        #expect(abs(moved.x - 15) < 1e-6)
        #expect(abs(moved.y - 3) < 1e-6)   // view +7 down ⇒ device −7 at 1:1
    }
}

// MARK: - Hit testing

@Suite struct EditorHitTestTests {

    @Test func hitsAFillInterior() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80))])
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == 1)
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 5, y: 5), strokeToleranceDevice: 2) == nil)
    }

    @Test func hitsNearAStroke() {
        // An open line from (20,50) to (80,50): a point 3 units off with a 4-unit
        // tolerance hits; one 10 units off misses.
        let scene = makeScene([lineElement(id: 1, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 80, y: 50), width: 1)])
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 50, y: 53), strokeToleranceDevice: 4) == 1)
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 50, y: 60), strokeToleranceDevice: 4) == nil)
    }

    @Test func topMostWins() {
        // Two overlapping fills; the later (top) element is returned.
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80)),
            rectElement(id: 2, rect: CGRect(x: 30, y: 30, width: 40, height: 40)),
        ])
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == 2)
        // Outside the top one, the bottom still hits.
        #expect(EditorHitTest.topmost(in: scene, atDevice: CGPoint(x: 15, y: 15), strokeToleranceDevice: 2) == 1)
    }

    @Test func skipsLockedHiddenAndPassthrough() {
        let locked = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80), locked: true)])
        #expect(EditorHitTest.topmost(in: locked, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == nil)

        let hidden = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80), hidden: true)])
        #expect(EditorHitTest.topmost(in: hidden, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == nil)

        let passthrough = makeScene([passthroughElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80))])
        #expect(EditorHitTest.topmost(in: passthrough, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == nil)
    }

    @Test func skipsHiddenOrLockedLayer() {
        let elements = [rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 80, height: 80))]
        let hiddenLayer = makeScene(elements, layerHidden: true)
        #expect(EditorHitTest.topmost(in: hiddenLayer, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == nil)
        let lockedLayer = makeScene(elements, layerLocked: true)
        #expect(EditorHitTest.topmost(in: lockedLayer, atDevice: CGPoint(x: 50, y: 50), strokeToleranceDevice: 2) == nil)
    }
}

// MARK: - Marquee + selection

@Suite struct EditorSelectionTests {

    @Test func marqueeSelectsIntersectingEditableElements() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            rectElement(id: 2, rect: CGRect(x: 60, y: 60, width: 20, height: 20)),
            passthroughElement(id: 3, rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
        ])
        // A marquee over the top-left corner catches id 1 only (2 is far, 3 passthrough).
        #expect(EditorHitTest.marquee(in: scene, deviceRect: CGRect(x: -5, y: -5, width: 30, height: 30)) == [1])
        // A marquee over everything catches both editable ids, never the passthrough.
        #expect(EditorHitTest.marquee(in: scene, deviceRect: CGRect(x: 0, y: 0, width: 100, height: 100)) == [1, 2])
    }

    @Test func clickReplacesAndShiftClickToggles() {
        var selection = EditorSelection()
        selection = selection.afterClick(hit: 1, additive: false)
        #expect(selection.ids == [1])
        selection = selection.afterClick(hit: 2, additive: true)   // shift-click adds
        #expect(selection.ids == [1, 2])
        selection = selection.afterClick(hit: 1, additive: true)   // shift-click again removes
        #expect(selection.ids == [2])
        selection = selection.afterClick(hit: 3, additive: false)  // plain click replaces
        #expect(selection.ids == [3])
        selection = selection.afterClick(hit: nil, additive: false) // empty click clears
        #expect(selection.isEmpty)
    }

    @Test func selectAllAndPruneSurviveUndo() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            rectElement(id: 2, rect: CGRect(x: 60, y: 60, width: 20, height: 20)),
            passthroughElement(id: 3, rect: CGRect(x: 40, y: 40, width: 10, height: 10)),
        ])
        var selection = EditorSelection()
        selection.selectAll(in: scene)
        #expect(selection.ids == [1, 2])   // editable only

        // After an undo removes id 2, prune drops it and keeps id 1.
        let afterUndo = makeScene([rectElement(id: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20))])
        selection.prune(to: afterUndo)
        #expect(selection.ids == [1])
    }

    @Test func selectionUnionBoundsAreMappingIndependent() throws {
        // Item 4: the device-space union is the same whatever the overlay's y-flip; the
        // flipped and non-flipped view rects cover the same on-screen region.
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
            rectElement(id: 2, rect: CGRect(x: 60, y: 70, width: 20, height: 10)),
        ])
        let selection = EditorSelection([1, 2])
        let deviceBox = try #require(selection.boundsDevice(in: scene))
        #expect(deviceBox == CGRect(x: 10, y: 10, width: 70, height: 70))
        let page = scene.pageBoundsDevice
        let target = CGRect(x: 0, y: 0, width: 200, height: 200)
        let flipped = EditorCanvasMapping(pageBoundsDevice: page, target: target, flipY: true).viewRect(fromDevice: deviceBox)
        let straight = EditorCanvasMapping(pageBoundsDevice: page, target: target, flipY: false).viewRect(fromDevice: deviceBox)
        #expect(abs(flipped.width - straight.width) < 1e-6)
        #expect(abs(flipped.height - straight.height) < 1e-6)
        #expect(abs(flipped.minX - straight.minX) < 1e-6)   // x is unaffected by the y-flip
    }

    @Test func boundingBoxIsTheUnionOfSelectedBounds() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            rectElement(id: 2, rect: CGRect(x: 60, y: 70, width: 20, height: 10)),
        ])
        var selection = EditorSelection([1, 2])
        let box = selection.boundsDevice(in: scene)
        #expect(box == CGRect(x: 0, y: 0, width: 80, height: 80))
        selection.clear()
        #expect(selection.boundsDevice(in: scene) == nil)
    }
}

// MARK: - Resize maths

@Suite struct EditorResizeTests {

    private func newBounds(_ handle: ResizeHandle, _ translation: CGVector, aspect: Bool = false, center: Bool = false) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let t = EditorTransform.resizeTransform(bounds: bounds, handle: handle, translation: translation, aspectLocked: aspect, fromCenter: center)
        return bounds.applying(t)
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) < epsilon && abs(a.minY - b.minY) < epsilon
            && abs(a.width - b.width) < epsilon && abs(a.height - b.height) < epsilon
    }

    @Test func eachCornerAndEdgeResizesFromTheOppositeAnchor() {
        // Bottom-right grows the max edges, top-left anchored.
        #expect(approxEqual(newBounds(.bottomRight, CGVector(dx: 20, dy: 10)), CGRect(x: 0, y: 0, width: 120, height: 110)))
        // Top-left grows the min edges, bottom-right anchored.
        #expect(approxEqual(newBounds(.topLeft, CGVector(dx: -20, dy: -10)), CGRect(x: -20, y: -10, width: 120, height: 110)))
        // The right edge moves only in x.
        #expect(approxEqual(newBounds(.right, CGVector(dx: 30, dy: 99)), CGRect(x: 0, y: 0, width: 130, height: 100)))
        // The top edge moves only in y.
        #expect(approxEqual(newBounds(.top, CGVector(dx: 99, dy: -40)), CGRect(x: 0, y: -40, width: 100, height: 140)))
    }

    @Test func shiftKeepsAspectRatioOnACorner() {
        // The larger deviation (x) drives both axes.
        #expect(approxEqual(newBounds(.bottomRight, CGVector(dx: 20, dy: 5), aspect: true), CGRect(x: 0, y: 0, width: 120, height: 120)))
    }

    @Test func optionResizesFromTheCentre() {
        // From the centre the opposite edge moves too: +10 on each side ⇒ +20 each
        // axis, centred.
        #expect(approxEqual(newBounds(.bottomRight, CGVector(dx: 10, dy: 10), center: true), CGRect(x: -10, y: -10, width: 120, height: 120)))
    }

    @Test func negativeDragIsClampedNotFlipped() {
        let r = newBounds(.bottomRight, CGVector(dx: -500, dy: -500))
        #expect(r.width >= 1 && r.width < 2)
        #expect(r.height >= 1 && r.height < 2)
    }
}

// MARK: - Rotation maths

@Suite struct EditorRotationTests {

    @Test func rotatesAPointAboutTheCentre() {
        let center = CGPoint(x: 0, y: 0)
        let t = EditorTransform.rotationTransform(center: center, from: CGPoint(x: 10, y: 0), to: CGPoint(x: 0, y: 10))
        let p = CGPoint(x: 10, y: 0).applying(t)
        #expect(abs(p.x - 0) < 1e-6)
        #expect(abs(p.y - 10) < 1e-6)
    }

    @Test func rotationReadoutIsInDegrees() {
        let center = CGPoint(x: 0, y: 0)
        let degrees = EditorTransform.rotationDegrees(center: center, from: CGPoint(x: 10, y: 0), to: CGPoint(x: 0, y: 10))
        #expect(abs(degrees - 90) < 1e-4)
    }

    @Test func rotationAboutAnOffsetCentreKeepsTheCentreFixed() {
        let center = CGPoint(x: 50, y: 50)
        let t = EditorTransform.rotationTransform(center: center, from: CGPoint(x: 60, y: 50), to: CGPoint(x: 50, y: 60))
        let fixed = center.applying(t)
        #expect(abs(fixed.x - 50) < 1e-6)
        #expect(abs(fixed.y - 50) < 1e-6)
    }
}

// MARK: - Move leaves no residue (item 1 regression)

@Suite struct EditorMoveRenderTests {

    private func samplePixel(_ image: CGImage, px: Int, py: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = max(0, min(h - 1, h - 1 - py))   // the bitmap is bottom-origin; py is top-origin
        let i = (row * w + max(0, min(w - 1, px))) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    /// A valid EMF with ONE solid-filled, border-less rectangle, so the import lifts a
    /// single element that re-synthesises correctly when edited.
    private func solidRectEMF(left: Int32, top: Int32, right: Int32, bottom: Int32, color: UInt32) -> Data {
        var body = Data()
        func w32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { body.append(contentsOf: $0) } }
        func rec(_ type: UInt32, _ payload: [UInt32]) {
            w32(type); w32(UInt32(8 + payload.count * 4)); payload.forEach(w32)
        }
        rec(37, [0x8000_0008])                                   // SELECTOBJECT NULL_PEN
        rec(39, [1, 0, color, 0])                                // CREATEBRUSHINDIRECT ih=1, solid
        rec(37, [1])                                             // SELECTOBJECT brush 1
        rec(43, [UInt32(bitPattern: left), UInt32(bitPattern: top), UInt32(bitPattern: right), UInt32(bitPattern: bottom)])
        rec(14, [0, 16, 20])                                     // EOF
        var d = Data()
        func h32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func hi(_ v: Int32) { h32(UInt32(bitPattern: v)) }
        func h16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        h32(1); h32(88)
        hi(0); hi(0); hi(99); hi(99)
        hi(0); hi(0); hi(2117); hi(2117)
        h32(0x464D_4520); h32(0x0001_0000); h32(88 + UInt32(body.count)); h32(6)
        h16(8); h16(0); h32(0); h32(0); h32(0)
        hi(1920); hi(1080); hi(508); hi(286)
        d.append(body)
        return d
    }

    @Test func movingAnElementLeavesTheVacatedAreaBackground() throws {
        // One solid rect at device (20,20)-(70,60). After moving it +30,+30, the ORIGINAL
        // centre must render as background — no residue left behind — and the element must
        // still render somewhere (it moved, it didn't vanish). This is the item-1
        // regression: the "leftover frame" was a decomposed fixture selected in part, not
        // a render fault, so a clean single element leaves the vacated area blank.
        let scene = try SceneImporter.import(data: solidRectEMF(left: 20, top: 20, right: 70, bottom: 60, color: 0x0000_00FF))
        let id = try #require(scene.editableElements.first?.id)
        var moved = scene
        try moved.translate([id], dx: 30, dy: 30)
        let after = try #require(SceneRenderer.makeImage(moved, scale: 1))
        let sx = CGFloat(after.width) / 100, sy = CGFloat(after.height) / 100
        let vacated = samplePixel(after, px: Int(45 * sx), py: Int(40 * sy))   // original centre
        var painted = 0
        for py in 0..<after.height { for px in 0..<after.width {
            let p = samplePixel(after, px: px, py: py)
            if p.r < 200 || p.g < 200 || p.b < 200 { painted += 1 }
        } }
        #expect(vacated.r > 240 && vacated.g > 240 && vacated.b > 240)   // vacated = background (no residue)
        #expect(painted > 1000)                                          // the element still renders (didn't vanish)
    }
}

// MARK: - Undo guarantees (drag, nudge) + transform round trip

@MainActor
@Suite struct EditorUndoAndRoundTripTests {

    /// A valid EMF carrying one fillable rectangle (device 10…90), so `SceneImporter`
    /// lifts exactly one editable element.
    private func editableEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(1); u32(88)
        i32(0); i32(0); i32(99); i32(99)
        i32(0); i32(0); i32(2117); i32(2117)
        u32(0x464D4520); u32(0x0001_0000); u32(88 + 24 + 20); u32(3)
        u16(1); u16(0); u32(0); u32(0); u32(0)
        i32(1920); i32(1080); i32(508); i32(286)
        u32(43); u32(24); i32(10); i32(10); i32(90); i32(90)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    @Test func aDragCommitsExactlyOneUndoEntryAndUndoRestores() throws {
        var scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        var history = SceneHistory(scene: scene)
        let original = history.scene
        // A committed drag is ONE apply (the live drag used a ghost); one undo entry.
        try history.apply(.applyTransform(ids: [id], CGAffineTransform(translationX: 12, y: -8)))
        #expect(history.undoCount == 1)
        #expect(history.scene != original)
        history.undo()
        #expect(history.scene == original)   // byte-exact restore
        scene = history.scene
    }

    @Test func fiveNudgesCoalesceToOneUndoEntry() throws {
        let scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        var history = SceneHistory(scene: scene)
        let original = history.scene
        for _ in 0..<5 {
            try history.apply(.translate(ids: [id], dx: 1, dy: 0), coalescing: EditorNudge.coalescingKey)
        }
        #expect(history.undoCount == 1)        // one coalesced step
        history.undo()
        #expect(history.scene == original)     // one undo reverses the whole run
        #expect(!history.canUndo)
    }

    @Test func transformRoundTripsThroughSaveAndReimportWithinHalfADeviceUnit() throws {
        let scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        let before = try #require(scene.elements.first { $0.id == id }).boundsDevice

        var edited = scene
        try edited.translate([id], dx: 5, dy: 7)
        let expected = before.offsetBy(dx: 5, dy: 7)

        let exported = try SceneExporter.export(edited, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)
        let moved = try #require(reimported.editableElements.first).boundsDevice

        #expect(abs(moved.minX - expected.minX) < 0.5)
        #expect(abs(moved.minY - expected.minY) < 0.5)
        #expect(abs(moved.width - expected.width) < 0.5)
        #expect(abs(moved.height - expected.height) < 0.5)
    }
}
