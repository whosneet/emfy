#if DEBUG
#if os(macOS)
import AppKit
#endif
import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process translate-in-place screenshots (X2c — REAL output only)
//
// Captures the X2c Translate surfaces into PNGs by hosting the REAL DrawingAITranslateView
// in an offscreen window and using `cacheDisplay` (no Screen Recording permission needed).
// The preview is driven by a STUB batch producer (a canned French translation parsed from
// the batch block) so the capture is deterministic and needs no model; a LIVE variant runs
// the on-device model instead. Inside `#if DEBUG`, so Release has none of it.
//
//   -EmfyDebugTranslateShots <base-path>   → <base>-picker.png, <base>-preview.png, <base>-applied.png
//   -EmfyDebugTranslateLive  <base-path>   → a LIVE on-device EN→FR preview + log
//   -EmfyDebugTranslateFixture <path>      → emits the fixture EMF (for the iPad/iPhone capture)

enum TranslateScreenshots {
    /// A fixture: three English runs (a heading and two body lines) so Translate has text to
    /// act on and the before/after preview shows a clear change.
    static func makeScene() -> EMFEdit.Scene? {
        guard var scene = try? SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 160))) else { return nil }
        let dup = scene.deviceUnitsPerPoint
        let dark = SceneColor(red: 0.1, green: 0.1, blue: 0.1)
        func addText(_ s: String, _ y: Double, _ pt: Double) {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeText(string: s, originDevice: CGPoint(x: 40, y: y), family: "Helvetica", pointSize: pt, color: dark, id: id, deviceUnitsPerPoint: dup), at: scene.elements.count)
        }
        addText("Welcome to the annual report", 80, 20)
        addText("Revenue increased this year", 140, 13)
        addText("Thank you for your support", 190, 13)
        return scene
    }

    /// The canned French translation the stub returns: parse the ids from the batch block and
    /// map each to a fixed French phrase, so the preview is deterministic without a model.
    static func cannedFrench(block: String) -> String {
        let phrases = [
            "Bienvenue au rapport annuel",
            "Les revenus ont augmenté cette année",
            "Merci de votre soutien",
        ]
        let ids = block.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("#") else { return nil }
            return Int(line.dropFirst().prefix { $0.isNumber })
        }
        let entries = ids.enumerated().map { index, id in
            "{\"id\":\(id),\"text\":\"\(phrases[index % phrases.count])\"}"
        }.joined(separator: ",")
        return "{\"translations\":[\(entries)]}"
    }

    #if os(macOS)
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if let f = args.firstIndex(of: "-EmfyDebugTranslateFixture"), f + 1 < args.count {
            if let scene = makeScene(), let data = try? SceneExporter.export(scene, as: .emf).data {
                try? data.write(to: URL(fileURLWithPath: args[f + 1]))
            }
            exit(0)
        }
        if let l = args.firstIndex(of: "-EmfyDebugTranslateLive"), l + 1 < args.count {
            let base = args[l + 1]
            Task { @MainActor in await captureLive(base: base); exit(0) }
            return
        }
        guard let i = args.firstIndex(of: "-EmfyDebugTranslateShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in await captureAll(base: base); exit(0) }
    }

    @MainActor
    private static func captureAll(base: String) async {
        guard let scene = makeScene(), let bytes = try? SceneExporter.export(scene, as: .emf).data else {
            try? "FAIL: could not build fixture".write(toFile: base + "-error.txt", atomically: true, encoding: .utf8)
            return
        }
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "translate-fixture.emf" })
        let model = DrawingAITranslateModel()
        model.engineOverride = .onDevice
        await model.prepare(session: session, selection: [])
        model.targetLanguage = TranslationLanguages.all.first { $0.code == "fr" } ?? model.targetLanguage
        model.producer = { _, block, _, _ in cannedFrench(block: block) }   // stub: no model

        // --- Language picker (input form) ---
        _ = capture(view: shot(model: model), size: NSSize(width: 560, height: 300), to: base + "-picker.png")

        // --- Preview (driven by the stub translation) ---
        model.submit()
        await wait(timeout: .seconds(10)) { model.preview != nil }
        _ = capture(view: shot(model: model), size: NSSize(width: 560, height: 600), to: base + "-preview.png")

        // --- Applied result on the canvas ---
        model.apply()
        await wait(timeout: .seconds(5)) { session.editVersion > 1 }
        if let edited = session.editingScene {
            _ = capture(view: CanvasShot(scene: edited), size: NSSize(width: 460, height: 380), to: base + "-applied.png")
        }
    }

    /// Runs Translate LIVE on the on-device model (no stub) EN→FR, up to 3 attempts, logging
    /// each raw reply and whether it decoded + reconciled, and capturing the resulting preview.
    @MainActor
    private static func captureLive(base: String) async {
        guard let scene = makeScene(), let bytes = try? SceneExporter.export(scene, as: .emf).data else {
            try? "FAIL: fixture".write(toFile: base + "-live-log.txt", atomically: true, encoding: .utf8)
            return
        }
        // The target language is overridable for an RTL (Arabic) render check.
        let langCode = ProcessInfo.processInfo.environment["EMFY_TRANSLATE_LANG"] ?? "fr"
        let langName = TranslationLanguages.all.first { $0.code == langCode }?.englishName ?? "French"
        var log = "Live on-device translate — EN→\(langName), 3-run fixture\n"
        var successes = 0
        var lastModel: DrawingAITranslateModel?
        for attempt in 1 ... 3 {
            let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "live.emf" })
            let model = DrawingAITranslateModel()
            model.engineOverride = .onDevice   // real model (producer stays nil)
            await model.prepare(session: session, selection: [])
            model.targetLanguage = TranslationLanguages.all.first { $0.code == langCode } ?? model.targetLanguage
            model.submit()
            await wait(timeout: .seconds(120)) {
                switch model.phase { case .preview, .failed, .applied: return true; default: return false }
            }
            let outcome: String
            switch model.phase {
            case .preview: outcome = "DECODED + RECONCILED → preview shown"; successes += 1
            case .failed(let m): outcome = "FAILED: \(m)"
            default: outcome = "phase=\(model.phase)"
            }
            log += "\n--- attempt \(attempt) ---\n\(outcome)\nRAW (<=800 chars):\n\(model.lastRawReply.prefix(800))\n"
            lastModel = model
            if case .preview = model.phase { break }
        }
        log += "\nResult: \(successes)/3 attempts decoded+reconciled.\n"
        try? log.write(toFile: base + "-live-log.txt", atomically: true, encoding: .utf8)
        if let model = lastModel {
            _ = capture(view: shot(model: model), size: NSSize(width: 560, height: 600), to: base + "-live.png")
        }
    }

    @MainActor private static func shot(model: DrawingAITranslateModel) -> some View {
        DrawingAITranslateView(model: model, onClose: {})
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
/// A fitted render of a scene, for the applied-result shot.
private struct TranslateCanvasShot: View {
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

private typealias CanvasShot = TranslateCanvasShot
#endif

#if os(iOS)
extension TranslateScreenshots {
    /// Whether the iPad/iPhone Translate screen was requested at launch.
    static var iosRequested: Bool { ProcessInfo.processInfo.arguments.contains("-EmfyDebugTranslateIOS") }

    /// Presents the REAL Translate sheet over a document backdrop as a `.sheet`, for a
    /// `simctl` screenshot that shows the true sheet presentation. Stub-driven so it needs
    /// no model; pass `preview` to show the before/after preview instead of the picker.
    struct IOSScreen: View {
        @State private var model = DrawingAITranslateModel()
        @State private var backdrop: CGImage?
        @State private var showSheet = false
        private var wantsPreview: Bool { ProcessInfo.processInfo.arguments.contains("preview") }

        var body: some View {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if let backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(60).opacity(0.5)
                }
            }
            .task { await setUp(); showSheet = true }
            .sheet(isPresented: $showSheet) {
                DrawingAITranslateView(model: model, onClose: {}).environment(nil as AIProviderStore?)
            }
        }

        @MainActor private func setUp() async {
            guard let scene = TranslateScreenshots.makeScene(),
                  let bytes = try? SceneExporter.export(scene, as: .emf).data else { return }
            backdrop = SceneRenderer.makeImage(scene, scale: 2)
            let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "translate.emf" })
            model.engineOverride = .onDevice
            await model.prepare(session: session, selection: [])
            model.targetLanguage = TranslationLanguages.all.first { $0.code == "fr" } ?? model.targetLanguage
            model.producer = { _, block, _, _ in TranslateScreenshots.cannedFrench(block: block) }
            if wantsPreview {
                model.submit()
                for _ in 0 ..< 100 where model.preview == nil { try? await Task.sleep(for: .milliseconds(30)) }
            }
        }
    }
}
#endif
#endif
