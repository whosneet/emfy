import CoreGraphics
import EMFParse
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// E3c: the from-scratch text + image factory. A text element authored from a point
/// size and family round-trips every export format; an inserted image is fitted to
/// the page and round-trips too; and the insert-text undo group is one entry that
/// cancels cleanly. (The untrusted-image ingest caps live in `SceneImageIngestTests`.)
struct SceneTextImageFactoryTests {

    // MARK: - Scene helper

    private func a4Landscape() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    // MARK: - Text defaults and conversion

    @Test func textPointSizeConvertsThroughDeviceUnitsPerPoint() throws {
        let scene = try a4Landscape()
        let perPoint = scene.deviceUnitsPerPoint   // 96/72 on a blank doc
        let element = SceneFactory.makeText(
            string: "Text", originDevice: CGPoint(x: 300, y: 400), family: "Helvetica Neue",
            pointSize: 18, color: SceneColor(red: 0, green: 0, blue: 0), id: 0, deviceUnitsPerPoint: perPoint)
        let text = try #require(element.text)
        // 18 pt × (96/72) = 24 device units, stored as a NEGATIVE em height (LOGFONT).
        #expect(text.logicalHeight == -24)
        #expect(element.kind == .text)
        #expect(element.transform == .identity)
        #expect(text.isEMFPlus == false)
        #expect(text.color == SceneColor(red: 0, green: 0, blue: 0))
        #expect(text.referenceLogical == CGPoint(x: 300, y: 400))
        // Baseline-left alignment (TA_LEFT | TA_BASELINE).
        #expect(text.alignRawValue == SceneFactory.baselineLeftAlign)
        #expect(element.provenance.edited)
        #expect(element.provenance.sourceRecordIndices.isEmpty)
    }

    @Test func textDefaultsAt72DPIAreOneToOne() {
        // At 72 DPI, deviceUnitsPerPoint == 1, so an 18 pt run stores -18.
        let element = SceneFactory.makeText(
            string: "Hi", originDevice: .zero, family: "Arial", pointSize: 18,
            color: SceneColor(red: 1, green: 0, blue: 0), id: 3, deviceUnitsPerPoint: 1)
        #expect(element.text?.logicalHeight == -18)
        #expect(element.id == 3)
    }

    @Test func textBoundsAreNonDegenerate() {
        let element = SceneFactory.makeText(
            string: "Hello Emfy", originDevice: CGPoint(x: 100, y: 200), family: "Helvetica Neue",
            pointSize: 18, color: SceneColor(red: 0, green: 0, blue: 0), id: 0, deviceUnitsPerPoint: 96.0 / 72)
        #expect(element.boundsDevice.width > 0)
        #expect(element.boundsDevice.height > 0)
    }

    // MARK: - Text round trips

    private func textScene() throws -> Scene {
        var scene = try a4Landscape()
        let element = SceneFactory.makeText(
            string: "Hello Emfy", originDevice: CGPoint(x: 200, y: 300), family: "Helvetica Neue",
            pointSize: 24, color: SceneColor(red: 0, green: 0, blue: 0),
            id: SceneFactory.nextElementID(in: scene), deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
        scene.insert(element, at: 0)
        return scene
    }

    @Test(arguments: [EMFEdit.ExportFormat.emf, .emz])
    func textRoundTripsThroughEMF(format: EMFEdit.ExportFormat) throws {
        let scene = try textScene()
        let exported = try SceneExporter.export(scene, as: format)
        let reimported = try SceneImporter.import(data: exported.data)
        let text = try #require(reimported.editableElements.first { $0.kind == .text })
        #expect(text.text?.string == "Hello Emfy")
        let image = try #require(SceneRenderer.makeImage(reimported, scale: 0.5))
        #expect(!isBlank(image))
    }

    @Test func textExportsToWMF() throws {
        let scene = try textScene()
        let exported = try SceneExporter.export(scene, as: .wmf)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.editableElements.contains { $0.kind == .text })
    }

    @Test func textAppearsInSVGExport() throws {
        let scene = try textScene()
        let svg = SceneSVGExporter.export(scene)
        let text = try #require(String(data: svg.data, encoding: .utf8))
        #expect(text.contains("Hello Emfy") || text.contains("<text"))
    }

    // MARK: - Fit-to-50% placement

    @Test func fitRectIsHalfTheSmallerDimensionAndCentred() {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 600)
        // A square image: fits within 0.5 × 600 = 300, centred.
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 200, height: 200), pageBoundsDevice: page)
        #expect(abs(rect.width - 300) < 0.01)
        #expect(abs(rect.height - 300) < 0.01)
        #expect(abs(rect.midX - 500) < 0.01)
        #expect(abs(rect.midY - 300) < 0.01)
    }

    @Test func fitRectPreservesAspectRatio() {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 600)
        // A 4:1 image: the long side fits 300, the short side is 75.
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 400, height: 100), pageBoundsDevice: page)
        #expect(abs(rect.width - 300) < 0.01)
        #expect(abs(rect.height - 75) < 0.01)
    }

    @Test func fitRectCentresOnDropPoint() {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let drop = CGPoint(x: 700, y: 150)
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 200, height: 200), pageBoundsDevice: page, centreDevice: drop)
        #expect(abs(rect.midX - 700) < 0.01)
        #expect(abs(rect.midY - 150) < 0.01)
    }

    @Test func fitRectClampsDegenerateInput() {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 0, height: 0), pageBoundsDevice: page)
        #expect(rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite)
    }

    // MARK: - Image round trips

    private func imageScene() throws -> Scene {
        var scene = try a4Landscape()
        let cg = try gradientImage(width: 240, height: 160)
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 240, height: 160), pageBoundsDevice: scene.pageBoundsDevice)
        let element = try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: rect, id: SceneFactory.nextElementID(in: scene)))
        scene.insert(element, at: 0)
        return scene
    }

    @Test(arguments: [EMFEdit.ExportFormat.emf, .emz])
    func imageRoundTripsThroughEMF(format: EMFEdit.ExportFormat) throws {
        let scene = try imageScene()
        let exported = try SceneExporter.export(scene, as: format)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.editableElements.contains { $0.kind == .image })
        let image = try #require(SceneRenderer.makeImage(reimported, scale: 0.5))
        #expect(!isBlank(image))
    }

    @Test func imageExportsToWMF() throws {
        let scene = try imageScene()
        let exported = try SceneExporter.export(scene, as: .wmf)
        let reimported = try SceneImporter.import(data: exported.data)
        #expect(reimported.editableElements.contains { $0.kind == .image })
    }

    @Test func imageAppearsInSVGExport() throws {
        let scene = try imageScene()
        let svg = SceneSVGExporter.export(scene)
        let text = try #require(String(data: svg.data, encoding: .utf8))
        #expect(text.contains("<image"))
    }

    // MARK: - Insert-text undo group

    @Test func insertThenSetTextIsOneUndoEntry() throws {
        let scene = try a4Landscape()
        var history = SceneHistory(scene: scene)
        let element = SceneFactory.makeText(
            string: "Text", originDevice: CGPoint(x: 100, y: 100), family: "Helvetica Neue",
            pointSize: 18, color: SceneColor(red: 0, green: 0, blue: 0), id: 0, deviceUnitsPerPoint: 1)

        history.beginGroup(name: .group("edit.action.insertText"))
        try history.apply(.insert(element: element, at: 0))
        try history.apply(.setText(id: element.id, "Hello Emfy"))
        history.endGroup()

        #expect(history.undoCount == 1)
        #expect(history.scene.editableElements.count == 1)
        #expect(history.scene.editableElements.first?.text?.string == "Hello Emfy")

        // One undo removes the whole insert+setText.
        history.undo()
        #expect(history.scene.editableElements.isEmpty)
        #expect(history.undoCount == 0)
    }

    @Test func cancelOnNewTextLeavesNothing() throws {
        let scene = try a4Landscape()
        var history = SceneHistory(scene: scene)
        let element = SceneFactory.makeText(
            string: "Text", originDevice: .zero, family: "Arial", pointSize: 18,
            color: SceneColor(red: 0, green: 0, blue: 0), id: 0, deviceUnitsPerPoint: 1)

        history.beginGroup(name: .group("edit.action.insertText"))
        try history.apply(.insert(element: element, at: 0))
        #expect(history.scene.editableElements.count == 1)   // shown while editing
        history.abortGroup()

        // The element is gone and nothing was recorded.
        #expect(history.scene.editableElements.isEmpty)
        #expect(history.undoCount == 0)
        #expect(history.canUndo == false)
        #expect(history.scene == scene)
    }

    // MARK: - Fixtures / helpers

    /// A simple RGB gradient CGImage (opaque), for the image round trips.
    private func gradientImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.3, blue: 0.1, alpha: 1)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return try #require(ctx.makeImage())
    }

    /// True when every pixel is fully transparent or identical white — a blank canvas.
    private func isBlank(_ image: CGImage) -> Bool {
        guard let pixels = PixelImage(image) else { return true }
        let count = pixels.pixels.count / 4
        for i in 0 ..< count {
            let o = i * 4
            let r = pixels.pixels[o], g = pixels.pixels[o + 1], b = pixels.pixels[o + 2], a = pixels.pixels[o + 3]
            if a > 8 && (r < 240 || g < 240 || b < 240) { return false }
        }
        return true
    }
}
