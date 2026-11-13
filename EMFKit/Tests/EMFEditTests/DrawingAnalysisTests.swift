import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

// X1a: the deterministic accessibility/legibility analysis and the one-tap fix
// planners. Pure maths, so everything here runs without a model or a window.

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

private func filledRect(id: Int, _ r: CGRect, color: SceneColor, locked: Bool = false, passthrough: Bool = false) -> Element {
    var style = SceneStyle()
    style.fill = SceneFill(color: color, evenOdd: false)
    return Element(
        id: id, kind: passthrough ? .passthrough : .rect, geometryDevice: rectPath(r), transform: .identity,
        style: style, provenance: Provenance(sourceRecordIndices: []), locked: locked,
        passthroughReason: passthrough ? .rasterOp : nil
    )
}

/// A GDI text run whose print point size is `points` on a 96-DPI (plain-WMF) page:
/// logicalHeight = points × (96/72) with an identity transform.
private func textRun(id: Int, _ r: CGRect, points: Double, color: SceneColor, bold: Bool = false, locked: Bool = false) -> Element {
    let logical = Int32((points * 96.0 / 72.0).rounded())
    var text = SceneText(
        string: "Label", fontFamily: "Helvetica", logicalHeight: -logical,
        color: color, referenceLogical: CGPoint(x: r.minX, y: r.maxY), alignRawValue: 0, bold: bold
    )
    text.string = "Label"
    var style = SceneStyle()
    style.fill = SceneFill(color: color, evenOdd: false)
    return Element(
        id: id, kind: .text, geometryDevice: rectPath(r), transform: .identity,
        style: style, text: text, provenance: Provenance(sourceRecordIndices: []), locked: locked
    )
}

private func makeScene(_ elements: [Element], page: CGSize = CGSize(width: 400, height: 300)) -> Scene {
    let layer = Layer(id: 0, name: "Layer 1", elements: elements)
    let source = SceneSource(data: Data(), format: .wmf, wasCompressed: false, renderPath: .wmf, unitCount: 0)
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    return Scene(pageBoundsDevice: CGRect(origin: .zero, size: page), layers: [layer], partition: partition, source: source)
}

private func gdi(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SceneColor { SceneColor(ColorRef(red: r, green: g, blue: b)) }
private let white = SceneColor(red: 1, green: 1, blue: 1)
private let black = SceneColor(red: 0, green: 0, blue: 0)

// MARK: - WCAG maths

@Suite struct WCAGContrastTests {

    @Test func blackOnWhiteIs21() {
        #expect(abs(DrawingColorMath.contrastRatio(black, white) - 21) < 0.01)
    }

    @Test func grey777OnWhiteFailsAA() {
        let ratio = DrawingColorMath.contrastRatio(gdi(0x77, 0x77, 0x77), white)
        #expect(abs(ratio - 4.48) < 0.02)
        #expect(ratio < 4.5)   // fails normal AA
    }

    @Test func luminanceBounds() {
        #expect(abs(DrawingColorMath.relativeLuminance(black)) < 1e-9)
        #expect(abs(DrawingColorMath.relativeLuminance(white) - 1) < 1e-9)
    }

    @Test func compositingTranslucentOverBackground() {
        let halfBlack = SceneColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let resolved = DrawingColorMath.composite(halfBlack, over: white)
        #expect(abs(resolved.red - 0.5) < 1e-9 && resolved.alpha == 1)
    }
}

// MARK: - Large-text threshold

@Suite struct LargeTextThresholdTests {

    // #888888 on white is ~3.55:1 — passes AA for large text (3:1), fails for normal (4.5:1).
    @Test func largeTextUsesThreeToOne() {
        let big = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 120, height: 30), points: 20, color: gdi(0x88, 0x88, 0x88))])
        #expect(!big.lowContrastFindings.contains { $0.elementIDs == [1] })
    }

    @Test func normalTextUsesFourAndHalf() {
        let small = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 120, height: 20), points: 10, color: gdi(0x88, 0x88, 0x88))])
        #expect(small.lowContrastFindings.contains { $0.elementIDs == [1] })
    }

    @Test func boldLowersTheLargeThreshold() {
        // 15 pt bold counts as large (≥14 pt bold); 15 pt non-bold does not (<18 pt).
        let config = DrawingAnalysis.Config()
        #expect(DrawingAnalysis.isLargeText(pointSize: 15, bold: true, config: config))
        #expect(!DrawingAnalysis.isLargeText(pointSize: 15, bold: false, config: config))
    }
}

// MARK: - Background detection

@Suite struct BackgroundDetectionTests {

    @Test func textOverFilledRectUsesThatFill() {
        let darkBlue = gdi(0x10, 0x20, 0x80)
        let elements = [
            filledRect(id: 1, CGRect(x: 0, y: 0, width: 400, height: 300), color: darkBlue),
            textRun(id: 2, CGRect(x: 50, y: 50, width: 120, height: 20), points: 12, color: white),
        ]
        let scene = makeScene(elements)
        let bg = DrawingAnalysis.background(forTextIndex: 1, elements: scene.elements, config: .init())
        #expect(bg == darkBlue)
        // White text on a dark-blue background passes; it would fail on the white page.
        #expect(!scene.lowContrastFindings.contains { $0.elementIDs == [2] })
    }

    @Test func whiteTextOnPageFailsContrast() {
        let scene = makeScene([textRun(id: 2, CGRect(x: 50, y: 50, width: 120, height: 20), points: 12, color: white)])
        #expect(scene.lowContrastFindings.contains { $0.elementIDs == [2] })
    }
}

// MARK: - Tiny text

@Suite struct TinyTextTests {

    @Test func sixPointTextIsTiny() {
        let scene = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 80, height: 10), points: 6, color: black)])
        let tiny = scene.findings.first { if case .tinyText = $0.kind { return true } else { return false } }
        #expect(tiny?.elementIDs == [1])
    }

    @Test func tenPointTextIsNotTiny() {
        let scene = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 80, height: 16), points: 10, color: black)])
        #expect(!scene.findings.contains { if case .tinyText = $0.kind { return true } else { return false } })
    }
}

// MARK: - Colour-blind pair

@Suite struct ColorBlindPairTests {

    private func redGreenScene() -> Scene {
        makeScene([
            filledRect(id: 1, CGRect(x: 10, y: 10, width: 50, height: 50), color: gdi(0xCC, 0x00, 0x00)),
            filledRect(id: 2, CGRect(x: 70, y: 10, width: 50, height: 50), color: gdi(0x00, 0x99, 0x00)),
        ])
    }

    @Test func adjacentRedGreenIsFlagged() {
        let pair = redGreenScene().findings.first { if case .colorPair = $0.kind { return true } else { return false } }
        #expect(pair?.elementIDs.sorted() == [1, 2])
    }

    @Test func blackWhitePairIsNotFlagged() {
        // Distinct in normal vision AND under simulation (a luminance difference), so no risk.
        let scene = makeScene([
            filledRect(id: 1, CGRect(x: 10, y: 10, width: 50, height: 50), color: black),
            filledRect(id: 2, CGRect(x: 70, y: 10, width: 50, height: 50), color: white),
        ])
        #expect(!scene.findings.contains { if case .colorPair = $0.kind { return true } else { return false } })
    }

    @Test func distantPairIsNotFlagged() {
        let scene = makeScene([
            filledRect(id: 1, CGRect(x: 0, y: 0, width: 30, height: 30), color: gdi(0xCC, 0x00, 0x00)),
            filledRect(id: 2, CGRect(x: 360, y: 260, width: 30, height: 30), color: gdi(0x00, 0x99, 0x00)),
        ])
        #expect(!scene.findings.contains { if case .colorPair = $0.kind { return true } else { return false } })
    }
}

// MARK: - Unlabelled image

@Suite struct UnlabelledImageTests {

    private func imageElement(id: Int, _ r: CGRect) -> Element {
        let dib = DIB(width: 32, height: 32, bitCount: 24, compression: .rgb, content: .pixels(bytes: Data(count: 32 * 128), stride: 128, palette: []))
        var image = SceneImage(emfPlusImage: EMFPlusImage(version: 1, content: .bitmap(EMFPlusImageBitmapHeader(width: 32, height: 32, stride: 128, pixelFormat: 0, bitmapDataType: 0), data: Data())), destRectDevice: r)
        image.sourceDIB = dib
        image.emfPlusImage = nil
        return Element(id: id, kind: .image, geometryDevice: rectPath(r), transform: .identity, style: SceneStyle(), image: image, provenance: Provenance(sourceRecordIndices: []))
    }

    @Test func imageWithoutNearbyTextIsInfo() {
        let scene = makeScene([imageElement(id: 1, CGRect(x: 160, y: 120, width: 80, height: 60))])
        let finding = scene.findings.first { if case .unlabelledImage = $0.kind { return true } else { return false } }
        #expect(finding?.severity == .low && finding?.elementIDs == [1])
    }

    @Test func imageWithNearbyTextIsNotFlagged() {
        let scene = makeScene([
            imageElement(id: 1, CGRect(x: 160, y: 120, width: 80, height: 60)),
            textRun(id: 2, CGRect(x: 160, y: 185, width: 80, height: 14), points: 12, color: black),
        ])
        #expect(!scene.findings.contains { if case .unlabelledImage = $0.kind { return true } else { return false } })
    }
}

// MARK: - Fix planners

@Suite struct DrawingFixPlannerTests {

    @Test func contrastFixMeetsThresholdWithOneCommand() throws {
        let scene = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 120, height: 20), points: 12, color: gdi(0x99, 0x99, 0x99))])
        let finding = try #require(scene.lowContrastFindings.first)
        let fix = try #require(DrawingFixPlanner.plan(for: finding, in: scene))
        guard case .setFill(let ids, let fill?) = fix.command else { Issue.record("expected one setFill"); return }
        #expect(ids == [1])
        let ratio = DrawingColorMath.contrastRatio(DrawingColorMath.composite(fill.color, over: white), white)
        #expect(ratio >= 4.5 - 1e-6)
        #expect(fix.kind == .darkenText)
    }

    @Test func contrastFixPreservesHue() {
        // A light blue text that must darken to pass; its hue (≈240°) is kept.
        let lightBlue = gdi(0x88, 0x88, 0xDD)
        let before = DrawingColorMath.toHSL(lightBlue).hue
        let after = DrawingFixPlanner.contrastAdjustedColor(text: lightBlue, background: white, required: 4.5)
        #expect(abs(DrawingColorMath.toHSL(after).hue - before) < 2)
        #expect(DrawingColorMath.contrastRatio(after, white) >= 4.5 - 1e-6)
    }

    @Test func tinyTextFixReachesEightPoint() throws {
        let scene = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 80, height: 10), points: 6, color: black)])
        let finding = try #require(scene.findings.first { if case .tinyText = $0.kind { return true } else { return false } })
        let fix = try #require(DrawingFixPlanner.plan(for: finding, in: scene))
        guard case .setFont(let id, let family, let size, _, _) = fix.command else { Issue.record("expected one setFont"); return }
        #expect(id == 1 && family == "Helvetica")
        // Apply and re-check: no tiny finding remains.
        var history = SceneHistory(scene: scene)
        try history.apply(fix.command)
        #expect(!DrawingAnalysis(scene: history.scene).findings.contains { if case .tinyText = $0.kind { return true } else { return false } })
        #expect(Double(size) * 72.0 / 96.0 >= 8)
    }

    @Test func colorPairFixSeparatesUnderSimulation() throws {
        let red = gdi(0xCC, 0x00, 0x00), green = gdi(0x00, 0x99, 0x00)
        let scene = makeScene([
            filledRect(id: 1, CGRect(x: 10, y: 10, width: 50, height: 50), color: red),
            filledRect(id: 2, CGRect(x: 70, y: 10, width: 50, height: 50), color: green),
        ])
        let finding = try #require(scene.findings.first { if case .colorPair = $0.kind { return true } else { return false } })
        let fix = try #require(DrawingFixPlanner.plan(for: finding, in: scene))
        guard case .setFill = fix.command else { Issue.record("expected one setFill"); return }
        var history = SceneHistory(scene: scene)
        try history.apply(fix.command)
        #expect(!DrawingAnalysis(scene: history.scene).findings.contains { if case .colorPair = $0.kind { return true } else { return false } })
    }

    @Test func fixesSkipLockedAndPassthrough() {
        let lockedScene = makeScene([textRun(id: 1, CGRect(x: 10, y: 10, width: 120, height: 20), points: 12, color: gdi(0x99, 0x99, 0x99), locked: true)])
        if let finding = lockedScene.lowContrastFindings.first {
            #expect(DrawingFixPlanner.plan(for: finding, in: lockedScene) == nil)
        }
        // A passthrough filled pair raises no colour-pair finding (rejectsMutation excludes it).
        let passScene = makeScene([
            filledRect(id: 1, CGRect(x: 10, y: 10, width: 50, height: 50), color: gdi(0xCC, 0x00, 0x00), passthrough: true),
            filledRect(id: 2, CGRect(x: 70, y: 10, width: 50, height: 50), color: gdi(0x00, 0x99, 0x00), passthrough: true),
        ])
        #expect(!passScene.findings.contains { if case .colorPair = $0.kind { return true } else { return false } })
    }

    @Test func fixAllIsOneUndoGroup() throws {
        let scene = makeScene([
            textRun(id: 1, CGRect(x: 10, y: 10, width: 120, height: 20), points: 12, color: gdi(0x99, 0x99, 0x99)),
            textRun(id: 2, CGRect(x: 10, y: 60, width: 120, height: 20), points: 12, color: gdi(0xAA, 0xAA, 0xAA)),
        ])
        let contrast = try #require(scene.lowContrastFindings.first)
        let fixes = DrawingFixPlanner.planAll(like: contrast, findings: scene.findings, in: scene)
        #expect(fixes.count == 2)
        var history = SceneHistory(scene: scene)
        try history.performGroup(name: DrawingFixPlanner.fixAllActionName) { h in
            for fix in fixes { try h.apply(fix.command) }
        }
        #expect(history.undoCount == 1)             // one grouped step
        history.undo()
        #expect(history.scene == scene)             // one undo reverts both
    }
}

// MARK: - End-to-end fixture

@Suite struct DrawingAnalysisFixtureTests {

    /// Grey #999999 text at 6 pt on white, plus an adjacent red/green pair.
    private func fixtureScene() -> Scene {
        makeScene([
            textRun(id: 1, CGRect(x: 180, y: 200, width: 120, height: 10), points: 6, color: gdi(0x99, 0x99, 0x99)),
            filledRect(id: 2, CGRect(x: 10, y: 10, width: 50, height: 50), color: gdi(0xCC, 0x00, 0x00)),
            filledRect(id: 3, CGRect(x: 70, y: 10, width: 50, height: 50), color: gdi(0x00, 0x99, 0x00)),
        ])
    }

    @Test func fixtureRaisesTheExpectedFindings() {
        let findings = fixtureScene().findings
        #expect(findings.contains { if case .lowContrast = $0.kind { return true } else { return false } })
        #expect(findings.contains { if case .tinyText = $0.kind { return true } else { return false } })
        #expect(findings.contains { if case .colorPair = $0.kind { return true } else { return false } })
    }

    @Test func applyingEveryFixZeroesTheFindings() throws {
        var history = SceneHistory(scene: fixtureScene())
        // Re-plan against the current scene after each apply, like the UI does.
        var guardCount = 0
        while let finding = DrawingAnalysis(scene: history.scene).findings.first(where: { if case .unlabelledImage = $0.kind { return false } else { return true } }),
              guardCount < 10 {
            guard let fix = DrawingFixPlanner.plan(for: finding, in: history.scene) else { break }
            try history.apply(fix.command)
            guardCount += 1
        }
        let remaining = DrawingAnalysis(scene: history.scene).findings.filter {
            if case .unlabelledImage = $0.kind { return false } else { return true }
        }
        #expect(remaining.isEmpty)
    }

    @Test func contentReportInventory() {
        let report = DrawingAnalysis(scene: fixtureScene()).report
        #expect(report.fonts.contains { $0.family == "Helvetica" })
        #expect(report.textRuns.count == 1)
        #expect(report.kindCounts.contains { $0.kind == .rect && $0.count == 2 })
        #expect(report.colors.contains { $0.role == .text })
    }
}

// MARK: - Analysis conveniences

private extension Scene {
    var findings: [Finding] { DrawingAnalysis(scene: self).findings }
    var lowContrastFindings: [Finding] {
        findings.filter { if case .lowContrast = $0.kind { return true } else { return false } }
    }
}
