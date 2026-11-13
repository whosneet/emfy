import CoreGraphics
import EMFEdit
import Foundation
import Testing

// X2c: the Translate-in-place view-model, driven by a STUB batch producer (no model, no
// network). Proves id mapping, that unknown/duplicate/missing ids are rejected with no
// mutation, that Apply is one grouped undo, overflow flagging, and selection scope. The
// model call is injected (`producer`) and the engine is forced (`engineOverride`), so these
// run anywhere.

@MainActor
private func makeTranslateFixtureScene(_ lines: [String] = ["Hello world", "Good morning", "Thank you"]) throws -> Scene {
    var scene = try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 160)))
    let dup = scene.deviceUnitsPerPoint
    let grey = SceneColor(red: 0.4, green: 0.4, blue: 0.4)
    for (i, line) in lines.enumerated() {
        let id = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeText(string: line, originDevice: CGPoint(x: 40, y: 80 + Double(i) * 40), family: "Helvetica", pointSize: 16, color: grey, id: id, deviceUnitsPerPoint: dup), at: scene.elements.count)
    }
    return scene
}

@MainActor
private func fixtureBytes(_ lines: [String] = ["Hello world", "Good morning", "Thank you"]) throws -> Data {
    try SceneExporter.export(try makeTranslateFixtureScene(lines), as: .emf).data
}

@MainActor
private func makeSession(_ bytes: Data) -> DocumentSession {
    DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "translate.emf" })
}

@MainActor
private func wait(_ model: DrawingAITranslateModel, until condition: @escaping () -> Bool) async {
    for _ in 0 ..< 300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The element ids listed in one fenced batch block (lines like `#12: "…"`).
private func ids(inBlock block: String) -> [Int] {
    block.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("#") else { return nil }
        return Int(line.dropFirst().prefix { $0.isNumber })
    }
}

private func translationsJSON(_ pairs: [(Int, String)]) -> String {
    let entries = pairs.map { "{\"id\":\($0.0),\"text\":\"\($0.1)\"}" }.joined(separator: ",")
    return "{\"translations\":[\(entries)]}"
}

@MainActor
private func readyModel(_ session: DocumentSession, selection: Set<Int> = []) async -> DrawingAITranslateModel {
    let model = DrawingAITranslateModel()
    model.engineOverride = .onDevice
    await model.prepare(session: session, selection: selection)
    return model
}

@Suite @MainActor struct DrawingAITranslateModelTests {

    @Test func mapsEachReturnedIDToItsRun() async throws {
        let bytes = try fixtureBytes()
        let session = makeSession(bytes)
        let model = await readyModel(session)
        // The stub translates every requested id to a short distinct token "LANG<id>".
        model.producer = { _, block, _, _ in translationsJSON(ids(inBlock: block).map { ($0, "x\($0)") }) }
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        let preview = try #require(model.preview)
        #expect(preview.changes.count == 3)
        #expect(session.isDirty == false)   // preview alone never mutates
        model.apply()
        let scene = try #require(session.editingScene)
        for element in scene.editableElements where element.kind == .text {
            #expect(element.text?.string == "x\(element.id)")
        }
    }

    @Test func rejectsAMissingIDWithoutMutation() async throws {
        let bytes = try fixtureBytes()
        let session = makeSession(bytes)
        let model = await readyModel(session)
        // Drop the last requested id → reconcile fails (missingID), nothing applies.
        model.producer = { _, block, _, _ in translationsJSON(ids(inBlock: block).dropLast().map { ($0, "x\($0)") }) }
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }

        if case .failed = model.phase {} else { Issue.record("expected .failed, got \(model.phase)") }
        #expect(model.preview == nil)
        #expect(session.isDirty == false)
        #expect(session.undoManager.canUndo == false)
    }

    @Test func rejectsAnExtraIDWithoutMutation() async throws {
        let bytes = try fixtureBytes()
        let session = makeSession(bytes)
        let model = await readyModel(session)
        model.producer = { _, block, _, _ in translationsJSON(ids(inBlock: block).map { ($0, "x\($0)") } + [(987654, "ghost")]) }
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }

        if case .failed = model.phase {} else { Issue.record("expected .failed") }
        #expect(session.isDirty == false)
    }

    @Test func rejectsADuplicateIDWithoutMutation() async throws {
        let bytes = try fixtureBytes()
        let session = makeSession(bytes)
        let model = await readyModel(session)
        model.producer = { _, block, _, _ in
            let all = ids(inBlock: block)
            guard let first = all.first else { return "{}" }
            return translationsJSON(all.map { ($0, "x\($0)") } + [(first, "dup")])
        }
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }

        if case .failed = model.phase {} else { Issue.record("expected .failed") }
        #expect(session.isDirty == false)
    }

    @Test func applyIsOneGroupedUndo() async throws {
        let originals = ["Hello world", "Good morning", "Thank you"]
        let bytes = try fixtureBytes(originals)
        let session = makeSession(bytes)
        let model = await readyModel(session)
        model.producer = { _, block, _, _ in translationsJSON(ids(inBlock: block).map { ($0, "x\($0)") }) }
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        model.apply()
        #expect(session.isDirty == true)
        #expect(session.undoManager.canUndo == true)

        // One undo restores EVERY run's original text.
        session.undoManager.undo()
        let scene = try #require(session.editingScene)
        let restored = Set(scene.editableElements.compactMap { $0.text?.string })
        #expect(restored == Set(originals))
    }

    @Test func flagsOverflowForAMuchWiderTranslation() async throws {
        let bytes = try fixtureBytes(["Hi", "OK", "Go"])
        let session = makeSession(bytes)
        let model = await readyModel(session)
        // Translate each short run to a much longer string → the first flags overflow.
        model.producer = { _, block, _, _ in
            translationsJSON(ids(inBlock: block).map { ($0, "this is a far longer translated phrase than the original") })
        }
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        let preview = try #require(model.preview)
        #expect(preview.overflowCount >= 1)
        #expect(preview.changes.contains { $0.overflow })
        #expect(preview.notes.contains { $0.contains("wider") })
    }

    @Test func scopesToTheSelectedTextRun() async throws {
        var scene = try makeTranslateFixtureScene()
        let bytes = try SceneExporter.export(scene, as: .emf).data
        let session = makeSession(bytes)
        // Select only the first text run.
        await session.beginEditing()
        scene = try #require(session.editingScene)
        let firstTextID = try #require(scene.editableElements.first { $0.kind == .text }?.id)

        let model = DrawingAITranslateModel()
        model.engineOverride = .onDevice
        await model.prepare(session: session, selection: [firstTextID])
        var requestedIDs: [Int] = []
        model.producer = { _, block, _, _ in
            requestedIDs = ids(inBlock: block)
            return translationsJSON(requestedIDs.map { ($0, "x\($0)") })
        }
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }
        model.apply()

        // Only the selected run was sent and changed; the others keep their original text.
        #expect(requestedIDs == [firstTextID])
        let edited = try #require(session.editingScene)
        #expect(edited.elements.first { $0.id == firstTextID }?.text?.string == "x\(firstTextID)")
        let others = edited.editableElements.filter { $0.kind == .text && $0.id != firstTextID }
        #expect(others.allSatisfy { !($0.text?.string.hasPrefix("x") ?? true) })
    }
}
