#if DEBUG
#if os(macOS)
import AppKit
#endif
import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process AI-edit + recolour screenshots (X2a — REAL output only)
//
// Captures the X2a surfaces into PNGs by hosting the REAL DrawingAIEditView /
// DrawingRecolourView in an offscreen window and using `cacheDisplay` (no Screen
// Recording permission needed). The AI edit is driven by a STUB plan producer (a canned
// EditPlan) so the capture is deterministic and needs no model; the recolour is fully
// deterministic already. Inside `#if DEBUG`, so Release has none of it.
//
//   -EmfyDebugAIEditShots <base-path>
//
// writes <base>-instruction.png, <base>-preview.png, <base>-applied.png,
// <base>-recolour-greyscale.png and <base>-recolour-cvd.png, then exits.
// `-EmfyDebugAIEditFixture <path>` emits the fixture EMF (for the iPad capture) and exits.

enum AIEditScreenshots {
    #if os(macOS)
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if let f = args.firstIndex(of: "-EmfyDebugAIEditFixture"), f + 1 < args.count {
            let path = args[f + 1]
            if let scene = makeScene(), let data = try? SceneExporter.export(scene, as: .emf).data {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
        if let l = args.firstIndex(of: "-EmfyDebugAIEditLive"), l + 1 < args.count {
            let base = args[l + 1]
            Task { @MainActor in
                await captureLive(base: base)
                exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "-EmfyDebugAIEditShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
        }
    }

    /// Runs "Edit with AI" LIVE on the on-device model (no stub) for the real instruction
    /// "make the headings dark blue", up to 3 attempts, logging each raw reply and whether
    /// it decoded + validated, and capturing the resulting preview (or the failure state).
    @MainActor
    private static func captureLive(base: String) async {
        guard let scene = makeScene(), let bytes = try? SceneExporter.export(scene, as: .emf).data else {
            try? "FAIL: fixture".write(toFile: base + "-live-log.txt", atomically: true, encoding: .utf8)
            return
        }
        var log = "Live on-device AI edit — instruction: \"make the headings dark blue\"\n"
        var successes = 0
        let attempts = 3
        var lastModel: DrawingAIEditModel?
        for attempt in 1 ... attempts {
            let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "live.emf" })
            await session.beginEditing()
            let model = DrawingAIEditModel()
            model.configure(session: session)
            model.engineOverride = .onDevice   // force on-device; producer stays nil → real model
            model.instruction = "make the headings dark blue"
            model.submit()
            await wait(timeout: .seconds(120)) {
                switch model.phase { case .preview, .failed, .applied: return true; default: return false }
            }
            let decoded: String
            switch model.phase {
            case .preview: decoded = "DECODED + VALIDATED → preview shown"; successes += 1
            case .failed(let m): decoded = "FAILED: \(m)"
            default: decoded = "phase=\(model.phase)"
            }
            let raw = model.lastRawReply.prefix(800)
            log += "\n--- attempt \(attempt) ---\n\(decoded)\nRAW (<=800 chars):\n\(raw)\n"
            lastModel = model
            if case .preview = model.phase { break }
        }
        log += "\nResult: \(successes)/\(attempts) attempts decoded+validated.\n"
        try? log.write(toFile: base + "-live-log.txt", atomically: true, encoding: .utf8)
        if let model = lastModel {
            _ = capture(view: aiEditShot(model: model), size: NSSize(width: 560, height: 560), to: base + "-live.png")
        }
    }
    #endif

    // MARK: Fixture

    /// A fixture: two grey headings (low contrast), a body run, and a red/green pair — the
    /// same shape as the Check fixture, so the AI "make the headings dark blue and bigger"
    /// edit and a recolour both have something to act on.
    static func makeScene() -> EMFEdit.Scene? {
        guard var scene = try? SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 160))) else { return nil }
        let dup = scene.deviceUnitsPerPoint
        let grey = SceneColor(red: 0.6, green: 0.6, blue: 0.6)
        func addText(_ s: String, _ y: Double, _ pt: Double, _ c: SceneColor) {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeText(string: s, originDevice: CGPoint(x: 40, y: y), family: "Helvetica", pointSize: pt, color: c, id: id, deviceUnitsPerPoint: dup), at: scene.elements.count)
        }
        func addRect(_ r: CGRect, _ c: SceneColor) {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: r, style: SceneStyle(fill: SceneFill(color: c, evenOdd: false), stroke: nil), id: id), at: scene.elements.count)
        }
        addText("Quarterly Results", 80, 20, grey)
        addText("Regional Breakdown", 130, 18, grey)
        addRect(CGRect(x: 40, y: 200, width: 120, height: 120), SceneColor(red: 0.85, green: 0, blue: 0))
        addRect(CGRect(x: 180, y: 200, width: 120, height: 120), SceneColor(red: 0, green: 0.6, blue: 0))
        return scene
    }

    /// The canned plan the stub producer returns: recolour the two headings dark blue and
    /// bump their size — matching "make the headings dark blue and 2pt bigger".
    static func cannedPlan(textIDs: [Int]) -> String {
        let ids = textIDs.map(String.init).joined(separator: ",")
        var ops = "{\"op\":\"recolorFill\",\"ids\":[\(ids)],\"color\":\"#1F3A93\"}"
        for id in textIDs {
            ops += ",{\"op\":\"setFontSize\",\"id\":\(id),\"points\":22}"
        }
        return "{\"operations\":[\(ops)]}"
    }

    // MARK: Capture (macOS offscreen)
    #if os(macOS)

    @MainActor
    private static func captureAll(base: String) async {
        guard let scene = makeScene(), let bytes = try? SceneExporter.export(scene, as: .emf).data else {
            try? "FAIL: could not build fixture".write(toFile: base + "-error.txt", atomically: true, encoding: .utf8)
            return
        }
        let textIDs = scene.editableElements.filter { $0.kind == .text }.map(\.id)

        // --- AI edit: instruction field ---
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "ai-edit-fixture.emf" })
        await session.beginEditing()
        let editModel = DrawingAIEditModel()
        editModel.configure(session: session)
        editModel.producer = { _, _, _ in cannedPlan(textIDs: textIDs) }   // stub: no model
        editModel.instruction = "make the headings dark blue and 2pt bigger"
        _ = capture(view: aiEditShot(model: editModel), size: NSSize(width: 560, height: 320), to: base + "-instruction.png")

        // --- AI edit: preview (driven by the stub plan) ---
        editModel.submit()
        await wait(timeout: .seconds(10)) { editModel.preview != nil }
        _ = capture(view: aiEditShot(model: editModel), size: NSSize(width: 560, height: 560), to: base + "-preview.png")

        // --- AI edit: applied result on the canvas ---
        editModel.apply()
        await wait(timeout: .seconds(5)) { session.editVersion > 1 }
        if let edited = session.editingScene {
            _ = capture(view: CanvasShot(scene: edited), size: NSSize(width: 460, height: 420), to: base + "-applied.png")
        }

        // --- Recolour: greyscale ---
        let greySession = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour-fixture.emf" })
        let greyModel = DrawingRecolourModel()
        await greyModel.start(session: greySession, selection: [])
        greyModel.mode = .greyscale
        await wait(timeout: .seconds(8)) { greyModel.afterImage != nil }
        _ = capture(view: DrawingRecolourView(model: greyModel, onClose: {}), size: NSSize(width: 560, height: 560), to: base + "-recolour-greyscale.png")

        // --- Recolour: colour-blind safe --- (set the mode BEFORE start so there is a
        // single render; otherwise the default-mode render can win the race.)
        let cvdSession = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour-fixture.emf" })
        let cvdModel = DrawingRecolourModel()
        cvdModel.mode = .colourBlindSafe
        await cvdModel.start(session: cvdSession, selection: [])
        await wait(timeout: .seconds(8)) { cvdModel.afterImage != nil }
        _ = capture(view: DrawingRecolourView(model: cvdModel, onClose: {}), size: NSSize(width: 560, height: 560), to: base + "-recolour-cvd.png")

        // --- Recolour scoped to a SELECTION (the editor entry) — header reads "Applies to
        //     1 selected element". ---
        if let firstID = (try? SceneImporter.import(data: bytes))?.editableElements.first?.id {
            let selSession = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour-fixture.emf" })
            let selModel = DrawingRecolourModel()
            selModel.mode = .print
            await selModel.start(session: selSession, selection: [firstID])
            await wait(timeout: .seconds(8)) { selModel.afterImage != nil }
            _ = capture(view: DrawingRecolourView(model: selModel, onClose: {}), size: NSSize(width: 560, height: 560), to: base + "-recolour-selection.png")
        }
    }

    @MainActor private static func aiEditShot(model: DrawingAIEditModel) -> some View {
        DrawingAIEditView(model: model, onClose: {})
            .environment(nil as AIProviderStore?)
            .frame(width: 560)
    }

    // MARK: Helpers

    @MainActor
    private static func wait(timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    @MainActor
    private static func capture<V: View>(view: V, size: NSSize, to path: String) -> Bool {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView else { return false }
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        content.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
    #endif
}

#if os(macOS)
/// A fitted render of a scene, for the applied-result shot.
private struct CanvasShot: View {
    let scene: EMFEdit.Scene
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = SceneRenderer.makeImage(scene, scale: 2) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .shadow(radius: 2)
            }
        }
    }
}
#endif

#if os(iOS)
extension AIEditScreenshots {
    /// Whether the iPad AI-edit/recolour screen was requested at launch.
    static var iosRequested: Bool { ProcessInfo.processInfo.arguments.contains("-EmfyDebugAIEditIOS") }

    /// Presents the REAL Recolour sheet (deterministic) and, when `ai-edit` is passed, the
    /// stub-driven AI edit preview, as a `.sheet` OVER a document backdrop on iPad, for a
    /// `simctl` screenshot that shows the true sheet presentation.
    struct IOSScreen: View {
        @State private var recolour = DrawingRecolourModel()
        @State private var edit = DrawingAIEditModel()
        @State private var backdrop: CGImage?
        @State private var showSheet = false
        private var wantsAI: Bool { ProcessInfo.processInfo.arguments.contains("ai-edit") }

        var body: some View {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                // A faint document backdrop so the sheet reads as presented over the drawing.
                if let backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(60).opacity(0.5)
                }
            }
            .task { await setUp(); showSheet = true }
            .sheet(isPresented: $showSheet) {
                if wantsAI {
                    DrawingAIEditView(model: edit, onClose: {}).environment(nil as AIProviderStore?)
                } else {
                    DrawingRecolourView(model: recolour, onClose: {})
                }
            }
        }

        @MainActor private func setUp() async {
            guard let scene = AIEditScreenshots.makeScene(),
                  let bytes = try? SceneExporter.export(scene, as: .emf).data else { return }
            backdrop = SceneRenderer.makeImage(scene, scale: 2)
            if wantsAI {
                let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "ai.emf" })
                await session.beginEditing()
                edit.configure(session: session)
                edit.engineOverride = .onDevice
                let textIDs = session.editingScene?.editableElements.filter { $0.kind == .text }.map(\.id) ?? []
                edit.producer = { _, _, _ in AIEditScreenshots.cannedPlan(textIDs: textIDs) }
                edit.instruction = "make the headings dark blue and 2pt bigger"
                edit.submit()
                for _ in 0 ..< 100 where edit.preview == nil { try? await Task.sleep(for: .milliseconds(30)) }
            } else {
                let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour.emf" })
                recolour.mode = .colourBlindSafe   // set before start → single render
                await recolour.start(session: session, selection: [])
                for _ in 0 ..< 100 where recolour.afterImage == nil { try? await Task.sleep(for: .milliseconds(30)) }
            }
        }
    }
}
#endif
#endif
