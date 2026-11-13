#if DEBUG && os(macOS)
import AppKit
import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI

// MARK: - DEBUG in-process accessibility-Check screenshots (X1a — REAL output only)
//
// Captures the X1a Check surfaces — the content report + findings with a finding
// selected and outlined on the canvas, the low-contrast fix preview, the post-fix
// zero-findings state, and the LIVE AI summary — into PNGs by hosting the REAL
// DrawingCheckView / FixPreviewSheet in an offscreen window and using `cacheDisplay`,
// so they can be shot with no Screen Recording permission. All state is driven live
// against a synthesised fixture (grey #999999 text, 6 pt text, an adjacent red/green
// pair). Inside `#if DEBUG`, so Release has none of it.
//
//   -EmfyDebugCheckShots <base-path>
//
// writes <base>-report.png, <base>-fix-preview.png, <base>-fixed.png and
// <base>-summary.png, then exits.

enum CheckScreenshots {
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        // Emit the fixture EMF to a path (for the iPad Simulator capture), then exit.
        if let f = args.firstIndex(of: "-EmfyDebugCheckFixture"), f + 1 < args.count {
            let path = args[f + 1]
            if let scene = makeScene(), let data = try? SceneExporter.export(scene, as: .emf).data {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
        guard let i = args.firstIndex(of: "-EmfyDebugCheckShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
        }
    }

    // MARK: Fixture

    /// The X1a fixture scene: two grey #999999 runs (low contrast), one 6 pt run (tiny),
    /// and an adjacent red/green fill pair (colour-only distinction).
    static func makeScene() -> EMFEdit.Scene? {
        guard var scene = try? SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 297))) else { return nil }
        let dup = scene.deviceUnitsPerPoint
        let grey = SceneColor(red: 0.6, green: 0.6, blue: 0.6)
        let black = SceneColor(red: 0, green: 0, blue: 0)
        func addText(_ s: String, _ y: Double, _ pt: Double, _ c: SceneColor) {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeText(string: s, originDevice: CGPoint(x: 40, y: y), family: "Helvetica", pointSize: pt, color: c, id: id, deviceUnitsPerPoint: dup), at: scene.elements.count)
        }
        func addRect(_ r: CGRect, _ c: SceneColor) {
            let id = SceneFactory.nextElementID(in: scene)
            scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: r, style: SceneStyle(fill: SceneFill(color: c, evenOdd: false), stroke: nil), id: id), at: scene.elements.count)
        }
        addText("Low contrast grey heading", 90, 15, grey)
        addText("Low contrast grey body copy", 130, 14, grey)
        addText("Tiny six point footnote", 175, 6, black)
        addRect(CGRect(x: 40, y: 230, width: 130, height: 130), SceneColor(red: 0.85, green: 0, blue: 0))
        addRect(CGRect(x: 185, y: 230, width: 130, height: 130), SceneColor(red: 0, green: 0.6, blue: 0))
        return scene
    }

    // MARK: Capture

    @MainActor
    private static func captureAll(base: String) async {
        guard let scene = makeScene(), let bytes = try? SceneExporter.export(scene, as: .emf).data else {
            try? "FAIL: could not build fixture".write(toFile: base + "-error.txt", atomically: true, encoding: .utf8)
            return
        }

        // Drive the model against the fixture, read-only path.
        let session = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "accessibility-fixture.emf" })
        let model = DrawingCheckModel()
        let summarise = DrawingSummariseModel()
        model.configure(session: session, dataProvider: { bytes }, contentID: 1)
        model.refreshIfNeeded()
        await wait(timeout: .seconds(10)) { model.analysis != nil }

        // (a) Report + findings, with the first low-contrast finding selected + outlined.
        let contrastID = model.findings.first { if case .lowContrast = $0.kind { return true }; return false }?.id
        if let contrastID { model.select(findingID: contrastID) }
        _ = capture(view: reportShot(scene: scene, model: model, summarise: summarise),
                    size: NSSize(width: 760, height: 560), to: base + "-report.png")

        // (b) The low-contrast fix preview (before/after).
        if let contrastID {
            model.beginFix(findingID: contrastID)
            await wait(timeout: .seconds(10)) { model.pendingFix != nil }
            if let fix = model.pendingFix {
                _ = capture(view: FixPreviewSheet(fix: fix, onApply: {}, onCancel: {}),
                            size: NSSize(width: 500, height: 420), to: base + "-fix-preview.png")
            }
            model.cancelPendingFix()
        }

        // (c) After every fix: zero findings, canvas updated. Driven exactly like the real
        // flow — enter edit mode, apply every kind's fixes through DocumentSession (one
        // grouped undo each), then re-analyse the in-memory edited scene (no save round-trip,
        // so the contrast fix's full-precision colour is preserved and the finding clears).
        let fixedSession = DocumentSession(entryID: UUID(), resolve: { _ in bytes }, documentFileName: { "accessibility-fixture.emf" })
        await fixedSession.beginEditing()
        applyAllFixes(in: fixedSession)
        let fixedModel = DrawingCheckModel()
        fixedModel.configure(session: fixedSession, dataProvider: { bytes }, contentID: 1)
        fixedModel.refreshIfNeeded()
        await wait(timeout: .seconds(10)) { fixedModel.analysis != nil }
        if let fixedScene = fixedSession.editingScene {
            _ = capture(view: reportShot(scene: fixedScene, model: fixedModel, summarise: DrawingSummariseModel()),
                        size: NSSize(width: 760, height: 560), to: base + "-fixed.png")
        }

        // (e) The live AI summary.
        let status = DrawingAIAvailability.current()
        if status.isAvailable, let data = model.summaryData {
            summarise.summarise(key: model.analysisVersion, data: data)
            await wait(timeout: .seconds(90)) {
                switch summarise.phase { case .done, .failed: return true; default: return false }
            }
            try? summarise.text.write(toFile: base + "-summary.txt", atomically: true, encoding: .utf8)
            if let contrastID { model.select(findingID: contrastID) }
            _ = capture(view: summaryShot(model: model, summarise: summarise),
                        size: NSSize(width: 420, height: 420), to: base + "-summary.png")
        } else {
            try? "AI unavailable: \(status)".write(toFile: base + "-summary-unavailable.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Applies every planned fix of every kind through the editing session (one grouped
    /// undo per kind), exactly as "Fix all of this kind" does, so the "fixed" capture
    /// shows zero findings.
    @MainActor
    private static func applyAllFixes(in session: DocumentSession) {
        guard let scene = session.editingScene else { return }
        let analysis = DrawingAnalysis(scene: scene)
        var seenKinds = Set<Int>()
        func rank(_ f: Finding) -> Int {
            switch f.kind { case .lowContrast: return 0; case .tinyText: return 1; case .colorPair: return 2; case .unlabelledImage: return 3 }
        }
        for finding in analysis.findings where seenKinds.insert(rank(finding)).inserted {
            let commands = DrawingFixPlanner.planAll(like: finding, findings: analysis.findings, in: scene).map(\.command)
            session.applyGroupedCommands(commands, name: DrawingFixPlanner.fixAllActionName)
        }
    }

    // MARK: Composite views

    /// The report + findings panel beside the fitted canvas with the selected finding
    /// outlined, exactly as the shipping viewer shows it.
    @MainActor private static func reportShot(scene: EMFEdit.Scene, model: DrawingCheckModel, summarise: DrawingSummariseModel) -> some View {
        HStack(spacing: 0) {
            CheckCanvasShot(scene: scene, highlight: model.highlight)
                .frame(width: 380)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            DrawingCheckView(model: model, summariseModel: summarise, onExport: {})
                .frame(width: 380)
        }
    }

    /// The AI summary surface, driven by the completed live stream.
    @MainActor private static func summaryShot(model: DrawingCheckModel, summarise: DrawingSummariseModel) -> some View {
        DrawingCheckView(model: model, summariseModel: summarise, onExport: {})
            .frame(width: 420)
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
}

/// A fitted render of a scene with the selected-finding outlines drawn on top, reusing
/// the viewer's translucent-fill-plus-outline highlight style.
private struct CheckCanvasShot: View {
    let scene: EMFEdit.Scene
    let highlight: FindHighlightSet

    var body: some View {
        GeometryReader { geo in
            let page = scene.pageBoundsDevice
            let scale = min(geo.size.width / max(page.width, 1), geo.size.height / max(page.height, 1)) * 0.92
            let drawn = CGSize(width: page.width * scale, height: page.height * scale)
            let origin = CGPoint(x: (geo.size.width - drawn.width) / 2, y: (geo.size.height - drawn.height) / 2)
            ZStack(alignment: .topLeading) {
                if let image = SceneRenderer.makeImage(scene, scale: 2) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .shadow(radius: 2)
                }
                ForEach(Array(highlight.matchDeviceRects.enumerated()), id: \.offset) { _, rect in
                    let f = CGRect(
                        x: origin.x + (rect.minX - page.minX) * scale,
                        y: origin.y + (rect.minY - page.minY) * scale,
                        width: rect.width * scale, height: rect.height * scale)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: f.width + 8, height: f.height + 8)
                        .position(x: f.midX, y: f.midY)
                }
            }
        }
    }
}
#endif
