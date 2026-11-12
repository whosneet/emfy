import CoreGraphics
import EMFEdit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// E3c: the shared text/image tool helpers (`TextToolInsertion`, `ImageInsertTool`) and
// the single-armed-tool exclusivity on `EditorModel`. Pure-logic tests in the EmfyTests
// bundle (no canvas/window needed).

@Suite struct TextToolInsertionTests {

    private func blankScene() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    @Test func insertedTextHasTheToolDefaults() throws {
        let scene = try blankScene()
        let insertion = TextToolInsertion.element(originDevice: CGPoint(x: 120, y: 240), in: scene)
        let text = try #require(insertion.element.text)
        #expect(insertion.element.kind == .text)
        #expect(text.string == "Text")
        #expect(text.color == SceneColor(red: 0, green: 0, blue: 0))
        #expect(text.referenceLogical == CGPoint(x: 120, y: 240))
        #expect(text.alignRawValue == SceneFactory.baselineLeftAlign)
        // 18 pt at 96 DPI (1.333 device units/pt) → -24 (negative em height).
        #expect(text.logicalHeight == -24)
        // "Helvetica Neue" when installed on this machine, else "Arial".
        #expect(text.fontFamily == TextToolInsertion.preferredFamily())
    }

    @Test func idsAreUniqueAcrossInserts() throws {
        var scene = try blankScene()
        let first = TextToolInsertion.element(originDevice: .zero, in: scene)
        scene.insert(first.element, at: 0)
        let second = TextToolInsertion.element(originDevice: .zero, in: scene)
        #expect(first.id != second.id)
    }
}

@Suite struct ImageInsertToolTests {

    private func blankScene() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    @Test func insertsAFittedImageElement() throws {
        let scene = try blankScene()
        let png = try pngFixture(width: 400, height: 100)
        let result = ImageInsertTool.element(imageData: png, pageBoundsDevice: scene.pageBoundsDevice, centreDevice: nil, in: scene)
        guard case .success(let inserted) = result else { Issue.record("expected success"); return }
        #expect(inserted.element.kind == .image)
        #expect(inserted.element.image?.emfPlusImage != nil)
        // Fitted within 50% of the smaller page side, aspect preserved (4:1).
        let rect = inserted.element.image?.destRectDevice ?? .zero
        #expect(abs(rect.width / rect.height - 4) < 0.01)
        #expect(rect.maxX <= scene.pageBoundsDevice.width)
        // Centred on the page.
        #expect(abs(rect.midX - scene.pageBoundsDevice.midX) < 0.5)
        #expect(abs(rect.midY - scene.pageBoundsDevice.midY) < 0.5)
    }

    @Test func garbageInputFailsUndecodable() throws {
        let scene = try blankScene()
        let result = ImageInsertTool.element(imageData: Data([0, 1, 2, 3]), pageBoundsDevice: scene.pageBoundsDevice, centreDevice: nil, in: scene)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure == .undecodable)
    }

    private func pngFixture(width: Int, height: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let buffer = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return buffer as Data
    }
}

@MainActor
@Suite struct EditorToolExclusivityTests {

    @Test func armingOneToolDisarmsTheOthers() {
        let model = EditorModel()

        model.armShape(.rect)
        #expect(model.armedShapeTool == .rect)
        #expect(!model.armedPen)
        #expect(!model.armedTextTool)

        model.armPen()
        #expect(model.armedPen)
        #expect(model.armedShapeTool == nil)
        #expect(!model.armedTextTool)

        model.armText()
        #expect(model.armedTextTool)
        #expect(!model.armedPen)
        #expect(model.armedShapeTool == nil)

        model.armShape(.ellipse)
        #expect(model.armedShapeTool == .ellipse)
        #expect(!model.armedTextTool)
        #expect(!model.armedPen)
    }

    @Test func disarmToolsClearsEveryTool() {
        let model = EditorModel()
        model.armText()
        model.disarmTools()
        #expect(!model.armedTextTool)
        #expect(!model.armedPen)
        #expect(model.armedShapeTool == nil)
    }
}
