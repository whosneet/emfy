import CoreGraphics
import EMFEdit
import Foundation
import Testing

// X2a: the Recolour view-model (deterministic, no AI). The palette maths are covered in
// EMFEditTests; here we prove the model drives scope, Apply as one grouped undo, and the
// brand-colour gating.

@MainActor
private func makeRecolourFixture() throws -> Data {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 160)))
    func addRect(_ r: CGRect, _ c: SceneColor) {
        let id = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: r, style: SceneStyle(fill: SceneFill(color: c, evenOdd: false), stroke: nil), id: id), at: scene.elements.count)
    }
    addRect(CGRect(x: 40, y: 40, width: 100, height: 100), SceneColor(red: 0.85, green: 0, blue: 0))
    addRect(CGRect(x: 180, y: 40, width: 100, height: 100), SceneColor(red: 0, green: 0.6, blue: 0))
    return try SceneExporter.export(scene, as: .emf).data
}

@MainActor
private func wait(until condition: @escaping () -> Bool) async {
    for _ in 0 ..< 200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite @MainActor struct DrawingRecolourModelTests {

    @Test func greyscaleMapsAndAppliesAsOneUndo() async throws {
        let bytes = try makeRecolourFixture()
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour.emf" })
        let model = DrawingRecolourModel()
        await model.start(session: session, selection: [])
        model.mode = .greyscale
        await wait { !model.mappingRows.isEmpty }

        #expect(model.scopeDescription == "the whole drawing")
        #expect(model.canApply)
        #expect(model.mappingRows.count == 2)

        model.apply()
        #expect(session.isDirty)
        #expect(session.debugSceneMatchesOpened() == false)
        #expect(session.undoManager.canUndo)

        session.undoManager.undo()
        #expect(session.debugSceneMatchesOpened() == true)
    }

    @Test func brandNeedsTwoValidColours() async throws {
        let bytes = try makeRecolourFixture()
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour.emf" })
        let model = DrawingRecolourModel()
        await model.start(session: session, selection: [])
        model.mode = .brand
        model.brandHex = ["#1F3A93", ""]   // only one valid
        await wait { true }
        #expect(model.brandColours.isEmpty)
        #expect(model.canApply == false)

        model.brandHex = ["#1F3A93", "#E69F00"]   // two valid
        await wait { !model.mappingRows.isEmpty }
        #expect(model.brandColours.count == 2)
        #expect(model.canApply)
    }

    @Test func scopeHonoursSelection() async throws {
        let bytes = try makeRecolourFixture()
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour.emf" })
        await session.beginEditing()
        let firstID = try #require(session.allEditableIDs().sorted().first)
        let model = DrawingRecolourModel()
        await model.start(session: session, selection: [firstID])
        model.mode = .greyscale
        await wait { !model.mappingRows.isEmpty }
        #expect(model.scopeDescription == "1 selected element")
    }
}
