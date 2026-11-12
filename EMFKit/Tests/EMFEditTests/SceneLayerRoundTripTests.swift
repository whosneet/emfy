import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Layer persistence (E3d): a scene with several named layers — hidden, locked,
/// custom names — saves to EMF/EMZ and re-imports with an identical layer
/// structure, and the saved bytes render identically with the markers ignored.
struct SceneLayerRoundTripTests {

    private static func blankScene() throws -> Scene {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 200, height: 150))
        return try SceneImporter.import(data: data)
    }

    private static func shape(_ id: Int, x: CGFloat, _ kind: ElementKind = .rect) -> Element {
        SceneFactory.makeShape(
            kind: kind,
            rectDevice: CGRect(x: x, y: 20, width: 30, height: 30),
            style: SceneFactory.defaultShapeStyle,
            id: id
        )
    }

    /// Background (locked, one rect) / Shapes (one ellipse) / Notes (hidden, one
    /// triangle) — the verification scene.
    private static func threeLayerScene() throws -> Scene {
        var history = SceneHistory(scene: try blankScene())
        let baseID = try #require(history.scene.layers.first?.id)
        try history.apply(.renameLayer(id: baseID, "Background"))
        try history.apply(.addLayer(name: "Shapes", at: 1))
        try history.apply(.addLayer(name: "Notes", at: 2))
        try history.apply(.insertInLayer(element: shape(100, x: 10, .rect), at: 0, layer: 0))
        try history.apply(.insertInLayer(element: shape(101, x: 50, .ellipse), at: 0, layer: 1))
        try history.apply(.insertInLayer(element: shape(102, x: 90, .polygon), at: 0, layer: 2))
        let ids = history.scene.layers.map(\.id)
        try history.apply(.setLayerLocked(id: ids[0], true))
        try history.apply(.setLayerHidden(id: ids[2], true))
        return history.scene
    }

    private struct LayerShape: Equatable {
        var name: String
        var hidden: Bool
        var locked: Bool
        var count: Int
    }
    private static func shapeOf(_ scene: Scene) -> [LayerShape] {
        scene.layers.map { LayerShape(name: $0.name, hidden: $0.hidden, locked: $0.locked, count: $0.elements.count) }
    }

    // MARK: - Round trips

    @Test func layersRoundTripThroughEMF() throws {
        let scene = try Self.threeLayerScene()
        let exported = try SceneExporter.export(scene, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)

        #expect(Self.shapeOf(reimported) == [
            LayerShape(name: "Background", hidden: false, locked: true, count: 1),
            LayerShape(name: "Shapes", hidden: false, locked: false, count: 1),
            LayerShape(name: "Notes", hidden: true, locked: false, count: 1),
        ])
    }

    @Test func layersRoundTripThroughEMZ() throws {
        let scene = try Self.threeLayerScene()
        let exported = try SceneExporter.export(scene, as: .emz)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(Self.shapeOf(reimported) == Self.shapeOf(scene))
    }

    /// Save → import → save → import is stable (the markers are stripped and
    /// reinjected cleanly, never accumulated).
    @Test func layersAreStableAcrossTwoSaves() throws {
        let scene = try Self.threeLayerScene()
        let once = try SceneImporter.import(data: SceneExporter.export(scene, as: .emf).data)
        let twice = try SceneImporter.import(data: SceneExporter.export(once, as: .emf).data)
        #expect(Self.shapeOf(twice) == Self.shapeOf(scene))
        // Marker records should not pile up: the re-save's marker count equals a
        // begin+end per layer (3 × 2 = 6).
        let resaved = try SceneExporter.export(once, as: .emf).data
        let file = try EMFFile.parse(resaved)
        let bytes = [UInt8](resaved)
        var markerCount = 0
        for record in file.records where record.type == 70 {
            let slice = Array(bytes[record.offset ..< record.offset + Int(record.size)])
            if EMFLayerMarker.decode(recordBytes: slice) != nil { markerCount += 1 }
        }
        #expect(markerCount == 6)
    }

    // MARK: - Plain-renderer equivalence (markers ignored)

    /// The layer markers are render-invisible: the saved bytes (markers + every
    /// layer's content) render pixel-for-pixel the same as the identical scene
    /// FLATTENED to one marker-less layer, when both are drawn by the plain
    /// `MetafileRenderer` — so "another app" (which ignores the comments) sees the
    /// same image, including the hidden layer's content (design §2: hidden layers
    /// are still drawn elsewhere).
    @Test func markersDoNotChangeTheRendering() throws {
        let scene = try Self.threeLayerScene()
        // A flat equivalent: the same elements, one default "Imported" layer, no
        // markers — exports through the overlay WITHOUT emitting any marker record.
        var flat = scene
        flat.layers = [Layer(id: 0, name: Scene.defaultLayerName, elements: scene.elements)]
        flat.layerMarkerIndices = []
        #expect(!flat.hasNonTrivialLayers)
        #expect(scene.hasNonTrivialLayers)

        let withMarkers = try SceneExporter.export(scene, as: .emf).data
        let withoutMarkers = try SceneExporter.export(flat, as: .emf).data

        let a = try Self.render(withMarkers)
        let b = try Self.render(withoutMarkers)
        let diff = compareImages(a, b, tolerance: 2)
        #expect(diff.sameSize)
        #expect(diff.differingFraction < 0.001)
    }

    private static func render(_ data: Data) throws -> CGImage {
        let opened = try OpenedMetafile.open(data)
        let image = try #require(MetafileRenderer.makeImage(opened, scale: 1, background: .white)?.0)
        return image
    }
}
