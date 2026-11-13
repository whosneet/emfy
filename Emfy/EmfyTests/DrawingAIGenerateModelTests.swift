import CoreGraphics
import EMFEdit
import Foundation
import Testing

// X2d: the "New Drawing from Description…" view-model, driven by a STUB plan producer (no
// model, no network). Proves the preview state, that a failure creates no document, and that
// an on-device refusal (a blank reply) surfaces the shared plain refusal message. The model
// call is injected (`producer`) and the engine is forced (`engineOverride`), so these run
// anywhere.

@MainActor
private func wait(_ model: DrawingAIGenerateModel, until condition: @escaping () -> Bool) async {
    for _ in 0 ..< 300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private let validPlanJSON = """
{"page":"a4-landscape","coords":"fraction","elements":[
  {"op":"rectangle","x":0.1,"y":0.1,"w":0.2,"h":0.15,"fill":"blue","stroke":"black"},
  {"op":"ellipse","x":0.5,"y":0.5,"w":0.2,"h":0.2,"fill":"red"},
  {"op":"text","x":0.12,"y":0.12,"text":"Start","color":"black","fontSize":16}
]}
"""

@Suite @MainActor struct DrawingAIGenerateModelTests {

    @Test func previewsAGeneratedDrawingWithSummary() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        model.producer = { _, _, _ in validPlanJSON }
        model.descriptionText = "a blue box and a red circle labelled Start"
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        let preview = try #require(model.preview)
        #expect(preview.summary == "2 shapes, 1 text label")
        #expect(preview.image.width > 0 && preview.image.height > 0)
        #expect(!preview.data.isEmpty)
    }

    @Test func createHandsTheBytesToTheHandlerOnce() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        model.producer = { _, _, _ in validPlanJSON }
        model.descriptionText = "a drawing"
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        var createdData: Data?
        model.create { createdData = $0 }
        #expect(createdData != nil)
        #expect(model.phase == .created)
        #expect(model.preview == nil)
        // A second create does nothing (the preview is consumed) — no document is made twice.
        var second: Data?
        model.create { second = $0 }
        #expect(second == nil)
    }

    @Test func failureCreatesNoDocument() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        model.producer = { _, _, _ in "this is not JSON at all" }
        model.descriptionText = "something"
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }

        #expect(model.preview == nil)
        // Create with no preview never calls the handler — nothing is written.
        var createdData: Data?
        model.create { createdData = $0 }
        #expect(createdData == nil)
    }

    @Test func emptyPlanFailsWithoutCreating() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        model.producer = { _, _, _ in #"{"page":"a4-landscape","elements":[]}"# }
        model.descriptionText = "nothing drawable"
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }
        #expect(model.preview == nil)
    }

    @Test func blankReplyShowsTheSharedRefusalMessage() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        // The on-device output guardrail declining returns no usable reply; the user must see
        // a clear message, not a silent failure.
        model.producer = { _, _, _ in "" }
        model.descriptionText = "a flowchart"
        model.submit()
        await wait(model) { if case .failed = model.phase { return true }; return false }

        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)"); return
        }
        #expect(message == DrawingAIEditModel.onDeviceRefusalMessage)
    }

    @Test func honoursTheChosenPage() async throws {
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        // The model declares A4 landscape, but the user picked A4 portrait — the output must
        // use the user's page.
        model.page = .a4Portrait
        model.producer = { _, _, _ in validPlanJSON }
        model.descriptionText = "a box"
        model.submit()
        await wait(model) { if case .preview = model.phase { return true }; return false }

        let preview = try #require(model.preview)
        let scene = try SceneImporter.import(data: preview.data)
        // A4 portrait is taller than it is wide.
        #expect(scene.pageBoundsDevice.height > scene.pageBoundsDevice.width)
    }
}
