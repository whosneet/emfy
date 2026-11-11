import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3a: the shape-tool geometry, the shape insertion (one undo step; unique ids), and
// the New Drawing naming/dedup. Pure-logic tests compiled into the EmfyTests bundle.

@Suite struct ShapeToolGeometryTests {

    @Test func shiftMakesASquare() {
        // A 120 × 40 drag with Shift becomes a square (equal magnitudes).
        let rect = ShapeToolGeometry.sweptRect(kind: .rect, start: CGPoint(x: 0, y: 0),
                                               current: CGPoint(x: 120, y: 40), shift: true, fromCentre: false)
        #expect(abs(rect.size.width) == abs(rect.size.height))
        #expect(abs(rect.size.width) == 120)
    }

    @Test func shiftKeepsEachSign() {
        // Up-and-left drag with Shift: still a square, signs preserved.
        let rect = ShapeToolGeometry.sweptRect(kind: .rect, start: CGPoint(x: 200, y: 200),
                                               current: CGPoint(x: 160, y: 80), shift: true, fromCentre: false)
        #expect(rect.size.width < 0)
        #expect(rect.size.height < 0)
        #expect(abs(rect.size.width) == abs(rect.size.height))
    }

    @Test func optionDrawsFromCentre() {
        // From the centre: start is the midpoint of the resulting box.
        let rect = ShapeToolGeometry.sweptRect(kind: .ellipse, start: CGPoint(x: 100, y: 100),
                                               current: CGPoint(x: 160, y: 140), shift: false, fromCentre: true)
        #expect(rect.standardized.midX == 100)
        #expect(rect.standardized.midY == 100)
        #expect(rect.standardized.width == 120)
        #expect(rect.standardized.height == 80)
    }

    @Test func lineSnapsTo45Degrees() {
        // A near-horizontal drag with Shift snaps to 0°; a near-diagonal to 45°.
        let flat = ShapeToolGeometry.sweptRect(kind: .line, start: .zero,
                                               current: CGPoint(x: 100, y: 12), shift: true, fromCentre: false)
        #expect(abs(flat.size.height) < 0.001)
        #expect(flat.size.width > 0)

        let diag = ShapeToolGeometry.sweptRect(kind: .line, start: .zero,
                                               current: CGPoint(x: 100, y: 90), shift: true, fromCentre: false)
        #expect(abs(diag.size.width - diag.size.height) < 0.001)   // 45°
    }

    @Test func defaultRectIsCentredAndSized() {
        let rect = ShapeToolGeometry.defaultRect(centreDevice: CGPoint(x: 50, y: 60), sideDevice: 100)
        #expect(rect == CGRect(x: 0, y: 10, width: 100, height: 100))
    }

    @Test func clickVsDragThreshold() {
        // A tiny movement at 1× is a click; a long one is a drag.
        #expect(!ShapeToolGeometry.isDrag(start: .zero, current: CGPoint(x: 2, y: 1), magnification: 1))
        #expect(ShapeToolGeometry.isDrag(start: .zero, current: CGPoint(x: 40, y: 0), magnification: 1))
    }

    @Test func pointsToDeviceScalesByDocumentResolution() {
        // 1 device unit per point → 100 pt = 100 device units.
        #expect(ShapeToolGeometry.pointsToDevice(100, deviceUnitsPerPoint: 1) == 100)
        // At 96 DPI (1.333 device units per point) a 72 pt length is 96 device units.
        #expect(abs(ShapeToolGeometry.pointsToDevice(72, deviceUnitsPerPoint: 96.0 / 72) - 96) < 0.001)
    }
}

@Suite struct ShapeInsertionTests {

    private func blankScene() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    @Test func insertIsOneUndoStepAndUndoRemovesTheShape() throws {
        let scene = try blankScene()
        var history = SceneHistory(scene: scene)
        let insertion = ShapeToolInsertion.command(kind: .rect, rectDevice: CGRect(x: 100, y: 100, width: 200, height: 150), in: scene)
        try history.apply(insertion.command)
        #expect(history.undoCount == 1)
        #expect(history.scene.editableElements.count == 1)
        #expect(history.scene.elements.contains { $0.id == insertion.id })

        history.undo()
        #expect(history.scene.editableElements.isEmpty)
        #expect(!history.scene.elements.contains { $0.id == insertion.id })
    }

    @Test func newElementsGetUniqueIds() throws {
        var scene = try blankScene()
        var ids: [Int] = []
        for kind in [ShapeToolKind.rect, .ellipse, .triangle, .line] {
            let insertion = ShapeToolInsertion.command(kind: kind, rectDevice: CGRect(x: 0, y: 0, width: 50, height: 50), in: scene)
            ids.append(insertion.id)
            // Insert so the next command sees the updated scene and picks the next id.
            if case .insert(let element, let at) = insertion.command {
                scene.insert(element, at: at)
            }
        }
        #expect(Set(ids).count == ids.count)
        #expect(ids == [0, 1, 2, 3])
    }

    @Test func closedShapesFillAndLinesStroke() throws {
        let scene = try blankScene()
        let rect = ShapeToolInsertion.command(kind: .rect, rectDevice: CGRect(x: 0, y: 0, width: 50, height: 50), in: scene)
        guard case .insert(let rectElement, _) = rect.command else { Issue.record("not an insert"); return }
        #expect(rectElement.style.fill != nil)
        #expect(rectElement.style.stroke == nil)

        let line = ShapeToolInsertion.command(kind: .line, rectDevice: CGRect(x: 0, y: 0, width: 50, height: 50), in: scene)
        guard case .insert(let lineElement, _) = line.command else { Issue.record("not an insert"); return }
        #expect(lineElement.style.stroke != nil)
        #expect(lineElement.style.fill == nil)
    }
}

@Suite struct NewDrawingNamingTests {

    @Test func firstDrawingUsesTheBaseName() {
        #expect(NewDrawing.nextName(existingDisplayNames: []) == "Untitled Drawing")
        #expect(NewDrawing.nextName(existingDisplayNames: ["house.emf", "star.wmf"]) == "Untitled Drawing")
    }

    @Test func secondDrawingDeduplicates() {
        #expect(NewDrawing.nextName(existingDisplayNames: ["Untitled Drawing.emf"]) == "Untitled Drawing 2")
        #expect(NewDrawing.nextName(existingDisplayNames: ["Untitled Drawing.emf", "Untitled Drawing 2.emf"]) == "Untitled Drawing 3")
    }

    @Test func dedupSkipsGaps() {
        // "Untitled Drawing 2" taken but not 3: the next is 3, not 4.
        #expect(NewDrawing.nextName(existingDisplayNames: ["Untitled Drawing.emf", "Untitled Drawing 2.emf", "Untitled Drawing 4.emf"]) == "Untitled Drawing 3")
    }

    @Test func presetSizesAndDefault() {
        #expect(NewDrawingPreset.default == .a4Landscape)
        #expect(NewDrawingPreset.a4Landscape.pageSizeMillimetres == CGSize(width: 297, height: 210))
        #expect(NewDrawingPreset.widescreen16x9.pageSizeMillimetres == CGSize(width: 254, height: 142.875))
    }
}
