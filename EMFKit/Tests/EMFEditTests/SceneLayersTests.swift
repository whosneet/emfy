import CoreGraphics
import EMFParse
import Foundation
import Testing
@testable import EMFEdit

/// Layers and arrange (E3d): the pure arrange maths, every layer command with its
/// undo, and the active-layer insert — all over a from-scratch scene.
struct SceneLayersTests {

    // MARK: - Fixtures

    private static func blankScene() throws -> Scene {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 200, height: 150))
        return try SceneImporter.import(data: data)
    }

    private static func shape(_ id: Int, x: CGFloat) -> Element {
        SceneFactory.makeShape(
            kind: .rect,
            rectDevice: CGRect(x: x, y: 10, width: 20, height: 20),
            style: SceneFactory.defaultShapeStyle,
            id: id
        )
    }

    /// A scene with three named layers — Background, Shapes, Notes — each holding
    /// one shape, Notes hidden and Background locked (the verification scene).
    private static func threeLayerHistory() throws -> SceneHistory {
        var history = SceneHistory(scene: try blankScene())
        // The imported blank has one "Imported" layer; rename it Background (order 0).
        let baseID = try #require(history.scene.layers.first?.id)
        try history.apply(.renameLayer(id: baseID, "Background"))
        try history.apply(.addLayer(name: "Shapes", at: 1))
        try history.apply(.addLayer(name: "Notes", at: 2))
        let ids = history.scene.layers.map(\.id)
        try history.apply(.insertInLayer(element: shape(100, x: 10), at: 0, layer: 0))
        try history.apply(.insertInLayer(element: shape(101, x: 40), at: 0, layer: 1))
        try history.apply(.insertInLayer(element: shape(102, x: 70), at: 0, layer: 2))
        try history.apply(.setLayerLocked(id: ids[0], true))
        try history.apply(.setLayerHidden(id: ids[2], true))
        return history
    }

    // MARK: - Arrange maths (pure helper, edges)

    private static func els(_ ids: [Int]) -> [Element] { ids.map { shape($0, x: CGFloat($0)) } }
    private static func idsOf(_ e: [Element]) -> [Int] { e.map(\.id) }

    @Test func arrangeToFrontMovesSelectedToEnd() {
        let out = SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [2], .toFront)
        #expect(Self.idsOf(out) == [1, 3, 4, 2])
    }

    @Test func arrangeToBackMovesSelectedToStart() {
        let out = SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [3], .toBack)
        #expect(Self.idsOf(out) == [3, 1, 2, 4])
    }

    @Test func arrangeForwardShiftsOneAndKeepsBlock() {
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [2], .forward)) == [1, 3, 2, 4])
        // A contiguous block moves as a unit.
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [2, 3], .forward)) == [1, 4, 2, 3])
    }

    @Test func arrangeBackwardShiftsOne() {
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [3], .backward)) == [1, 3, 2, 4])
    }

    @Test func arrangeIsNoOpAtEdges() {
        // Already front: forward / toFront do nothing.
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [4], .forward)) == [1, 2, 3, 4])
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [4], .toFront)) == [1, 2, 3, 4])
        // Already back: backward / toBack do nothing.
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [1], .backward)) == [1, 2, 3, 4])
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [1], .toBack)) == [1, 2, 3, 4])
        // Front block: forward is a no-op.
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3, 4]), selected: [3, 4], .forward)) == [1, 2, 3, 4])
        // Empty / absent selection: unchanged.
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3]), selected: [], .toFront)) == [1, 2, 3])
        #expect(Self.idsOf(SceneArrange.reorder(Self.els([1, 2, 3]), selected: [99], .toFront)) == [1, 2, 3])
    }

    // MARK: - Default active layer = the top layer

    @Test func defaultActiveLayerIsTop() throws {
        let history = try Self.threeLayerHistory()
        #expect(history.scene.defaultActiveLayerID == history.scene.layers.last?.id)
    }

    // MARK: - Every command + undo

    @Test func addLayerAndUndo() throws {
        var history = SceneHistory(scene: try Self.blankScene())
        let before = history.scene.layers.count
        try history.apply(.addLayer(name: "New", at: before))
        #expect(history.scene.layers.count == before + 1)
        #expect(history.scene.layers.last?.name == "New")
        history.undo()
        #expect(history.scene.layers.count == before)
        history.redo()
        #expect(history.scene.layers.last?.name == "New")
    }

    @Test func deleteLayerTakesItsElementsAndUndoRestores() throws {
        var history = try Self.threeLayerHistory()
        let shapesLayerID = history.scene.layers[1].id
        let elementCount = history.scene.elements.count
        try history.apply(.deleteLayer(id: shapesLayerID))
        #expect(history.scene.layers.count == 2)
        #expect(history.scene.elements.count == elementCount - 1)
        #expect(!history.scene.elements.contains { $0.id == 101 })
        history.undo()
        #expect(history.scene.layers.count == 3)
        #expect(history.scene.elements.contains { $0.id == 101 })
    }

    @Test func deletingOnlyLayerIsRefused() throws {
        var history = SceneHistory(scene: try Self.blankScene())
        let id = try #require(history.scene.layers.first?.id)
        #expect(throws: SceneEditError.cannotDeleteOnlyLayer) {
            try history.apply(.deleteLayer(id: id))
        }
        #expect(history.scene.layers.count == 1)
        #expect(history.undoCount == 0)
    }

    @Test func renameAndUndo() throws {
        var history = SceneHistory(scene: try Self.blankScene())
        let id = try #require(history.scene.layers.first?.id)
        try history.apply(.renameLayer(id: id, "Sketch"))
        #expect(history.scene.layers[0].name == "Sketch")
        history.undo()
        #expect(history.scene.layers[0].name == Scene.defaultLayerName)
    }

    @Test func reorderAndUndo() throws {
        var history = try Self.threeLayerHistory()
        let ids = history.scene.layers.map(\.id)
        try history.apply(.reorderLayers([ids[2], ids[0], ids[1]]))
        #expect(history.scene.layers.map(\.id) == [ids[2], ids[0], ids[1]])
        history.undo()
        #expect(history.scene.layers.map(\.id) == ids)
    }

    @Test func reorderRejectsIncompleteOrder() throws {
        var history = try Self.threeLayerHistory()
        let ids = history.scene.layers.map(\.id)
        #expect(throws: SceneEditError.invalidLayerOrder) {
            try history.apply(.reorderLayers([ids[0], ids[1]]))   // missing one
        }
    }

    @Test func hiddenAndLockedWithUndo() throws {
        var history = SceneHistory(scene: try Self.blankScene())
        let id = try #require(history.scene.layers.first?.id)
        try history.apply(.setLayerHidden(id: id, true))
        try history.apply(.setLayerLocked(id: id, true))
        #expect(history.scene.layers[0].hidden)
        #expect(history.scene.layers[0].locked)
        history.undo()
        #expect(!history.scene.layers[0].locked)
        #expect(history.scene.layers[0].hidden)
        history.undo()
        #expect(!history.scene.layers[0].hidden)
    }

    @Test func moveElementsToLayerAndUndo() throws {
        var history = try Self.threeLayerHistory()
        // Move the Background shape (id 100) up to the Notes layer (order 2).
        try history.apply(.moveElementsToLayer(ids: [100], layer: 2))
        #expect(history.scene.layerOrder(ofElement: 100) == 2)
        #expect(history.scene.layers[0].elements.isEmpty)
        history.undo()
        #expect(history.scene.layerOrder(ofElement: 100) == 0)
    }

    @Test func insertInLayerTargetsTheActiveLayerAndUndoes() throws {
        var history = try Self.threeLayerHistory()
        try history.apply(.insertInLayer(element: Self.shape(200, x: 5), at: 0, layer: 1))
        #expect(history.scene.layerOrder(ofElement: 200) == 1)
        history.undo()
        #expect(!history.scene.elements.contains { $0.id == 200 })
    }

    @Test func insertInLayerRejectsBadIndex() throws {
        var history = try Self.threeLayerHistory()
        #expect(throws: SceneEditError.layerIndexOutOfRange(index: 9)) {
            try history.apply(.insertInLayer(element: Self.shape(201, x: 5), at: 0, layer: 9))
        }
    }

    @Test func arrangeCommandReordersWithinLayerAndUndoes() throws {
        var history = SceneHistory(scene: try Self.blankScene())
        let layer = try #require(history.scene.layers.first?.id)
        _ = layer
        try history.apply(.insertInLayer(element: Self.shape(1, x: 0), at: 0, layer: 0))
        try history.apply(.insertInLayer(element: Self.shape(2, x: 30), at: 1, layer: 0))
        try history.apply(.insertInLayer(element: Self.shape(3, x: 60), at: 2, layer: 0))
        #expect(history.scene.layers[0].elements.map(\.id) == [1, 2, 3])
        try history.apply(.arrange(ids: [1], .toFront))
        #expect(history.scene.layers[0].elements.map(\.id) == [2, 3, 1])
        history.undo()
        #expect(history.scene.layers[0].elements.map(\.id) == [1, 2, 3])
    }
}
