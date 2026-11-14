import CoreGraphics
import EMFEdit
import Foundation
import Testing

// C5g unit tests (audit finding A1) for the pure editor accessibility model: the
// element list (count, reading order, labels, locked handling), each custom action's
// scene command and its single undo step, and the keyboard selection-cycling order. All
// pure — scenes are built by hand, so no canvas, window or assistive technology is
// needed.

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

private func rectElement(id: Int, rect: CGRect, fill: SceneColor? = SceneColor(red: 0.85, green: 0.1, blue: 0.1), locked: Bool = false, hidden: Bool = false) -> Element {
    let segs: [ScenePath.Segment] = [
        .move(CGPoint(x: rect.minX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.maxY)),
        .line(CGPoint(x: rect.minX, y: rect.maxY)),
        .close,
    ]
    var style = SceneStyle()
    if let fill { style.fill = SceneFill(color: fill, evenOdd: false) }
    return Element(
        id: id, kind: .rect, geometryDevice: ScenePath(segments: segs),
        transform: .identity, style: style,
        provenance: Provenance(sourceRecordIndices: [id]), locked: locked, hidden: hidden
    )
}

private func textElement(id: Int, rect: CGRect, string: String) -> Element {
    let text = SceneText(
        string: string, fontFamily: "Helvetica", logicalHeight: -16,
        color: SceneColor(red: 0, green: 0, blue: 0),
        referenceLogical: CGPoint(x: rect.minX, y: rect.midY), alignRawValue: 0)
    // Give the run real device geometry (a rect) so selectionBoundsDevice is the box.
    let segs: [ScenePath.Segment] = [
        .move(CGPoint(x: rect.minX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.minY)),
        .line(CGPoint(x: rect.maxX, y: rect.maxY)),
        .line(CGPoint(x: rect.minX, y: rect.maxY)),
        .close,
    ]
    return Element(
        id: id, kind: .text, geometryDevice: ScenePath(segments: segs),
        transform: .identity, text: text,
        provenance: Provenance(sourceRecordIndices: [id])
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

// MARK: - Element list

@Suite struct EditorAccessibilityElementTests {

    @Test func listsOnlyEditableVisibleElements() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
            rectElement(id: 2, rect: CGRect(x: 40, y: 40, width: 20, height: 20), hidden: true),
            passthroughElement(id: 3, rect: CGRect(x: 60, y: 60, width: 20, height: 20)),
        ])
        let descriptors = EditorAccessibility.descriptors(in: scene, selection: EditorSelection())
        #expect(descriptors.map(\.id) == [1])   // hidden and passthrough are omitted
    }

    @Test func lockedElementsAreAnnouncedWithoutActions() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20), locked: true)])
        let descriptor = EditorAccessibility.descriptors(in: scene, selection: EditorSelection([1])).first
        #expect(descriptor?.isLocked == true)
        #expect(descriptor?.actions.isEmpty == true)   // no actions on a locked element
    }

    @Test func elementsOnALockedLayerAreLocked() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20))], layerLocked: true)
        let descriptor = EditorAccessibility.descriptors(in: scene, selection: EditorSelection()).first
        #expect(descriptor?.isLocked == true)
        #expect(descriptor?.actions.isEmpty == true)
    }

    @Test func elementsOnAHiddenLayerAreOmitted() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20))], layerHidden: true)
        #expect(EditorAccessibility.descriptors(in: scene, selection: EditorSelection()).isEmpty)
    }

    @Test func readingOrderIsTopToBottomThenLeftToRight() {
        // Two elements on the top row (y≈5), one lower (y≈60). Reading order: top-left,
        // top-right, then the lower one — regardless of insertion order.
        let scene = makeScene([
            rectElement(id: 3, rect: CGRect(x: 10, y: 60, width: 10, height: 10)),
            rectElement(id: 2, rect: CGRect(x: 60, y: 5, width: 10, height: 10)),
            rectElement(id: 1, rect: CGRect(x: 10, y: 5, width: 10, height: 10)),
        ])
        let order = EditorAccessibility.descriptors(in: scene, selection: EditorSelection()).map(\.id)
        #expect(order == [1, 2, 3])
    }

    @Test func labelsCarryKindAndContent() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            textElement(id: 2, rect: CGRect(x: 0, y: 20, width: 40, height: 10), string: "Quarterly Results"),
        ])
        let descriptors = EditorAccessibility.descriptors(in: scene, selection: EditorSelection())
        let rect = try! #require(descriptors.first { $0.id == 1 })
        let text = try! #require(descriptors.first { $0.id == 2 })
        #expect(rect.label == "Rectangle, red fill")
        #expect(text.label == "Text, Quarterly Results")
        #expect(text.isText)
        #expect(text.userInputLabels.contains("Quarterly Results"))
    }

    @Test func selectedElementReportsSelectionAndEditingActions() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 20, height: 20))])
        let unselected = EditorAccessibility.descriptors(in: scene, selection: EditorSelection()).first
        #expect(unselected?.isSelected == false)
        #expect(unselected?.actions == [.select])

        let selected = EditorAccessibility.descriptors(in: scene, selection: EditorSelection([1])).first
        #expect(selected?.isSelected == true)
        let actions = selected?.actions ?? []
        #expect(actions.contains(.delete))
        #expect(actions.contains(.moveLeft))
        #expect(actions.contains(.moveUpLarge))
        #expect(actions.contains(.makeBigger))
        #expect(actions.contains(.bringToFront))
        #expect(!actions.contains(.select))      // already selected
        #expect(!actions.contains(.editText))    // not a text element
    }

    @Test func selectedTextOffersEditText() {
        let scene = makeScene([textElement(id: 1, rect: CGRect(x: 0, y: 0, width: 40, height: 10), string: "Hi")])
        let selected = EditorAccessibility.descriptors(in: scene, selection: EditorSelection([1])).first
        #expect(selected?.actions.contains(.editText) == true)
    }

    @Test func colourNamesPickTheNearestBasicColour() {
        #expect(EditorAccessibility.colorName(SceneColor(red: 1, green: 0, blue: 0)) == "red")
        #expect(EditorAccessibility.colorName(SceneColor(red: 0, green: 0, blue: 0)) == "black")
        #expect(EditorAccessibility.colorName(SceneColor(red: 1, green: 1, blue: 1)) == "white")
        #expect(EditorAccessibility.colorName(SceneColor(red: 0.1, green: 0.3, blue: 0.9)) == "blue")
    }
}

// MARK: - Action → command → one undo step

@Suite struct EditorAccessibilityActionTests {

    /// A valid EMF carrying one fillable rectangle (device 10…90), so `SceneImporter`
    /// lifts exactly one editable element that re-synthesises when edited.
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

    @Test func moveActionsAreTranslatesByTheStep() {
        let scene = makeScene([rectElement(id: 7, rect: CGRect(x: 10, y: 10, width: 20, height: 20))])
        // Page is 100×100 → small step 1, large step 10.
        #expect(EditorAccessibility.command(for: .moveRight, elementID: 7, in: scene) == .translate(ids: [7], dx: 1, dy: 0))
        #expect(EditorAccessibility.command(for: .moveLeft, elementID: 7, in: scene) == .translate(ids: [7], dx: -1, dy: 0))
        #expect(EditorAccessibility.command(for: .moveUp, elementID: 7, in: scene) == .translate(ids: [7], dx: 0, dy: -1))
        #expect(EditorAccessibility.command(for: .moveDown, elementID: 7, in: scene) == .translate(ids: [7], dx: 0, dy: 1))
        #expect(EditorAccessibility.command(for: .moveUpLarge, elementID: 7, in: scene) == .translate(ids: [7], dx: 0, dy: -10))
        #expect(EditorAccessibility.command(for: .moveRightLarge, elementID: 7, in: scene) == .translate(ids: [7], dx: 10, dy: 0))
    }

    @Test func arrangeActionsAreArrangeCommands() {
        let scene = makeScene([rectElement(id: 7, rect: CGRect(x: 10, y: 10, width: 20, height: 20))])
        #expect(EditorAccessibility.command(for: .bringToFront, elementID: 7, in: scene) == .arrange(ids: [7], .toFront))
        #expect(EditorAccessibility.command(for: .sendToBack, elementID: 7, in: scene) == .arrange(ids: [7], .toBack))
    }

    @Test func resizeActionsScaleAboutTheCentre() {
        let scene = makeScene([rectElement(id: 7, rect: CGRect(x: 20, y: 20, width: 40, height: 40))])
        guard case .applyTransform(let ids, let transform) = EditorAccessibility.command(for: .makeBigger, elementID: 7, in: scene) else {
            Issue.record("expected applyTransform"); return
        }
        #expect(ids == [7])
        // The box centre (40,40) is a fixed point of a centre-anchored scale.
        let centre = CGPoint(x: 40, y: 40).applying(transform)
        #expect(abs(centre.x - 40) < 1e-6 && abs(centre.y - 40) < 1e-6)
        // A corner moves out by the grow factor.
        let corner = CGPoint(x: 20, y: 20).applying(transform)
        #expect(corner.x < 20 && corner.y < 20)
    }

    @Test func selectEditAndDeleteHaveNoDirectCommand() {
        let scene = makeScene([textElement(id: 7, rect: CGRect(x: 0, y: 0, width: 40, height: 10), string: "Hi")])
        #expect(EditorAccessibility.command(for: .select, elementID: 7, in: scene) == nil)
        #expect(EditorAccessibility.command(for: .editText, elementID: 7, in: scene) == nil)
        #expect(EditorAccessibility.command(for: .delete, elementID: 7, in: scene) == nil)
    }

    @Test func aMoveActionCommitsExactlyOneUndoStep() throws {
        let scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        var history = SceneHistory(scene: scene)
        let original = history.scene
        let command = try #require(EditorAccessibility.command(for: .moveRight, elementID: id, in: scene))
        try history.apply(command)
        #expect(history.undoCount == 1)
        history.undo()
        #expect(history.scene == original)   // byte-exact restore
    }

    @Test func aResizeActionCommitsExactlyOneUndoStep() throws {
        let scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        var history = SceneHistory(scene: scene)
        let original = history.scene
        let command = try #require(EditorAccessibility.command(for: .makeBigger, elementID: id, in: scene))
        try history.apply(command)
        #expect(history.undoCount == 1)
        history.undo()
        #expect(history.scene == original)
    }

    @Test func deleteViaTheDeletePathIsOneUndoStep() throws {
        // Delete routes through `.delete(ids:)` (DocumentSession.deleteSelection), not
        // `command`, but it is still exactly one undo step through SceneHistory.
        let scene = try SceneImporter.import(data: editableEMF())
        let id = try #require(scene.editableElements.first?.id)
        var history = SceneHistory(scene: scene)
        let original = history.scene
        try history.apply(.delete(ids: [id]))
        #expect(history.undoCount == 1)
        history.undo()
        #expect(history.scene == original)
    }
}

// MARK: - Selection cycling

@Suite struct EditorAccessibilitySelectionCyclingTests {

    private func threeInARow() -> Scene {
        makeScene([
            rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 10, height: 10)),
            rectElement(id: 2, rect: CGRect(x: 40, y: 10, width: 10, height: 10)),
            rectElement(id: 3, rect: CGRect(x: 70, y: 10, width: 10, height: 10)),
        ])
    }

    @Test func forwardFromNothingSelectsTheFirst() {
        #expect(EditorAccessibility.cycleSelection(from: [], forward: true, in: threeInARow()) == 1)
    }

    @Test func backwardFromNothingSelectsTheLast() {
        #expect(EditorAccessibility.cycleSelection(from: [], forward: false, in: threeInARow()) == 3)
    }

    @Test func forwardAdvancesInReadingOrderAndWraps() {
        let scene = threeInARow()
        #expect(EditorAccessibility.cycleSelection(from: [1], forward: true, in: scene) == 2)
        #expect(EditorAccessibility.cycleSelection(from: [2], forward: true, in: scene) == 3)
        #expect(EditorAccessibility.cycleSelection(from: [3], forward: true, in: scene) == 1)   // wrap
    }

    @Test func backwardStepsAndWraps() {
        let scene = threeInARow()
        #expect(EditorAccessibility.cycleSelection(from: [2], forward: false, in: scene) == 1)
        #expect(EditorAccessibility.cycleSelection(from: [1], forward: false, in: scene) == 3)   // wrap
    }

    @Test func cyclingSkipsLockedElements() {
        let scene = makeScene([
            rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 10, height: 10)),
            rectElement(id: 2, rect: CGRect(x: 40, y: 10, width: 10, height: 10), locked: true),
            rectElement(id: 3, rect: CGRect(x: 70, y: 10, width: 10, height: 10)),
        ])
        #expect(EditorAccessibility.cycleSelection(from: [1], forward: true, in: scene) == 3)   // 2 is locked
    }

    @Test func noSelectableElementsYieldsNil() {
        let scene = makeScene([rectElement(id: 1, rect: CGRect(x: 10, y: 10, width: 10, height: 10), locked: true)])
        #expect(EditorAccessibility.cycleSelection(from: [], forward: true, in: scene) == nil)
    }
}
