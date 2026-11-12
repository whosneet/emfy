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

    // MARK: - WMF flattens layers with a warning (fix 3)

    @Test(arguments: [ExportFormat.wmf, .wmz])
    func wmfExportFlattensLayersWithAWarning(_ format: ExportFormat) throws {
        let scene = try Self.threeLayerScene()
        let result = try SceneExporter.export(scene, as: format)
        #expect(result.warnings.contains(.layersFlattened))
        #expect(SceneExporter.summarize(result.warnings)[.layers] == 1)
        // The WMF re-imports as a single layer (no markers persisted there).
        let reimported = try SceneImporter.import(data: result.data)
        #expect(reimported.layers.count == 1)
    }

    @Test func wmfExportOfaTrivialSceneHasNoLayerWarning() throws {
        let scene = try Self.blankScene()   // one default layer, no markers
        var history = SceneHistory(scene: scene)
        try history.apply(.insertInLayer(element: Self.shape(1, x: 10), at: 0, layer: 0))
        let result = try SceneExporter.export(history.scene, as: .wmf)
        #expect(!result.warnings.contains(.layersFlattened))
    }

    // MARK: - Arrange / move reach the saved file for UNEDITED source elements (fix 2)

    /// Two overlapping rectangles — a red one drawn first, a blue one on top — as a
    /// real EMF, so importing yields two UNEDITED source elements.
    private static func twoRectEMF() -> Data {
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        var records: [[UInt8]] = []
        var header: [UInt8] = []
        header += u32(1) + u32(88)
        header += i32(0) + i32(0) + i32(99) + i32(99)          // rclBounds
        header += i32(0) + i32(0) + i32(2645) + i32(2645)      // rclFrame
        header += u32(0x464D_4520) + u32(0x0001_0000)
        header += u32(228) + u32(8)                            // nBytes, nRecords (advisory)
        header += u16(3) + u16(0)                              // nHandles
        header += u32(0) + u32(0) + u32(0)
        header += i32(1920) + i32(1080)
        header += i32(320) + i32(240)
        records.append(header)
        // Red brush (ih 1) → select → rect (10,10)-(60,60).
        records.append(u32(39) + u32(24) + u32(1) + u32(0) + [255, 0, 0, 0] + u32(0))
        records.append(u32(37) + u32(12) + u32(1))
        records.append(u32(43) + u32(24) + i32(10) + i32(10) + i32(60) + i32(60))
        // Blue brush (ih 2) → select → rect (40,40)-(90,90), drawn on top.
        records.append(u32(39) + u32(24) + u32(2) + u32(0) + [0, 0, 255, 0] + u32(0))
        records.append(u32(37) + u32(12) + u32(2))
        records.append(u32(43) + u32(24) + i32(40) + i32(40) + i32(90) + i32(90))
        records.append(u32(14) + u32(20) + u32(0) + u32(0) + u32(20))
        return Data(records.flatMap { $0 })
    }

    /// The RGBA of the device-space overlap centre (~50,50) in a 100×100 render.
    private static func overlapPixel(_ image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let px = try #require(PixelImage(image))
        try #require(px.width == 100 && px.height == 100)
        let o = (50 * px.width + 50) * 4
        return (Int(px.pixels[o]), Int(px.pixels[o + 1]), Int(px.pixels[o + 2]))
    }

    @Test func bringToFrontOfUneditedElementReachesTheSavedFile() throws {
        var history = SceneHistory(scene: try SceneImporter.import(data: Self.twoRectEMF()))
        let els = history.scene.elements
        try #require(els.count == 2)
        // The source element provenance is unedited.
        #expect(els.allSatisfy { !$0.provenance.edited })
        // Overlap starts blue (the second rect is on top).
        let before = try Self.overlapPixel(try Self.render(SceneExporter.export(history.scene, as: .emf).data))
        #expect(before.b > before.r)

        // Bring the first (bottom, red) element to the front, save, re-render.
        try history.apply(.arrange(ids: [els[0].id], .toFront))
        let after = try Self.overlapPixel(try Self.render(SceneExporter.export(history.scene, as: .emf).data))
        #expect(after.r > after.b)   // red is now on top
    }

    @Test func moveToLayerOfUneditedElementReachesTheSavedFile() throws {
        var history = SceneHistory(scene: try SceneImporter.import(data: Self.twoRectEMF()))
        let els = history.scene.elements
        try #require(els.count == 2)
        // Add a top layer and move the red (bottom) element into it; a higher layer
        // draws later, so red ends on top.
        try history.apply(.addLayer(name: "Top", at: 1))
        try history.apply(.moveElementsToLayer(ids: [els[0].id], layer: 1))
        let after = try Self.overlapPixel(try Self.render(SceneExporter.export(history.scene, as: .emf).data))
        #expect(after.r > after.b)
    }
}
