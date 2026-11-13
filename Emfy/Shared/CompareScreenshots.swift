#if DEBUG
import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - DEBUG in-process compare-versions screenshots (X1b item 1 — REAL output only)
//
// Hosts the REAL DrawingCompareView against a synthesised baseline + edited scene and
// shoots each mode (side-by-side, overlay, highlight differences) plus the iPad layout,
// using an offscreen window + cacheDisplay (macOS) or a UIGraphicsImageRenderer (iOS),
// so captures need no Screen Recording permission. Inside #if DEBUG only.
//
//   -EmfyDebugCompareShots <base-path>
//
// writes <base>-side-by-side.png, <base>-highlight.png, <base>-overlay.png and, on iOS,
// <base>-ipad.png, then exits.

enum CompareScreenshots {
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugCompareShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
        }
    }

    // MARK: Fixtures

    /// The baseline scene: a heading, a red rectangle and a blue ellipse.
    static func baselineScene() -> EMFEdit.Scene? {
        guard var scene = try? SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 210, height: 297))) else { return nil }
        let dup = scene.deviceUnitsPerPoint
        let black = SceneColor(red: 0, green: 0, blue: 0)
        let textID = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeText(string: "Quarterly report", originDevice: CGPoint(x: 60, y: 90), family: "Helvetica", pointSize: 20, color: black, id: textID, deviceUnitsPerPoint: dup), at: scene.elements.count)
        let rectID = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeShape(kind: .rect, rectDevice: CGRect(x: 60, y: 180, width: 240, height: 150), style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.85, green: 0.1, blue: 0.1), evenOdd: false), stroke: nil), id: rectID), at: scene.elements.count)
        let ellipseID = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeShape(kind: .ellipse, rectDevice: CGRect(x: 360, y: 180, width: 150, height: 150), style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.1, green: 0.35, blue: 0.9), evenOdd: false), stroke: nil), id: ellipseID), at: scene.elements.count)
        return scene
    }

    /// The edited scene: heading re-texted, rectangle moved, ellipse recoloured, one
    /// shape added and the baseline order preserved — so every change kind appears.
    static func editedScene(from baseline: EMFEdit.Scene) -> EMFEdit.Scene? {
        var scene = baseline
        guard let textID = scene.elements.first(where: { $0.kind == .text })?.id,
              let rectID = scene.elements.first(where: { $0.kind == .rect })?.id,
              let ellipseID = scene.elements.first(where: { $0.kind == .ellipse })?.id else { return nil }
        try? scene.setText(textID, "Annual report 2026")
        try? scene.translate([rectID], dx: 40, dy: 70)
        try? scene.setFill([ellipseID], SceneFill(color: SceneColor(red: 0.1, green: 0.7, blue: 0.25), evenOdd: false))
        let newID = SceneFactory.nextElementID(in: scene)
        scene.insert(SceneFactory.makeShape(kind: .roundRect, rectDevice: CGRect(x: 60, y: 420, width: 200, height: 90), style: SceneStyle(fill: SceneFill(color: SceneColor(red: 0.3, green: 0.3, blue: 0.3), evenOdd: false), stroke: nil), id: newID), at: scene.elements.count)
        return scene
    }

    // MARK: Capture

    @MainActor
    private static func captureAll(base: String) async {
        guard let baseline = baselineScene(), let current = editedScene(from: baseline) else {
            write("FAIL: could not build fixtures", to: base + "-error.txt")
            return
        }
        let model = DrawingCompareModel()
        model.compare(current: current, baseline: baseline, baselineLabel: "Opened version")
        await wait(timeout: .seconds(10)) { model.phase == .ready }
        // Select the first changed element so the canvas highlight shows.
        if let changed = model.changes.first(where: { $0.kind == .changed }) {
            model.select(changeID: changed.id)
        }

        model.mode = .sideBySide
        _ = capture(view: compareView(model), size: CGSize(width: 820, height: 560), to: base + "-side-by-side.png")

        model.mode = .highlight
        _ = capture(view: compareView(model), size: CGSize(width: 820, height: 560), to: base + "-highlight.png")

        model.mode = .overlay
        model.onionValue = 0.5
        _ = capture(view: compareView(model), size: CGSize(width: 820, height: 560), to: base + "-overlay.png")
    }

    @MainActor
    private static func compareView(_ model: DrawingCompareModel) -> some View {
        DrawingCompareView(model: model, onClose: {})
    }

    // MARK: Helpers

    @MainActor
    private static func wait(timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private static func write(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    #if os(macOS)
    @MainActor
    private static func capture<V: View>(view: V, size: CGSize, to path: String) -> Bool {
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
    #else
    @MainActor
    private static func capture<V: View>(view: V, size: CGSize, to path: String) -> Bool {
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .systemBackground
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData() else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
    #endif
}

#if os(iOS)
extension CompareScreenshots {
    /// Whether an iPad compare capture was requested (`-EmfyDebugCompareShots <base>`).
    static var iosRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-EmfyDebugCompareShots")
    }

    private static func iosBasePath() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugCompareShots"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The iPad compare screen: the REAL DrawingCompareView against the fixtures, which
    /// shoots itself to `<base>-ipad.png` once ready and exits.
    struct IOSScreen: View {
        @State private var model = DrawingCompareModel()
        var body: some View {
            DrawingCompareView(model: model, onClose: {})
                .task {
                    guard let base = iosBasePath(), let baseline = baselineScene(),
                          let current = editedScene(from: baseline) else { exit(0) }
                    model.compare(current: current, baseline: baseline, baselineLabel: "Opened version")
                    await wait(timeout: .seconds(10)) { model.phase == .ready }
                    if let changed = model.changes.first(where: { $0.kind == .changed }) {
                        model.select(changeID: changed.id)
                    }
                    try? await Task.sleep(for: .milliseconds(600))
                    _ = capture(view: DrawingCompareView(model: model, onClose: {}),
                                size: CGSize(width: 760, height: 640), to: base + "-ipad.png")
                    exit(0)
                }
        }
    }
}
#endif
#endif
