import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3b: the pen tool's commit decision, style persistence, the iPad draw-mode routing and
// the pure Pencil decision helpers. Pure-logic tests in the EmfyTests bundle.

@Suite struct PenToolTests {

    private func blankScene() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    /// A deterministic wavy open stroke.
    private func wavyStroke() -> [CGPoint] {
        (0 ... 50).map { CGPoint(x: CGFloat($0) * 8, y: 300 + sin(CGFloat($0) * 0.4) * 60) }
    }

    /// A closed, round stroke that the recogniser snaps to an ellipse.
    private func roundStroke() -> [CGPoint] {
        var pts = (0 ... 72).map { i -> CGPoint in
            let a = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: 250 + cos(a) * 120, y: 250 + sin(a) * 120)
        }
        pts.append(pts[0])
        return pts
    }

    // MARK: - One stroke = one insert, one undo entry

    @Test func noHoldCommitsASmoothedCurveStroke() throws {
        let scene = try blankScene()
        let result = try #require(PenCommit.command(
            rawDevicePoints: wavyStroke(), held: false, minSpacing: 1, rdpTolerance: 1.5,
            pen: .default, in: scene))
        guard case .insert(let element, _) = result.command else { Issue.record("not an insert"); return }
        #expect(element.kind == .path)          // an open stroked path, not a shape
        #expect(element.style.stroke != nil)
        #expect(element.style.fill == nil)
    }

    @Test func holdSnapsToAShape() throws {
        let scene = try blankScene()
        let result = try #require(PenCommit.command(
            rawDevicePoints: roundStroke(), held: true, minSpacing: 1, rdpTolerance: 3,
            pen: .default, in: scene))
        guard case .insert(let element, _) = result.command else { Issue.record("not an insert"); return }
        #expect(element.kind == .ellipse)       // snapped to the perfect shape
        #expect(element.style.stroke != nil)    // the PEN's stroke
        #expect(element.style.fill == nil)      // no fill (design call 4)
    }

    @Test func holdWithNoMatchStillCommitsACurve() throws {
        let scene = try blankScene()
        // A held wavy OPEN stroke doesn't match any shape, so it stays a curve.
        let result = try #require(PenCommit.command(
            rawDevicePoints: wavyStroke(), held: true, minSpacing: 1, rdpTolerance: 1.5,
            pen: .default, in: scene))
        guard case .insert(let element, _) = result.command else { Issue.record("not an insert"); return }
        #expect(element.kind == .path)
    }

    @Test func strokeIsOneUndoStep() throws {
        let scene = try blankScene()
        var history = SceneHistory(scene: scene)
        let result = try #require(PenCommit.command(
            rawDevicePoints: wavyStroke(), held: false, minSpacing: 1, rdpTolerance: 1.5,
            pen: .default, in: scene))
        try history.apply(result.command)
        #expect(history.undoCount == 1)
        #expect(history.scene.editableElements.count == 1)
        history.undo()
        #expect(history.scene.editableElements.isEmpty)
    }

    @Test func strokeGoesToTopOfZOrder() throws {
        var scene = try blankScene()
        // Insert a shape first, then a stroke: the stroke must sit on top (last in layer 0).
        let shape = ShapeToolInsertion.command(kind: .rect, rectDevice: CGRect(x: 0, y: 0, width: 50, height: 50), in: scene)
        if case .insert(let e, let at) = shape.command { scene.insert(e, at: at) }
        let stroke = try #require(PenCommit.command(
            rawDevicePoints: wavyStroke(), held: false, minSpacing: 1, rdpTolerance: 1.5,
            pen: .default, in: scene))
        if case .insert(_, let at) = stroke.command { #expect(at == scene.layers[0].elements.count) }
    }

    // MARK: - Style persistence / resolution

    @Test func penStyleDefaultsToBlackTwoPoint() {
        #expect(PenStyle.default.color == PenPalette.black)
        #expect(PenStyle.default.widthPoints == 2)
    }

    @Test func penWidthConvertsThroughDocumentResolution() throws {
        let scene = try blankScene()   // 96 DPI → 1.333 device units / pt
        let style = PenToolInsertion.strokeStyle(PenStyle(color: PenPalette.red, widthPoints: 4), in: scene)
        #expect(style.stroke?.color == PenPalette.red)
        let expected = Double(4 * scene.deviceUnitsPerPoint)
        #expect(abs((style.stroke?.width ?? 0) - expected) < 0.001)
    }

    @Test func paletteOffersSixColoursAndThreeWidths() {
        #expect(PenPalette.colors.count == 6)
        #expect(PenPalette.widths == [1, 2, 4])
    }

    // MARK: - Draw-mode routing (iPad)

    @Test func pencilAlwaysDrawsThePen() {
        // Pencil, nothing armed → pen (Freeform convention).
        #expect(PenDrawMode.resolve(isPencil: true, armedPen: false, armedShape: false) == .pen)
        // A shape tool armed → the Pencil draws that shape.
        #expect(PenDrawMode.resolve(isPencil: true, armedPen: false, armedShape: true) == .shape)
    }

    @Test func fingerSelectsUnlessPenOrShapeArmed() {
        #expect(PenDrawMode.resolve(isPencil: false, armedPen: false, armedShape: false) == .select)
        #expect(PenDrawMode.resolve(isPencil: false, armedPen: true, armedShape: false) == .pen)
        #expect(PenDrawMode.resolve(isPencil: false, armedPen: false, armedShape: true) == .shape)
    }

    // MARK: - Pencil decision helpers

    @Test func doubleTapRespectsPreference() {
        #expect(PencilSupport.doubleTapAction(for: .ignore) == .none)
        #expect(PencilSupport.doubleTapAction(for: .showPalette) == .showPalette)
        #expect(PencilSupport.doubleTapAction(for: .switchTool) == .togglePenSelect)
        #expect(PencilSupport.doubleTapAction(for: .systemDefault) == .togglePenSelect)
    }

    @Test func squeezeShowsThePalette() {
        #expect(PencilSupport.squeezeAction() == .showPalette)
    }

    @Test func hoverRingHasAFloor() {
        #expect(PencilSupport.hoverRingDiameter(widthDevice: 2) == 8)
        #expect(PencilSupport.hoverRingDiameter(widthDevice: 20) == 20)
    }
}
