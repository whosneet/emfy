#if DEBUG
#if os(macOS)
import AppKit
#endif
import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process "generate a drawing" screenshots (X2d — REAL output only)
//
// Captures the X2d "New Drawing from Description…" surfaces into PNGs by hosting the REAL
// DrawingAIGenerateView in an offscreen window and using `cacheDisplay` (no Screen Recording
// permission needed). The preview is driven by a STUB plan producer (a canned flowchart
// GenerationPlan) so the capture is deterministic and needs no model; a LIVE variant runs the
// on-device model instead. Inside `#if DEBUG`, so Release has none of it.
//
//   -EmfyDebugGenerateShots <base>  → <base>-sheet.png, <base>-preview.png, <base>-created.png, <base>-refusal.png
//   -EmfyDebugGenerateLive  <base>  → a LIVE on-device generated preview + log
//   -EmfyDebugGenerateIOS           → the iPad/iPhone sheet in its real .sheet presentation

enum GenerateScreenshots {
    /// The canned flowchart plan the stub returns: three boxes connected by two arrows,
    /// labelled Start / Process / End — the brief's own live-eval prompt.
    static let cannedFlowchart = """
    {"page":"a4-landscape","coords":"fraction","elements":[
      {"op":"roundedRectangle","x":0.05,"y":0.4,"w":0.2,"h":0.16,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},
      {"op":"roundedRectangle","x":0.4,"y":0.4,"w":0.2,"h":0.16,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},
      {"op":"roundedRectangle","x":0.75,"y":0.4,"w":0.2,"h":0.16,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},
      {"op":"arrow","x1":0.25,"y1":0.48,"x2":0.4,"y2":0.48,"stroke":"black","strokeWidth":3},
      {"op":"arrow","x1":0.6,"y1":0.48,"x2":0.75,"y2":0.48,"stroke":"black","strokeWidth":3},
      {"op":"text","x":0.1,"y":0.46,"text":"Start","color":"dark blue","fontSize":18},
      {"op":"text","x":0.44,"y":0.46,"text":"Process","color":"dark blue","fontSize":18},
      {"op":"text","x":0.81,"y":0.46,"text":"End","color":"dark blue","fontSize":18}
    ]}
    """

    #if os(macOS)
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if let l = args.firstIndex(of: "-EmfyDebugGenerateLive"), l + 1 < args.count {
            let base = args[l + 1]
            Task { @MainActor in await captureLive(base: base); exit(0) }
            return
        }
        guard let i = args.firstIndex(of: "-EmfyDebugGenerateShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in await captureAll(base: base); exit(0) }
    }

    @MainActor
    private static func captureAll(base: String) async {
        // --- Input sheet (description + page) ---
        let sheetModel = DrawingAIGenerateModel()
        sheetModel.engineOverride = .onDevice
        sheetModel.descriptionText = "a simple flowchart with three boxes connected by arrows, labelled Start, Process, End"
        _ = capture(view: shot(model: sheetModel), size: NSSize(width: 560, height: 360), to: base + "-sheet.png")

        // --- Preview (driven by the stub plan) ---
        let model = DrawingAIGenerateModel()
        model.engineOverride = .onDevice
        model.producer = { _, _, _ in cannedFlowchart }
        model.descriptionText = "a simple flowchart with three boxes connected by arrows, labelled Start, Process, End"
        model.submit()
        await wait(timeout: .seconds(10)) { model.preview != nil }
        _ = capture(view: shot(model: model), size: NSSize(width: 560, height: 600), to: base + "-preview.png")

        // --- Created document rendered on the canvas ---
        if let data = model.preview?.data, let scene = try? SceneImporter.import(data: data) {
            _ = capture(view: CanvasShot(scene: scene), size: NSSize(width: 520, height: 380), to: base + "-created.png")
        }

        // --- Refusal message (the on-device guardrail declines → a blank reply) ---
        let refusalModel = DrawingAIGenerateModel()
        refusalModel.engineOverride = .onDevice
        refusalModel.producer = { _, _, _ in "" }
        refusalModel.descriptionText = "a flowchart"
        refusalModel.submit()
        await wait(timeout: .seconds(10)) { if case .failed = refusalModel.phase { return true }; return false }
        _ = capture(view: shot(model: refusalModel), size: NSSize(width: 560, height: 320), to: base + "-refusal.png")
    }

    /// Runs generation LIVE on the on-device model (no stub) for the flowchart prompt, up to
    /// 3 attempts, logging each raw reply and whether it decoded + validated, and capturing
    /// the resulting preview (or the failure state).
    @MainActor
    private static func captureLive(base: String) async {
        let prompt = "a simple flowchart with three boxes connected by arrows, labelled Start, Process, End"
        var log = "Live on-device generate — description: \"\(prompt)\"\n"
        var successes = 0
        var lastModel: DrawingAIGenerateModel?
        for attempt in 1 ... 3 {
            let model = DrawingAIGenerateModel()
            model.engineOverride = .onDevice   // real model (producer stays nil)
            model.descriptionText = prompt
            model.submit()
            await wait(timeout: .seconds(120)) {
                switch model.phase { case .preview, .failed, .created: return true; default: return false }
            }
            let outcome: String
            switch model.phase {
            case .preview: outcome = "DECODED + VALIDATED → preview shown (\(model.preview?.summary ?? ""))"; successes += 1
            case .failed(let m): outcome = "FAILED: \(m)"
            default: outcome = "phase=\(model.phase)"
            }
            log += "\n--- attempt \(attempt) ---\n\(outcome)\nRAW (<=1000 chars):\n\(model.lastRawReply.prefix(1000))\n"
            lastModel = model
            if case .preview = model.phase { break }
        }
        log += "\nResult: \(successes)/3 attempts decoded+validated.\n"
        try? log.write(toFile: base + "-live-log.txt", atomically: true, encoding: .utf8)
        if let model = lastModel {
            _ = capture(view: shot(model: model), size: NSSize(width: 560, height: 600), to: base + "-live.png")
        }
    }

    @MainActor private static func shot(model: DrawingAIGenerateModel) -> some View {
        DrawingAIGenerateView(model: model, onCreate: { _ in }, onClose: {})
            .environment(nil as AIProviderStore?)
            .frame(width: 560)
    }

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
/// A fitted render of a scene, for the created-document shot.
private struct GenerateCanvasShot: View {
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

private typealias CanvasShot = GenerateCanvasShot
#endif

#if os(iOS)
extension GenerateScreenshots {
    /// Whether the iPad/iPhone generate screen was requested at launch.
    static var iosRequested: Bool { ProcessInfo.processInfo.arguments.contains("-EmfyDebugGenerateIOS") }

    /// Presents the REAL generate sheet over a faint backdrop as a `.sheet`, for a `simctl`
    /// screenshot that shows the true sheet presentation. Stub-driven, so it needs no model;
    /// pass `preview` to show the generated preview instead of the input form.
    struct IOSScreen: View {
        @State private var model = DrawingAIGenerateModel()
        @State private var showSheet = false
        private var wantsPreview: Bool { ProcessInfo.processInfo.arguments.contains("preview") }

        var body: some View {
            ZStack { Color(.systemGroupedBackground).ignoresSafeArea() }
                .task { await setUp(); showSheet = true }
                .sheet(isPresented: $showSheet) {
                    DrawingAIGenerateView(model: model, onCreate: { _ in }, onClose: {})
                        .environment(nil as AIProviderStore?)
                }
        }

        @MainActor private func setUp() async {
            model.engineOverride = .onDevice
            model.descriptionText = "a simple flowchart with three boxes connected by arrows, labelled Start, Process, End"
            model.producer = { _, _, _ in GenerateScreenshots.cannedFlowchart }
            if wantsPreview {
                model.submit()
                for _ in 0 ..< 100 where model.preview == nil { try? await Task.sleep(for: .milliseconds(30)) }
            }
        }
    }
}
#endif
#endif
