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
        guard let i = args.firstIndex(of: "-EmfyDebugAIEditShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
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

        // --- Recolour: colour-blind safe ---
        let cvdSession = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "recolour-fixture.emf" })
        let cvdModel = DrawingRecolourModel()
        await cvdModel.start(session: cvdSession, selection: [])
        cvdModel.mode = .colourBlindSafe
        await wait(timeout: .seconds(8)) { cvdModel.afterImage != nil }
        _ = capture(view: DrawingRecolourView(model: cvdModel, onClose: {}), size: NSSize(width: 560, height: 560), to: base + "-recolour-cvd.png")
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

    /// Shows the REAL Recolour sheet (deterministic) and, when `-EmfyDebugAIEditWhich ai`
    /// is passed, the stub-driven AI edit preview, hosted on iPad for a `simctl` screenshot.
    struct IOSScreen: View {
        @State private var recolour = DrawingRecolourModel()
        @State private var edit = DrawingAIEditModel()
        @State private var ready = false
        private var wantsAI: Bool { ProcessInfo.processInfo.arguments.contains("ai-edit") }

        var body: some View {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if ready {
                    if wantsAI, edit.preview != nil {
                        DrawingAIEditView(model: edit, onClose: {}).environment(nil as AIProviderStore?)
                    } else {
                        DrawingRecolourView(model: recolour, onClose: {})
                    }
                }
            }
            .task { await setUp() }
        }

        @MainActor private func setUp() async {
            guard let scene = AIEditScreenshots.makeScene(),
                  let bytes = try? SceneExporter.export(scene, as: .emf).data else { return }
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
                await recolour.start(session: session, selection: [])
                recolour.mode = .colourBlindSafe
                for _ in 0 ..< 100 where recolour.afterImage == nil { try? await Task.sleep(for: .milliseconds(30)) }
            }
            ready = true
        }
    }
}
#endif
#endif
