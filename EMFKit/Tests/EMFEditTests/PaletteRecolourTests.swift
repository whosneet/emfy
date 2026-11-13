import CoreGraphics
import Foundation
import Testing
@testable import EMFEdit

// X2a: the deterministic palette recolour (greyscale, colour-blind-safe, print, brand).
// Pure maths — no model, no window.

// MARK: - Fixtures

private func rectPath(_ r: CGRect) -> ScenePath {
    ScenePath(segments: [
        .move(CGPoint(x: r.minX, y: r.minY)),
        .line(CGPoint(x: r.maxX, y: r.minY)),
        .line(CGPoint(x: r.maxX, y: r.maxY)),
        .line(CGPoint(x: r.minX, y: r.maxY)),
        .close,
    ])
}

private func filledRect(id: Int, _ r: CGRect, color: SceneColor) -> Element {
    var style = SceneStyle()
    style.fill = SceneFill(color: color, evenOdd: false)
    return Element(id: id, kind: .rect, geometryDevice: rectPath(r), transform: .identity,
                   style: style, provenance: Provenance(sourceRecordIndices: []))
}

private func textRun(id: Int, _ r: CGRect, color: SceneColor) -> Element {
    let text = SceneText(string: "Label", fontFamily: "Helvetica", logicalHeight: -16,
                         color: color, referenceLogical: CGPoint(x: r.minX, y: r.maxY), alignRawValue: 0)
    var style = SceneStyle()
    style.fill = SceneFill(color: color, evenOdd: false)
    return Element(id: id, kind: .text, geometryDevice: rectPath(r), transform: .identity,
                   style: style, text: text, provenance: Provenance(sourceRecordIndices: []))
}

private func makeScene(_ elements: [Element]) -> Scene {
    let layer = Layer(id: 0, name: "Layer 1", elements: elements)
    let source = SceneSource(data: Data(), format: .wmf, wasCompressed: false, renderPath: .wmf, unitCount: 0)
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    return Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 400, height: 300), layers: [layer], partition: partition, source: source)
}

private let white = SceneColor(red: 1, green: 1, blue: 1)

private func contrast(_ a: SceneColor, over b: SceneColor) -> Double {
    DrawingColorMath.contrastRatio(DrawingColorMath.composite(a, over: b), b)
}

// MARK: - Greyscale

@Test func greyscaleYieldsEqualChannels() {
    for colour in [SceneColor(red: 0.85, green: 0, blue: 0), SceneColor(red: 0, green: 0.6, blue: 0), SceneColor(red: 0.2, green: 0.4, blue: 0.9)] {
        let grey = PaletteRecolour.greyscale(colour)
        #expect(abs(grey.red - grey.green) < 1e-9)
        #expect(abs(grey.green - grey.blue) < 1e-9)
    }
}

@Test func greyscalePreservesLuminanceOrder() {
    let dark = PaletteRecolour.greyscale(SceneColor(red: 0.85, green: 0, blue: 0))
    let light = PaletteRecolour.greyscale(SceneColor(red: 0.9, green: 0.9, blue: 0.2))
    #expect(DrawingColorMath.relativeLuminance(dark) < DrawingColorMath.relativeLuminance(light))
}

@Test func greyscaleCommandsRecolourWholeScene() {
    let scene = makeScene([
        filledRect(id: 1, CGRect(x: 0, y: 0, width: 50, height: 50), color: SceneColor(red: 1, green: 0, blue: 0)),
        filledRect(id: 2, CGRect(x: 60, y: 0, width: 50, height: 50), color: SceneColor(red: 0, green: 0, blue: 1)),
    ])
    let commands = PaletteRecolour.commands(for: scene, ids: nil, mode: .greyscale)
    #expect(commands.count == 2)
    for command in commands {
        if case .setFill(_, let fill?) = command {
            #expect(abs(fill.color.red - fill.color.green) < 1e-9)
            #expect(abs(fill.color.green - fill.color.blue) < 1e-9)
        } else { Issue.record("expected setFill") }
    }
}

// MARK: - Colour-blind-safe

@Test func colourBlindMappedPairsAreDistinguishableUnderSimulation() {
    let red = SceneColor(red: 0.85, green: 0, blue: 0)
    let green = SceneColor(red: 0, green: 0.6, blue: 0)
    let scene = makeScene([
        filledRect(id: 1, CGRect(x: 0, y: 0, width: 80, height: 80), color: red),
        filledRect(id: 2, CGRect(x: 100, y: 0, width: 80, height: 80), color: green),
    ])
    let mapping = PaletteRecolour.mapping(for: scene, ids: nil, mode: .colourBlindSafe)
    #expect(mapping.count == 2)
    guard let a = mapping.first(where: { $0.from == red })?.to,
          let b = mapping.first(where: { $0.from == green })?.to else {
        Issue.record("both colours should map"); return
    }
    #expect(a != b)
    for type in DrawingColorMath.Dichromacy.allCases {
        let distance = DrawingColorMath.distance(DrawingColorMath.simulate(a, type), DrawingColorMath.simulate(b, type))
        #expect(distance > 0.15, "mapped pair must stay distinct under \(type): \(distance)")
    }
}

@Test func colourBlindPreservesLightnessOrder() {
    let darker = SceneColor(red: 0.3, green: 0.1, blue: 0.1)
    let lighter = SceneColor(red: 0.9, green: 0.85, blue: 0.3)
    let scene = makeScene([
        filledRect(id: 1, CGRect(x: 0, y: 0, width: 40, height: 40), color: darker),
        filledRect(id: 2, CGRect(x: 60, y: 0, width: 40, height: 40), color: lighter),
    ])
    let map = PaletteRecolour.colourBlindMap(PaletteRecolour.distinctColours(scene, ids: nil))
    guard let mappedDark = map[darker], let mappedLight = map[lighter] else { Issue.record("map"); return }
    let dl = DrawingColorMath.toHSL(mappedDark).lightness
    let ll = DrawingColorMath.toHSL(mappedLight).lightness
    #expect(dl <= ll)
}

// MARK: - Print

@Test func printForcesTextNearBlackAndKeepsVeryLightFills() {
    let scene = makeScene([
        textRun(id: 1, CGRect(x: 0, y: 0, width: 80, height: 20), color: SceneColor(red: 0.2, green: 0.4, blue: 0.9)),
        filledRect(id: 2, CGRect(x: 0, y: 40, width: 40, height: 40), color: SceneColor(red: 0.98, green: 0.98, blue: 0.95)),
        filledRect(id: 3, CGRect(x: 60, y: 40, width: 40, height: 40), color: SceneColor(red: 1, green: 0, blue: 1)),
    ])
    // Text → near-black.
    let textColour = PaletteRecolour.printText(SceneColor(red: 0.2, green: 0.4, blue: 0.9))
    #expect(textColour.red < 0.2 && textColour.green < 0.2 && textColour.blue < 0.2)
    // Very light fill kept unchanged → no command for element 2.
    let commands = PaletteRecolour.commands(for: scene, ids: nil, mode: .print)
    #expect(!commands.contains { if case .setFill(let ids, _) = $0 { return ids == [2] }; return false })
    // A vivid fill is pulled into the conservative gamut.
    let vivid = PaletteRecolour.printFill(SceneColor(red: 1, green: 0, blue: 1))
    let hsl = DrawingColorMath.toHSL(vivid)
    #expect(hsl.saturation <= 0.8 + 1e-9)
    #expect(hsl.lightness >= 0.2 - 1e-9 && hsl.lightness <= 0.85 + 1e-9)
}

// MARK: - Brand

@Test func brandMapsToNearestByDeltaE() {
    let brand = [SceneColor(red: 1, green: 0, blue: 0), SceneColor(red: 0, green: 0, blue: 1)]
    let nearRed = SceneColor(red: 0.8, green: 0.1, blue: 0.1)
    let nearBlue = SceneColor(red: 0.1, green: 0.1, blue: 0.75)
    #expect(PaletteRecolour.nearestBrand(nearRed, brand: brand) == brand[0])
    #expect(PaletteRecolour.nearestBrand(nearBlue, brand: brand) == brand[1])
}

@Test func brandTextKeepsContrastWhenADarkBrandColourExists() {
    // Dark, legible text (meets 4.5:1 on white).
    let darkText = SceneColor(red: 0.05, green: 0.05, blue: 0.1)
    #expect(contrast(darkText, over: white) >= 4.5)
    let brand = [SceneColor(red: 0.93, green: 0.93, blue: 0.93), SceneColor(red: 0.13, green: 0.13, blue: 0.13)]
    let scene = makeScene([textRun(id: 1, CGRect(x: 0, y: 0, width: 80, height: 20), color: darkText)])
    let commands = PaletteRecolour.commands(for: scene, ids: nil, mode: .brand(colours: brand))
    #expect(commands.count == 1)
    guard case .setFill(_, let fill?) = commands.first else { Issue.record("expected setFill"); return }
    // Must NOT pick the light brand colour, which would make the text illegible.
    #expect(contrast(fill.color, over: white) >= 4.5)
}

// MARK: - Text-contrast guarantee

@Test func enforceTextContrastRestoresLegibility() {
    // A dark, legible original mapped to a too-light colour must be darkened back.
    let original = SceneColor(red: 0, green: 0, blue: 0)
    let tooLight = SceneColor(red: 0.95, green: 0.9, blue: 0.3)
    #expect(contrast(tooLight, over: white) < 4.5)
    let fixed = PaletteRecolour.enforceTextContrast(tooLight, original: original)
    #expect(contrast(fixed, over: white) >= 4.5)
}

// MARK: - Undo

@Test func recolourUndoRestoresOriginalScene() {
    let scene = makeScene([
        filledRect(id: 1, CGRect(x: 0, y: 0, width: 50, height: 50), color: SceneColor(red: 0.85, green: 0, blue: 0)),
        filledRect(id: 2, CGRect(x: 60, y: 0, width: 50, height: 50), color: SceneColor(red: 0, green: 0.6, blue: 0)),
        textRun(id: 3, CGRect(x: 0, y: 70, width: 80, height: 20), color: SceneColor(red: 0.6, green: 0.6, blue: 0.6)),
    ])
    let original = scene
    var history = SceneHistory(scene: scene)
    let commands = PaletteRecolour.commands(for: scene, ids: nil, mode: .colourBlindSafe)
    #expect(!commands.isEmpty)
    history.performGroup(name: .group("edit.action.recolour")) { h in
        for command in commands { try? h.apply(command) }
    }
    #expect(history.scene != original)
    #expect(history.undoCount == 1)
    history.undo()
    #expect(history.scene == original)
}

// MARK: - Scope

@Test func recolourHonoursSelectionScope() {
    let scene = makeScene([
        filledRect(id: 1, CGRect(x: 0, y: 0, width: 50, height: 50), color: SceneColor(red: 1, green: 0, blue: 0)),
        filledRect(id: 2, CGRect(x: 60, y: 0, width: 50, height: 50), color: SceneColor(red: 0, green: 0, blue: 1)),
    ])
    let commands = PaletteRecolour.commands(for: scene, ids: [1], mode: .greyscale)
    #expect(commands.count == 1)
    if case .setFill(let ids, _) = commands.first { #expect(ids == [1]) } else { Issue.record("setFill") }
}
