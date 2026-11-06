import CoreGraphics
import Foundation
import Testing
@testable import EMFEdit

/// E1b1 mutation primitives: pure value edits that validate up front, reject
/// locked/passthrough elements, and flag provenance edited.
struct SceneMutationTests {

    private func house() throws -> Scene {
        let url = EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")
        return try SceneImporter.import(data: try Data(contentsOf: url))
    }

    private func textScene() throws -> Scene {
        let url = EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-text.emf")
        return try SceneImporter.import(data: try Data(contentsOf: url))
    }

    @Test func translateMovesBoundsAndFlagsEdited() throws {
        var scene = try house()
        let id = try #require(scene.editableElements.first?.id)
        let before = try #require(scene.element(id: id)).boundsDevice
        try scene.translate([id], dx: 10, dy: 5)
        let after = try #require(scene.element(id: id))
        #expect(abs(after.boundsDevice.minX - (before.minX + 10)) < 0.001)
        #expect(abs(after.boundsDevice.minY - (before.minY + 5)) < 0.001)
        #expect(after.provenance.edited)
    }

    @Test func applyTransformScalesGeometry() throws {
        var scene = try house()
        let id = try #require(scene.editableElements.first?.id)
        let before = try #require(scene.element(id: id)).boundsDevice
        try scene.applyTransform([id], CGAffineTransform(scaleX: 2, y: 2))
        let after = try #require(scene.element(id: id)).boundsDevice
        #expect(abs(after.width - before.width * 2) < 0.01)
    }

    @Test func deleteRemovesElement() throws {
        var scene = try house()
        let countBefore = scene.editableElements.count
        let id = try #require(scene.editableElements.first?.id)
        try scene.delete([id])
        #expect(scene.editableElements.count == countBefore - 1)
        #expect(scene.element(id: id) == nil)
    }

    @Test func setFillChangesColour() throws {
        var scene = try house()
        let id = try #require(scene.editableElements.first { $0.style.fill != nil }?.id)
        let newColor = SceneColor(red: 0.1, green: 0.2, blue: 0.3)
        try scene.setFill([id], SceneFill(color: newColor, evenOdd: false))
        let element = try #require(scene.element(id: id))
        #expect(element.style.fill?.color == newColor)
        #expect(element.provenance.edited)
    }

    @Test func setStrokeAndOpacity() throws {
        var scene = try house()
        let id = try #require(scene.editableElements.first?.id)
        let stroke = SceneStroke(color: SceneColor(red: 0, green: 0, blue: 0), isCosmetic: false, width: 3, dash: .solid, cap: .round, join: .round, miterLimit: 10)
        try scene.setStroke([id], stroke)
        try scene.setOpacity([id], 0.5)
        let element = try #require(scene.element(id: id))
        #expect(element.style.stroke?.width == 3)
        #expect(element.style.opacity == 0.5)
    }

    @Test func setTextAndFont() throws {
        var scene = try textScene()
        let id = try #require(scene.editableElements.first { $0.kind == .text }?.id)
        try scene.setText(id, "Changed text")
        try scene.setFont(id, family: "Helvetica", size: 48, bold: true, italic: false)
        let text = try #require(scene.element(id: id)?.text)
        #expect(text.string == "Changed text")
        #expect(text.requestedFamily == "Helvetica")
        #expect(text.logicalHeight == -48)
        #expect(text.bold)
    }

    @Test func setTextDropsStaleAdvances() throws {
        // A GDI text run that carried captured intercharacter advances must drop
        // them on setText — reusing advances sized for the old string mis-spaces the
        // new run ([MS-EMF] §2.2.5).
        let base = try textScene()
        guard let id = base.editableElements.first(where: { $0.kind == .text && !($0.text?.advancesLogical.isEmpty ?? true) })?.id else { return }
        var scene = base
        try scene.setText(id, "W")
        #expect(scene.element(id: id)?.text?.advancesLogical.isEmpty == true, "setText did not drop the stale advances")
    }

    @Test func setTextDropsStaleLayoutExtentForLongerString() throws {
        // An EMF+ run with a real layout extent: a LONGER replacement collapses the
        // extent to a point origin (a stale narrow rect would clip/mis-align the
        // longer run, [MS-EMFPLUS] §2.3.4.14); a shorter one keeps it.
        let base = try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("handmade-emfplus-text.emf")))
        guard let id = base.editableElements.first(where: { $0.kind == .text })?.id else { return }
        var seeded = base
        for li in seeded.layers.indices {
            for ei in seeded.layers[li].elements.indices where seeded.layers[li].elements[ei].id == id {
                seeded.layers[li].elements[ei].text?.string = "Hi"
                seeded.layers[li].elements[ei].text?.layoutReference = CGRect(x: 0, y: 0, width: 40, height: 20)
                seeded.layers[li].elements[ei].text?.advancesLogical = [3, 3]
            }
        }
        var longer = seeded
        try longer.setText(id, "Hello world, a much longer run")
        #expect(longer.element(id: id)?.text?.layoutReference.isNull == true, "longer setText did not collapse the stale extent")
        #expect(longer.element(id: id)?.text?.advancesLogical.isEmpty == true, "longer setText did not drop advances")
        var shorter = seeded
        try shorter.setText(id, "H")
        #expect(shorter.element(id: id)?.text?.layoutReference.isNull == false, "shorter setText wrongly collapsed the extent")
    }

    @Test func setTextOnNonTextThrows() throws {
        var scene = try house()
        let id = try #require(scene.editableElements.first { $0.kind != .text }?.id)
        #expect(throws: SceneEditError.notTextElement(id: id)) {
            try scene.setText(id, "nope")
        }
    }

    @Test func lockedAndPassthroughRejectMutation() throws {
        var scene = try house()
        let passthroughID = try #require(scene.elements.first { $0.kind == .passthrough }?.id)
        #expect(throws: SceneEditError.elementLocked(id: passthroughID)) {
            try scene.translate([passthroughID], dx: 1, dy: 1)
        }
        #expect(throws: SceneEditError.elementLocked(id: passthroughID)) {
            try scene.delete([passthroughID])
        }
    }

    @Test func missingIDThrowsAndLeavesSceneUntouched() throws {
        var scene = try house()
        let before = scene
        let goodID = try #require(scene.editableElements.first?.id)
        let missing = 999_999
        #expect(throws: SceneEditError.elementNotFound(id: missing)) {
            try scene.translate([goodID, missing], dx: 10, dy: 10)
        }
        // Validation is up front: nothing moved.
        #expect(scene == before)
    }

    @Test func insertAddsElementOnTop() throws {
        var scene = try house()
        let countBefore = scene.elements.count
        let rect = Element(
            id: 10_000, kind: .rect,
            geometryDevice: ScenePath(CGPath(rect: CGRect(x: 10, y: 10, width: 40, height: 40), transform: nil)),
            transform: .identity,
            style: SceneStyle(fill: SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false)),
            provenance: Provenance(sourceRecordIndices: [])
        )
        scene.insert(rect, at: scene.layers[0].elements.count)
        #expect(scene.elements.count == countBefore + 1)
        #expect(scene.elements.last?.id == 10_000)
    }
}
