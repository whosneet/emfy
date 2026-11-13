import CoreGraphics
import EMFEdit
import Foundation
import Testing

// X1a tests for the accessibility Check: the analysis cache key, that a fix is one
// undo and clears its finding on re-analysis, that "fix all" is one undo group, that a
// fix is never applied without a confirmed preview, and that the AI summary prompt is
// built ONLY from the data-only summary block (no raw drawing text).

// MARK: - Fixture

/// A scene carrying the brief's accessibility problems: two grey #999999 text runs on
/// white (low contrast), one 6 pt run (tiny text), and an adjacent red/green fill pair
/// (colour-only distinction). Built in-code through `SceneFactory`, so the findings are
/// deterministic.
@MainActor
private func makeCheckFixtureScene() throws -> Scene {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 297)))
    let dup = scene.deviceUnitsPerPoint
    let grey = SceneColor(red: 0.6, green: 0.6, blue: 0.6)   // #999999
    let black = SceneColor(red: 0, green: 0, blue: 0)

    func addText(_ string: String, y: Double, pt: Double, color: SceneColor) {
        let id = SceneFactory.nextElementID(in: scene)
        let element = SceneFactory.makeText(
            string: string, originDevice: CGPoint(x: 40, y: y), family: "Helvetica",
            pointSize: pt, color: color, id: id, deviceUnitsPerPoint: dup)
        scene.insert(element, at: scene.elements.count)
    }
    func addRect(_ rect: CGRect, color: SceneColor) {
        let id = SceneFactory.nextElementID(in: scene)
        let style = SceneStyle(fill: SceneFill(color: color, evenOdd: false), stroke: nil)
        scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: rect, style: style, id: id), at: scene.elements.count)
    }

    addText("Low contrast grey heading", y: 80, pt: 14, color: grey)
    addText("Low contrast grey body copy", y: 120, pt: 14, color: grey)
    addText("Tiny six point footnote", y: 170, pt: 6, color: black)
    addRect(CGRect(x: 40, y: 240, width: 120, height: 120), color: SceneColor(red: 0.85, green: 0, blue: 0))
    addRect(CGRect(x: 170, y: 240, width: 120, height: 120), color: SceneColor(red: 0, green: 0.6, blue: 0))
    return scene
}

@MainActor
private func makeEditingSession(bytes: Data) -> DocumentSession {
    DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "fixture.emf" })
}

private func lowContrastFindings(_ analysis: DrawingAnalysis) -> [Finding] {
    analysis.findings.filter { if case .lowContrast = $0.kind { return true }; return false }
}

@Suite struct DrawingCheckTests {

// MARK: - Cache key

@Test
func checkCacheKeyReadOnlyIgnoresEditVersion() {
    let a = DrawingCheckModel.cacheKey(editing: false, editVersion: 5, contentID: 42)
    let b = DrawingCheckModel.cacheKey(editing: false, editVersion: 99, contentID: 42)
    #expect(a == b)
    #expect(a != DrawingCheckModel.cacheKey(editing: false, editVersion: 5, contentID: 7))
}

@Test
func checkCacheKeyEditingTracksEditVersion() {
    let a = DrawingCheckModel.cacheKey(editing: true, editVersion: 5, contentID: 42)
    let b = DrawingCheckModel.cacheKey(editing: true, editVersion: 6, contentID: 42)
    #expect(a != b)
    // Editing vs read-only are distinct even at the same numbers.
    #expect(DrawingCheckModel.cacheKey(editing: true, editVersion: 5, contentID: 42)
        != DrawingCheckModel.cacheKey(editing: false, editVersion: 5, contentID: 42))
}

// MARK: - The fixture produces the expected findings

@Test @MainActor
func fixtureProducesContrastAndTinyFindings() throws {
    let analysis = DrawingAnalysis(scene: try makeCheckFixtureScene())
    #expect(lowContrastFindings(analysis).count == 2)
    #expect(analysis.findings.contains { if case .tinyText = $0.kind { return true }; return false })
}

// MARK: - A fix is one undo and clears its finding

@Test @MainActor
func contrastFixIsOneUndoAndClearsTheFinding() async throws {
    let bytes = try SceneExporter.export(makeCheckFixtureScene(), as: .emf).data
    let session = makeEditingSession(bytes: bytes)
    await session.beginEditing()
    let scene = try #require(session.editingScene)

    let analysis = DrawingAnalysis(scene: scene)
    let finding = try #require(lowContrastFindings(analysis).first)
    let fix = try #require(DrawingFixPlanner.plan(for: finding, in: scene))
    let targetID = try #require(finding.elementIDs.first)

    let undoBefore = session.undoManager.canUndo
    session.apply(fix.command)
    #expect(!undoBefore)                       // no undo before the fix
    #expect(session.undoManager.canUndo)       // exactly one undo after

    let after = DrawingAnalysis(scene: try #require(session.editingScene))
    #expect(!after.findings.contains { finding in
        if case .lowContrast = finding.kind { return finding.elementIDs.contains(targetID) }
        return false
    })

    // One undo restores the original low-contrast finding.
    session.undoManager.undo()
    let reverted = DrawingAnalysis(scene: try #require(session.editingScene))
    #expect(lowContrastFindings(reverted).contains { $0.elementIDs.contains(targetID) })
    #expect(!session.undoManager.canUndo)
}

// MARK: - Fix all is one undo group

@Test @MainActor
func fixAllOfAKindIsOneUndoGroup() async throws {
    let bytes = try SceneExporter.export(makeCheckFixtureScene(), as: .emf).data
    let session = makeEditingSession(bytes: bytes)
    await session.beginEditing()
    let scene = try #require(session.editingScene)

    let analysis = DrawingAnalysis(scene: scene)
    let finding = try #require(lowContrastFindings(analysis).first)
    let plans = DrawingFixPlanner.planAll(like: finding, findings: analysis.findings, in: scene)
    #expect(plans.count == 2)

    session.applyGroupedCommands(plans.map(\.command), name: DrawingFixPlanner.fixAllActionName)
    let after = DrawingAnalysis(scene: try #require(session.editingScene))
    #expect(lowContrastFindings(after).isEmpty)       // both fixed

    // One undo step reverses the WHOLE batch.
    #expect(session.undoManager.canUndo)
    session.undoManager.undo()
    #expect(!session.undoManager.canUndo)
    let reverted = DrawingAnalysis(scene: try #require(session.editingScene))
    #expect(lowContrastFindings(reverted).count == 2)
}

// MARK: - No apply without a confirmed preview

@Test @MainActor
func noFixAppliesWithoutAConfirmedPreview() async throws {
    let bytes = try SceneExporter.export(makeCheckFixtureScene(), as: .emf).data
    let session = makeEditingSession(bytes: bytes)
    await session.beginEditing()
    let versionBefore = session.editVersion

    let model = DrawingCheckModel()
    model.configure(session: session, dataProvider: { bytes }, contentID: 1)
    // No beginFix/beginFixAll has run, so nothing is pending.
    #expect(model.pendingFix == nil)
    await model.confirmPendingFix()
    // Confirming with nothing pending mutates nothing.
    #expect(session.editVersion == versionBefore)
    #expect(!session.undoManager.canUndo)
}

// MARK: - The summary prompt uses summaryData() only

@Test @MainActor
func summaryPromptUsesDataOnlyBlock() throws {
    let analysis = DrawingAnalysis(scene: try makeCheckFixtureScene())
    let data = analysis.summaryData()
    let prompt = DrawingAIPrompt.summariseCheckPrompt(data: data)

    #expect(prompt.contains(data))
    // The data block, and therefore the prompt, carry NO raw drawing text.
    #expect(!data.contains("Low contrast grey heading"))
    #expect(!prompt.contains("Tiny six point footnote"))

    let request = AIProviderRequestBuilder.summariseCheck(data: data, model: "test-model")
    #expect(request.userPrompt == prompt)
    #expect(request.tools.isEmpty)
    #expect(request.system == DrawingAIPrompt.structuredInstructions)
}

}
