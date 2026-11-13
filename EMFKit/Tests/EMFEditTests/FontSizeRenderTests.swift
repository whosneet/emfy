import CoreGraphics
import Foundation
import Testing
@testable import EMFEdit

// X2a correction 2: a font-size change must actually RENDER bigger — for GDI text AND
// EMF+ text — both live (in the edited scene) and after a save → reload round-trip. The
// bug was that an EMF+ run sizes from EmfPlusFont EmSize, not logicalHeight, so a
// logicalHeight-only setFont was dropped. These are render-based (ink-pixel) tests.

private func inkPixels(_ scene: Scene, scale: CGFloat = 2) -> Int {
    guard let image = SceneRenderer.makeImage(scene, scale: scale), let px = PixelImage(image) else { return 0 }
    var count = 0
    var i = 0
    while i + 2 < px.pixels.count {
        if px.pixels[i] < 200 || px.pixels[i + 1] < 200 || px.pixels[i + 2] < 200 { count += 1 }
        i += 4
    }
    return count
}

@MainActor
private func gdiTextScene(points: Double) throws -> Scene {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 120, height: 80)))
    let id = SceneFactory.nextElementID(in: scene)
    scene.insert(SceneFactory.makeText(string: "Size", originDevice: CGPoint(x: 20, y: 80), family: "Helvetica", pointSize: points, color: SceneColor(red: 0, green: 0, blue: 0), id: id, deviceUnitsPerPoint: scene.deviceUnitsPerPoint), at: scene.elements.count)
    return scene
}

@MainActor
private func emfPlusTextElement(id: Int, em: Double) -> Element {
    var text = SceneText(string: "Size", fontFamily: "Helvetica", logicalHeight: 0,
                         color: SceneColor(red: 0, green: 0, blue: 0),
                         referenceLogical: CGPoint(x: 20, y: 80), alignRawValue: 0)
    text.isEMFPlus = true
    text.emSize = em
    text.emSizeUnit = 0   // World
    return Element(id: id, kind: .text,
                   geometryDevice: ScenePath(CGPath(rect: CGRect(x: 20, y: 40, width: 80, height: 40), transform: nil)),
                   transform: .identity, text: text,
                   provenance: Provenance(sourceRecordIndices: [], edited: true))
}

@MainActor
private func emfPlusTextScene(em: Double) throws -> Scene {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 120, height: 80)))
    scene.insert(emfPlusTextElement(id: SceneFactory.nextElementID(in: scene), em: em), at: scene.elements.count)
    return scene
}

@Test @MainActor func gdiFontSizeChangeRendersBigger() throws {
    var scene = try gdiTextScene(points: 10)
    let before = inkPixels(scene)
    let id = try #require(scene.editableElements.first?.id)
    try scene.setFont(id, family: "Helvetica", size: 40, bold: false, italic: false)
    let after = inkPixels(scene)
    #expect(before > 0)
    #expect(after > before * 2, "GDI text should render markedly bigger (before=\(before) after=\(after))")
}

@Test @MainActor func emfPlusFontSizeChangeRendersBigger() throws {
    var scene = try emfPlusTextScene(em: 14)
    let before = inkPixels(scene)
    let id = try #require(scene.editableElements.first?.id)
    try scene.setFont(id, family: "Helvetica", size: 56, bold: false, italic: false)
    let after = inkPixels(scene)
    #expect(before > 0)
    #expect(after > before * 2, "EMF+ text should render markedly bigger (before=\(before) after=\(after))")
}

@Test @MainActor func emfPlusFontSizeChangeSurvivesRoundTrip() throws {
    // Baseline EMF+ run exported and reimported.
    let small = try emfPlusTextScene(em: 14)
    let smallData = try SceneExporter.export(small, as: .emf).data
    let smallReloaded = try SceneImporter.import(data: smallData)
    let smallInk = inkPixels(smallReloaded)

    // The same run, enlarged, exported and reimported.
    var big = try emfPlusTextScene(em: 14)
    let id = try #require(big.editableElements.first?.id)
    try big.setFont(id, family: "Helvetica", size: 56, bold: false, italic: false)
    let bigData = try SceneExporter.export(big, as: .emf).data
    let bigReloaded = try SceneImporter.import(data: bigData)
    let bigInk = inkPixels(bigReloaded)

    #expect(smallInk > 0)
    #expect(bigInk > smallInk * 2, "an enlarged EMF+ run must stay enlarged after save → reload (small=\(smallInk) big=\(bigInk))")
}

@Test @MainActor func setFontUpdatesEmSizeForEMFPlusRun() throws {
    var scene = try emfPlusTextScene(em: 14)
    let id = try #require(scene.editableElements.first?.id)
    try scene.setFont(id, family: "Arial", size: 48, bold: false, italic: false)
    let text = try #require(scene.element(id: id)?.text)
    #expect(text.emSize == 48)
    #expect(text.emSizeUnit == 0)        // World
    #expect(text.logicalHeight == -48)
}
