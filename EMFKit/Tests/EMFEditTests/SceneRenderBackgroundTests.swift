import CoreGraphics
import Foundation
import Testing
@testable import EMFEdit

/// P1 polish: `SceneRenderer.makeImage` (the edited-scene PNG export/copy path)
/// used to white the page regardless of the Export › PNG background setting, so a
/// transparent-background export came out opaque white. It now honours
/// `RenderBackground`, exactly as the viewer's PNG export does.
struct SceneRenderBackgroundTests {

    /// A blank A5 page with one filled rectangle in the middle, so the page corners
    /// stay empty — the region whose alpha the background setting decides.
    private func sceneWithCentreShape() throws -> Scene {
        var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 148)))
        let page = scene.pageSizeDevice
        let box = CGRect(x: page.width * 0.4, y: page.height * 0.4, width: page.width * 0.2, height: page.height * 0.2)
        let id = SceneFactory.nextElementID(in: scene)
        let style = SceneStyle(fill: SceneFill(color: SceneColor(red: 0.2, green: 0.5, blue: 0.9), evenOdd: false), stroke: nil)
        scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: box, style: style, id: id), at: scene.elements.count)
        return scene
    }

    /// The straight (un-premultiplied source) alpha/rgb at the image's top-left pixel.
    private func cornerPixel(_ image: CGImage) -> (a: UInt8, r: UInt8, g: UInt8, b: UInt8)? {
        guard let p = PixelImage(image), p.width > 0, p.height > 0 else { return nil }
        return (p.pixels[3], p.pixels[0], p.pixels[1], p.pixels[2])
    }

    @Test func transparentBackgroundLeavesEmptyCornerClear() throws {
        let scene = try sceneWithCentreShape()
        let image = try #require(SceneRenderer.makeImage(scene, scale: 1, background: .transparent))
        let corner = try #require(cornerPixel(image))
        #expect(corner.a == 0, "transparent export corner alpha should be 0, was \(corner.a)")
    }

    @Test func whiteBackgroundFillsEmptyCorner() throws {
        let scene = try sceneWithCentreShape()
        let image = try #require(SceneRenderer.makeImage(scene, scale: 1, background: .white))
        let corner = try #require(cornerPixel(image))
        #expect(corner.a == 255, "white export corner alpha should be 255, was \(corner.a)")
        #expect(corner.r == 255 && corner.g == 255 && corner.b == 255,
                "white export corner should be white, was (\(corner.r),\(corner.g),\(corner.b))")
    }

    @Test func defaultBackgroundStaysWhite() throws {
        // The default (no argument) must stay white, so every existing caller's output
        // is byte-for-byte unchanged.
        let scene = try sceneWithCentreShape()
        let image = try #require(SceneRenderer.makeImage(scene, scale: 1))
        let corner = try #require(cornerPixel(image))
        #expect(corner.a == 255 && corner.r == 255 && corner.g == 255 && corner.b == 255)
    }
}
