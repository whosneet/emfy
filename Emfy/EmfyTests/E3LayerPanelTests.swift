import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3d (app layer): the active-layer resolver, the active-layer insert routing, the
// layer-name sanitiser, the delete-confirmation decision and the Arrange-enabled state.
// All pure logic — scenes are built from the blank-document factory, no window needed.

@Suite struct ActiveLayerResolverTests {

    private func blankScene() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 200, height: 150)))
    }

    private func shape(_ id: Int, x: CGFloat) -> Element {
        SceneFactory.makeShape(kind: .rect, rectDevice: CGRect(x: x, y: 10, width: 20, height: 20),
                               style: SceneFactory.defaultShapeStyle, id: id)
    }

    /// Background (order 0) → Shapes (1) → Notes (2), one shape in each of the first two.
    private func threeLayerScene() throws -> Scene {
        var scene = try blankScene()
        let baseID = scene.layers[0].id
        try scene.renameLayer(baseID, "Background")
        scene.addLayer(name: "Shapes", at: 1)
        scene.addLayer(name: "Notes", at: 2)
        try scene.insert(shape(100, x: 10), at: 0, inLayer: 0)
        try scene.insert(shape(101, x: 40), at: 0, inLayer: 1)
        return scene
    }

    // MARK: - Resolver (nil, stale, single layer)

    @MainActor
    @Test func nilActiveResolvesToDefaultTopLayer() throws {
        let scene = try threeLayerScene()
        let model = EditorModel()
        model.activeLayerID = nil
        // The default active is the TOP layer (last in back-to-front), i.e. Notes.
        #expect(model.resolvedActiveLayerID(in: scene) == scene.layers.last?.id)
    }

    @MainActor
    @Test func staleActiveResolvesToDefault() throws {
        let scene = try threeLayerScene()
        let model = EditorModel()
        model.activeLayerID = 9999   // never a real layer id
        #expect(model.resolvedActiveLayerID(in: scene) == scene.defaultActiveLayerID)
    }

    @MainActor
    @Test func singleLayerResolvesToThatLayer() throws {
        let scene = try blankScene()
        let model = EditorModel()
        let only = try #require(scene.layers.first?.id)
        model.activeLayerID = nil
        #expect(model.resolvedActiveLayerID(in: scene) == only)
        model.activeLayerID = only
        #expect(model.resolvedActiveLayerID(in: scene) == only)
    }

    @MainActor
    @Test func validActiveIsKept() throws {
        let scene = try threeLayerScene()
        let model = EditorModel()
        let shapesID = try #require(scene.layers.first { $0.name == "Shapes" }?.id)
        model.activeLayerID = shapesID
        #expect(model.resolvedActiveLayerID(in: scene) == shapesID)
    }

    // MARK: - Insert into the active layer

    @Test func insertRoutesIntoActiveLayerOrder() throws {
        let scene = try threeLayerScene()
        let shapesOrder = try #require(scene.layerOrder(ofLayer: scene.layers.first { $0.name == "Shapes" }!.id))
        let shapesID = scene.layers[shapesOrder].id
        let command = ActiveLayerInsert.route(.insert(element: shape(200, x: 5), at: 0), activeLayerID: shapesID, in: scene)
        guard case .insertInLayer(_, let at, let layer) = command else { Issue.record("not insertInLayer"); return }
        #expect(layer == shapesOrder)
        #expect(at == scene.layers[shapesOrder].elements.count)   // on top of that layer
    }

    @Test func insertIntoActiveLayerLandsThere() throws {
        let scene = try threeLayerScene()
        let notesOrder = try #require(scene.layerOrder(ofLayer: scene.layers.first { $0.name == "Notes" }!.id))
        let notesID = scene.layers[notesOrder].id
        let command = ActiveLayerInsert.route(.insert(element: shape(300, x: 7), at: 0), activeLayerID: notesID, in: scene)
        var history = SceneHistory(scene: scene)
        try history.apply(command)
        #expect(history.scene.layers[notesOrder].elements.contains { $0.id == 300 })
        #expect(history.scene.layers.filter { $0.name != "Notes" }.allSatisfy { !$0.elements.contains { $0.id == 300 } })
    }

    @Test func staleActiveInsertFallsBackToDefault() throws {
        let scene = try threeLayerScene()
        let command = ActiveLayerInsert.route(.insert(element: shape(301, x: 7), at: 0), activeLayerID: 9999, in: scene)
        var history = SceneHistory(scene: scene)
        try history.apply(command)
        // Default active is the top (Notes) layer.
        let topOrder = history.scene.layers.count - 1
        #expect(history.scene.layers[topOrder].elements.contains { $0.id == 301 })
    }

    @Test func nonInsertCommandPassesThrough() throws {
        let scene = try threeLayerScene()
        let command = ActiveLayerInsert.route(.delete(ids: [100]), activeLayerID: nil, in: scene)
        #expect(command == .delete(ids: [100]))
    }
}

@Suite struct LayerPanelSupportTests {

    // MARK: - Name sanitiser

    @Test func sanitiserTrimsAndKeeps() {
        #expect(LayerName.sanitised("  Hello  ") == "Hello")
        #expect(LayerName.sanitised("Background") == "Background")
    }

    @Test func sanitiserStripsControlCharactersAndNewlines() {
        #expect(LayerName.sanitised("Line1\nLine2\t!") == "Line1Line2!")
    }

    @Test func sanitiserRejectsEmptyAndWhitespaceOnly() {
        #expect(LayerName.sanitised("") == nil)
        #expect(LayerName.sanitised("   \n\t ") == nil)
    }

    @Test func sanitiserCapsAt256() {
        let long = String(repeating: "x", count: 500)
        #expect(LayerName.sanitised(long)?.count == 256)
    }

    @Test func nextDefaultPicksLowestFreeNumber() {
        #expect(LayerName.nextDefault(existing: ["Layer 1"]) == "Layer 2")
        #expect(LayerName.nextDefault(existing: ["Background", "Notes"]) == "Layer 1")
        #expect(LayerName.nextDefault(existing: ["Layer 1", "Layer 2", "Layer 4"]) == "Layer 3")
    }

    // MARK: - Delete confirmation decision

    @Test func emptyLayerDeletesWithoutConfirmation() {
        #expect(!LayerDeletion.needsConfirmation(elementCount: 0))
    }

    @Test func nonEmptyLayerNeedsConfirmation() {
        #expect(LayerDeletion.needsConfirmation(elementCount: 3))
        #expect(LayerDeletion.confirmationMessage(name: "Shapes", elementCount: 3) == "Delete “Shapes” and its 3 items?")
        #expect(LayerDeletion.confirmationMessage(name: "Notes", elementCount: 1) == "Delete “Notes” and its 1 item?")
    }

    // MARK: - Arrange enabled state

    @Test func arrangeEnabledOnlyWhenEditingWithSelection() {
        #expect(!ArrangeAvailability.isEnabled(editing: false, selectionCount: 3))
        #expect(!ArrangeAvailability.isEnabled(editing: true, selectionCount: 0))
        #expect(ArrangeAvailability.isEnabled(editing: true, selectionCount: 1))
    }
}
