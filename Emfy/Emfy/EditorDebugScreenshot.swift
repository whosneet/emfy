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

    /// Composites every visible app window (the library window plus any popover, which
    /// is its own child window) into one PNG, so an E2c text-edit popover appears in the
    /// shot — `cacheDisplay` of a single window never includes a separate popover
    /// window. Still permission-free. Returns whether it wrote.
    @MainActor
    @discardableResult
    static func captureAllWindows(to path: String) -> Bool {
        var captured: [(rect: NSRect, rep: NSBitmapImageRep)] = []
        // All windows, lowest level first, so a popover (a higher-level child window not
        // in `orderedWindows`) composites over the library window.
        let windows = NSApp.windows.filter { $0.isVisible }.sorted { $0.level.rawValue < $1.level.rawValue }
        for window in windows {
            guard let view = window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            // Note: `cacheDisplay` renders SwiftUI-hosted content in the light drawing
            // appearance regardless of the window's appearance (the standard sidebar
            // renders light in a dark window too), so a faithful DARK capture isn't
            // possible here; force light via `-EmfyDebugAppearance light` for a clean shot.
            view.cacheDisplay(in: bounds, to: rep)
            let screenRect = window.convertToScreen(view.convert(bounds, to: nil))
            captured.append((screenRect, rep))
        }
        guard let first = captured.first else { return false }
        var union = first.rect
        for item in captured.dropFirst() { union = union.union(item.rect) }
        guard union.width > 0, union.height > 0 else { return false }

        let image = NSImage(size: union.size)
        image.lockFocus()
        for item in captured {
            let origin = NSPoint(x: item.rect.minX - union.minX, y: item.rect.minY - union.minY)
            item.rep.draw(in: NSRect(origin: origin, size: item.rect.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
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
