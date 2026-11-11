#if DEBUG
import AppKit

/// DEBUG-only in-process window capture for E2b screenshots (design call E2b-8).
/// `screencapture -l` needs Screen Recording permission, which a headless build
/// agent doesn't have; `cacheDisplay` renders the view hierarchy (including the
/// CATiledLayer scene and the selection overlay) straight to a bitmap, needing no
/// permission. Compiled out of Release entirely (macOS only).
enum EditorDebugScreenshot {
    /// Writes a PNG of the library window's content view to `path`, at the backing
    /// scale. Returns whether it wrote.
    @MainActor
    @discardableResult
    static func captureLibraryWindow(to path: String) -> Bool {
        guard let window = libraryWindow(), let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The main library window: the largest visible non-panel window. With the
    /// What's New popup suppressed during a debug run, this is unambiguous.
    @MainActor
    private static func libraryWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && ($0.contentView?.bounds.height ?? 0) > 200 }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }
}
#endif
