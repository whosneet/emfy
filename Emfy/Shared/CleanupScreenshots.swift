#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - DEBUG in-process clean-up screenshots (X1b item 2 — REAL output only)
//
// Hosts the REAL DrawingCleanupView against a hand-built EMF that carries one of each
// redundancy kind plus an EMF+ comment, and shoots the report (counts + sizes), the
// size before/after and the compatibility warning, using an offscreen window +
// cacheDisplay (macOS) or UIGraphicsImageRenderer (iOS). Inside #if DEBUG only.
//
//   -EmfyDebugCleanupShots <base-path>  →  <base>-report.png (+ <base>-ipad.png on iOS)

enum CleanupScreenshots {
    static func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugCleanupShots"), i + 1 < args.count else { return }
        let base = args[i + 1]
        Task { @MainActor in
            await captureAll(base: base)
            exit(0)
        }
    }

    @MainActor
    private static func captureAll(base: String) async {
        let model = DrawingCleanupModel()
        model.analyse(data: fixtureEMF())
        await wait(timeout: .seconds(10)) { model.phase == .ready }
        _ = capture(view: view(model), size: CGSize(width: 520, height: 640), to: base + "-report.png")

        // The unsaved-changes state: both save actions blocked, with the "save first" note.
        let dirty = DrawingCleanupModel()
        dirty.analyse(data: fixtureEMF(), hasUnsavedChanges: true)
        await wait(timeout: .seconds(10)) { dirty.phase == .ready }
        _ = capture(view: view(dirty), size: CGSize(width: 520, height: 640), to: base + "-dirty.png")
    }

    @MainActor
    private static func view(_ model: DrawingCleanupModel) -> some View {
        DrawingCleanupView(model: model, fileName: "diagram.emf", onClose: {})
    }

    @MainActor
    private static func wait(timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    // MARK: - Fixture (an EMF with one of each redundancy + an EMF+ comment)

    static func fixtureEMF() -> Data {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func lei32(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func record(_ type: UInt32, _ body: [UInt8]) -> [UInt8] { le32(type) + le32(UInt32(8 + body.count)) + body }
        func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [r, g, b, 0] }

        var header: [UInt8] = []
        header += le32(1) + le32(88)
        header += lei32(0) + lei32(0) + lei32(100) + lei32(100)
        header += lei32(0) + lei32(0) + lei32(2645) + lei32(2645)
        header += le32(0x464D4520) + le32(0x00010000)
        header += le32(0) + le32(0)                     // nBytes, nRecords (patched)
        header += le16(8) + le16(0)
        header += le32(0) + le32(0) + le32(0)
        header += le32(100) + le32(100) + le32(26) + le32(26)

        var records: [[UInt8]] = [header]
        records.append(record(39, le32(0) + le32(0) + color(40, 90, 200) + le32(0)))                    // CreateBrush ih=0 blue
        records.append(record(37, le32(0)))                                                             // SelectObject ih=0
        records.append(record(43, lei32(0) + lei32(0) + lei32(80) + lei32(80)))                         // Rectangle
        records.append(record(33, []))                                                                  // SaveDC
        records.append(record(34, lei32(-1)))                                                           // RestoreDC (empty pair)
        records.append(record(38, le32(3) + le32(0) + lei32(1) + lei32(0) + color(0, 0, 0)))            // CreatePen ih=3 (unused)
        records.append(record(24, color(0, 0, 0)))                                                      // SetTextColor
        records.append(record(24, color(0, 0, 0)))                                                      // SetTextColor (redundant)
        records.append(record(40, le32(9)))                                                             // DeleteObject ih=9 (dangling)
        records.append(record(70, le32(8) + le32(0x2B464D45) + le32(0)))                                // Comment EMF+
        records.append(record(14, le32(0) + le32(0) + le32(20)))                                        // EOF

        var bytes = records.flatMap { $0 }
        func patch(_ at: Int, _ v: [UInt8]) { for (i, b) in v.enumerated() { bytes[at + i] = b } }
        patch(48, le32(UInt32(bytes.count)))
        patch(52, le32(UInt32(records.count)))
        return Data(bytes)
    }

    // MARK: - Capture

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
extension CleanupScreenshots {
    static var iosRequested: Bool { ProcessInfo.processInfo.arguments.contains("-EmfyDebugCleanupShots") }

    private static func iosBasePath() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugCleanupShots"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    struct IOSScreen: View {
        @State private var model = DrawingCleanupModel()
        var body: some View {
            DrawingCleanupView(model: model, fileName: "diagram.emf", onClose: {})
                .task {
                    guard let base = iosBasePath() else { exit(0) }
                    model.analyse(data: fixtureEMF())
                    await wait(timeout: .seconds(10)) { model.phase == .ready }
                    try? await Task.sleep(for: .milliseconds(500))
                    _ = capture(view: DrawingCleanupView(model: model, fileName: "diagram.emf", onClose: {}),
                                size: CGSize(width: 560, height: 700), to: base + "-ipad.png")
                    exit(0)
                }
        }
    }
}
#endif
#endif
