import CoreGraphics
import EMFParse
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// E3a: the from-scratch document + shape factory. A blank document is a real,
/// minimal EMF that parses, accounts for every byte, imports to an empty scene
/// with the right page bounds, and round-trips; shapes survive save → re-import
/// → render and carry unique ids.
struct SceneFactoryTests {

    // MARK: - Blank document

    @Test func blankDocumentParsesAndAccountsForEveryByte() throws {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210))
        let file = try EMFFile.parse(data)
        // Header + EOF, nothing else.
        #expect(file.records.count == 2)
        #expect(file.records.first?.type == 1)   // EMR_HEADER
        #expect(file.records.last?.type == 14)   // EMR_EOF
        // The walker's accounting covers the whole file: the header Bytes field
        // equals the data length and the records tile it exactly.
        #expect(Int(file.header.bytes) == data.count)
        let walked = file.records.reduce(0) { $0 + Int($1.size) }
        #expect(walked == data.count)
    }

    @Test func blankDocumentImportsToEmptySceneWithPageBounds() throws {
        // A4 landscape: 297 × 210 mm at 96 DPI → 1122 × 794 device pixels.
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210))
        let scene = try SceneImporter.import(data: data)
        #expect(scene.elements.isEmpty)
        #expect(scene.editableElements.isEmpty)
        let expectedW = Int((297.0 / 25.4 * 96).rounded())
        let expectedH = Int((210.0 / 25.4 * 96).rounded())
        #expect(scene.pageBoundsDevice.origin == .zero)
        #expect(Int(scene.pageBoundsDevice.width.rounded()) == expectedW)
        #expect(Int(scene.pageBoundsDevice.height.rounded()) == expectedH)
    }

    @Test func blankDocumentRoundTripsThroughExport() throws {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 297))
        let scene = try SceneImporter.import(data: data)
        // An unedited blank scene re-emits; the result re-imports to the same page.
        let exported = try SceneExporter.export(scene, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.elements.isEmpty)
        #expect(reimported.pageBoundsDevice.size == scene.pageBoundsDevice.size)
        #expect(exported.warnings.isEmpty)
    }

    @Test(arguments: [
        CGSize(width: 297, height: 210),   // A4 landscape
        CGSize(width: 210, height: 297),   // A4 portrait
        CGSize(width: 215.9, height: 279.4),  // US Letter portrait
        CGSize(width: 254, height: 142.875),  // 16:9
    ])
    func blankDocumentPreservesAspectRatio(size: CGSize) throws {
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: size)
        let scene = try SceneImporter.import(data: data)
        let pageAspect = scene.pageBoundsDevice.width / scene.pageBoundsDevice.height
        let mmAspect = size.width / size.height
        #expect(abs(pageAspect - mmAspect) < 0.02)
    }

    @Test func blankDocumentClampsDegeneratePageSize() throws {
        // A zero/negative dimension must not trap; it clamps to a 1×1-floor page.
        let data = try SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 0, height: -5))
        let scene = try SceneImporter.import(data: data)
        #expect(scene.pageBoundsDevice.width >= 1)
        #expect(scene.pageBoundsDevice.height >= 1)
    }

    // MARK: - Shapes survive save → re-import → render

    private func a4Landscape() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    @Test(arguments: [ElementKind.rect, .roundRect, .ellipse, .line, .polygon])
    func shapeSurvivesSaveReimportAndRenders(kind: ElementKind) throws {
        var scene = try a4Landscape()
        let rect = CGRect(x: 200, y: 150, width: 300, height: 200)
        let style = kind == .line ? SceneFactory.defaultLineStyle(widthDevice: 3) : SceneFactory.defaultShapeStyle
        let shape = SceneFactory.makeShape(kind: kind, rectDevice: rect, style: style,
                                           id: SceneFactory.nextElementID(in: scene), cornerRadiusDevice: 24)
        scene.insert(shape, at: 0)

        // Export (synthesises the new element), then re-import.
        let exported = try SceneExporter.export(scene, as: .emf)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.editableElements.count == 1)

        // The re-imported shape renders a non-blank image somewhere on the page.
        let image = try #require(SceneRenderer.makeImage(reimported, scale: 0.5))
        #expect(image.width > 0 && image.height > 0)
        #expect(!isBlank(image))
    }

    @Test(arguments: [EMFEdit.ExportFormat.emf, .emz])
    func roundRectRoundTripsAsRoundRectWithRadius(format: EMFEdit.ExportFormat) throws {
        var scene = try a4Landscape()
        let radius: CGFloat = 40
        let shape = SceneFactory.makeShape(kind: .roundRect, rectDevice: CGRect(x: 100, y: 100, width: 400, height: 250),
                                           style: SceneFactory.defaultShapeStyle, id: 0, cornerRadiusDevice: radius)
        scene.insert(shape, at: 0)
        let exported = try SceneExporter.export(scene, as: format)
        // EMR_ROUNDRECT carries the corner, so no kind-fallback warning.
        #expect(!exported.warnings.contains { if case .kindFallback = $0 { return true }; return false })
        let reimported = try SceneImporter.import(data: exported.data)
        let element = try #require(reimported.editableElements.first)
        #expect(element.kind == .roundRect)   // kind preserved, not downgraded to a path
        // The radius survives: recover it from the re-imported geometry.
        let recovered = try #require(SceneSynthesis.roundRectBoxAndRadius(element.geometryDevice))
        #expect(abs(recovered.radius - radius) <= 1.5)
    }

    @Test(arguments: [ElementKind.rect, .ellipse, .line, .polygon])
    func shapeAppearsInSVGExport(kind: ElementKind) throws {
        var scene = try a4Landscape()
        let style = kind == .line ? SceneFactory.defaultLineStyle(widthDevice: 3) : SceneFactory.defaultShapeStyle
        let shape = SceneFactory.makeShape(kind: kind, rectDevice: CGRect(x: 120, y: 120, width: 240, height: 180),
                                           style: style, id: 0)
        scene.insert(shape, at: 0)
        let svg = SceneSVGExporter.export(scene)
        let text = try #require(String(data: svg.data, encoding: .utf8))
        // A drawn shape produces a path/polygon/line/ellipse/rect element in the SVG.
        #expect(text.contains("<path") || text.contains("<polygon") || text.contains("<polyline")
            || text.contains("<rect") || text.contains("<ellipse") || text.contains("<line"))
    }

    // MARK: - Geometry

    @Test func rectGeometryIsAxisAlignedRectangle() {
        let shape = SceneFactory.makeShape(kind: .rect, rectDevice: CGRect(x: 10, y: 20, width: 100, height: 60),
                                           style: SceneFactory.defaultShapeStyle, id: 0)
        let box = try? #require(SceneSynthesis.axisAlignedRect(shape.geometryDevice))
        #expect(box?.width == 100)
        #expect(box?.height == 60)
    }

    @Test func lineGeometryPreservesDragDirection() {
        // A drag up-and-left: negative width/height. The endpoints keep the direction.
        let shape = SceneFactory.makeShape(kind: .line, rectDevice: CGRect(x: 300, y: 300, width: -100, height: -50),
                                           style: SceneFactory.defaultLineStyle(widthDevice: 2), id: 0)
        #expect(shape.geometryDevice.segments.count == 2)
        guard case .move(let start) = shape.geometryDevice.segments[0],
              case .line(let end) = shape.geometryDevice.segments[1] else {
            Issue.record("line geometry is not move+line"); return
        }
        #expect(start == CGPoint(x: 300, y: 300))
        #expect(end == CGPoint(x: 200, y: 250))
    }

    @Test func triangleHasThreeDistinctVertices() throws {
        let shape = SceneFactory.makeShape(kind: .polygon, rectDevice: CGRect(x: 0, y: 0, width: 100, height: 80),
                                           style: SceneFactory.defaultShapeStyle, id: 0)
        let subs = try #require(SceneSynthesis.lineSubpaths(shape.geometryDevice))
        #expect(subs.count == 1)
        #expect(subs[0].count == 3)
    }

    // MARK: - Physical resolution (review 1)

    @Test func blankDocumentResolutionIs96DPI() throws {
        let scene = try a4Landscape()
        let dpi = try #require(scene.deviceUnitsPerInch)
        #expect(abs(dpi - 96) < 0.5)                       // authored at 96 DPI
        #expect(abs(scene.deviceUnitsPerPoint - 96.0 / 72) < 0.01)
    }

    @Test func corpusResolutionMatchesTheHeaderRatio() throws {
        // A real EMF: Scene.deviceUnitsPerInch must equal the header's own device-vs-
        // physical ratio (bounds vs frame), whatever its DPI — so shapes are sized
        // physically on an imported drawing, not at a fixed 96 DPI.
        let url = EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-house.emf")
        let data = try Data(contentsOf: url)
        let scene = try SceneImporter.import(data: data)
        let file = try EMFFile.parse(data)
        let b = file.header.bounds, f = file.header.frame
        let devW = Double(Int64(b.right) - Int64(b.left) + 1)
        let frameWmm = Double(Int64(f.right) - Int64(f.left)) / 100
        let expectedDPIx = devW / frameWmm * 25.4
        let dpi = try #require(scene.deviceUnitsPerInch)
        // Within the X/Y averaging and rounding; the header ratio drives it.
        #expect(abs(dpi - expectedDPIx) < max(2, expectedDPIx * 0.05))
        #expect(scene.deviceUnitsPerPoint > 0)
    }

    // MARK: - Hostile header resolution (§8)

    /// A 40-byte buffer with the given rclBounds and rclFrame, for the resolution reader.
    private func emfHeaderBytes(bounds: (Int32, Int32, Int32, Int32), frame: (Int32, Int32, Int32, Int32)) -> Data {
        var d = Data(count: 40)
        func put(_ v: Int32, _ off: Int) {
            let u = UInt32(bitPattern: v)
            d[off] = UInt8(u & 0xFF); d[off + 1] = UInt8((u >> 8) & 0xFF)
            d[off + 2] = UInt8((u >> 16) & 0xFF); d[off + 3] = UInt8((u >> 24) & 0xFF)
        }
        put(bounds.0, 8); put(bounds.1, 12); put(bounds.2, 16); put(bounds.3, 20)
        put(frame.0, 24); put(frame.1, 28); put(frame.2, 32); put(frame.3, 36)
        return d
    }

    @Test func hostileEMFResolutionFallsBack() {
        // A 1-unit frame → an astronomically high DPI → rejected.
        #expect(Scene.emfDeviceUnitsPerInch(emfHeaderBytes(bounds: (0, 0, 10_000, 10_000), frame: (0, 0, 1, 1))) == nil)
        // A tiny device over a huge frame → near-zero DPI → rejected.
        #expect(Scene.emfDeviceUnitsPerInch(emfHeaderBytes(bounds: (0, 0, 1, 1), frame: (0, 0, 1_000_000, 1_000_000))) == nil)
        // A degenerate (zero) frame → rejected.
        #expect(Scene.emfDeviceUnitsPerInch(emfHeaderBytes(bounds: (0, 0, 100, 100), frame: (0, 0, 0, 0))) == nil)
        // A truncated header → rejected.
        #expect(Scene.emfDeviceUnitsPerInch(Data(count: 20)) == nil)
        // A sane 96-DPI header is still accepted.
        let ok = Scene.emfDeviceUnitsPerInch(emfHeaderBytes(bounds: (0, 0, 1122, 793), frame: (0, 0, 29_700, 21_000)))
        #expect(ok != nil)
    }

    @Test func hostileWMFInchFallsBack() {
        func placeable(inch: UInt16) -> Data {
            var d = Data(count: 16)
            d[14] = UInt8(inch & 0xFF); d[15] = UInt8((inch >> 8) & 0xFF)
            return d
        }
        #expect(Scene.placeableWMFUnitsPerInch(placeable(inch: 1)) == nil)       // garbage low
        #expect(Scene.placeableWMFUnitsPerInch(placeable(inch: 65535)) == nil)   // garbage high
        #expect(Scene.placeableWMFUnitsPerInch(placeable(inch: 0)) == nil)       // absent
        #expect(Scene.placeableWMFUnitsPerInch(placeable(inch: 1440)) == 1440)   // a real value
    }

    // MARK: - Unique ids

    @Test func nextElementIDIsOnePastLargest() throws {
        var scene = try a4Landscape()
        #expect(SceneFactory.nextElementID(in: scene) == 0)
        scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: CGRect(x: 0, y: 0, width: 10, height: 10),
                                            style: SceneFactory.defaultShapeStyle, id: 0), at: 0)
        #expect(SceneFactory.nextElementID(in: scene) == 1)
        scene.insert(SceneFactory.makeShape(kind: .ellipse, rectDevice: CGRect(x: 0, y: 0, width: 10, height: 10),
                                            style: SceneFactory.defaultShapeStyle, id: SceneFactory.nextElementID(in: scene)), at: 0)
        // Two elements with ids 0 and 1 → next is 2, and the ids are distinct.
        #expect(SceneFactory.nextElementID(in: scene) == 2)
        #expect(Set(scene.elements.map(\.id)).count == scene.elements.count)
    }

    // MARK: - Helpers

    /// True when every pixel is fully transparent or identical white — a blank canvas.
    private func isBlank(_ image: CGImage) -> Bool {
        guard let pixels = PixelImage(image) else { return true }
        var sawInk = false
        let count = pixels.pixels.count / 4
        for i in 0 ..< count {
            let o = i * 4
            let r = pixels.pixels[o], g = pixels.pixels[o + 1], b = pixels.pixels[o + 2], a = pixels.pixels[o + 3]
            if a > 8 && (r < 240 || g < 240 || b < 240) { sawInk = true; break }
        }
        return !sawInk
    }
}
