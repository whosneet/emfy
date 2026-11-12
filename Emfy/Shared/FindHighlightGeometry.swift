import CoreGraphics

// MARK: - Find highlight geometry (F3b)
//
// The pure mapping behind the find overlay on both platforms. A `DrawingTextFind.Match`
// carries DEVICE-space bounds (the drawing's own y-down coordinates); the overlay draws
// in VIEW space (the paper/canvas the scene is fitted into). This helper is the single,
// tested bridge: it maps the matches' device rects into view rects through the same
// `EditorCanvasMapping` the viewer and editor already use, flags the current match, and
// computes the union + the zoom a too-large match needs. No UIKit/AppKit, so it tests on
// any platform.

enum FindHighlightGeometry {

    /// The distinct VIEW-space rects to fill for `matches`, mapped through `mapping`.
    /// Several occurrences in one run share one device rect (and so one view rect), so
    /// duplicates collapse — the translucent fill is drawn once per highlighted region.
    /// Null/empty-bounds matches (unknown geometry) are dropped.
    static func allViewRects(_ matches: [DrawingTextFind.Match], mapping: EditorCanvasMapping) -> [CGRect] {
        var seen: [CGRect] = []
        for match in matches where !match.boundsDevice.isNull && !match.boundsDevice.isEmpty {
            let rect = mapping.viewRect(fromDevice: match.boundsDevice).standardized
            if !seen.contains(where: { approxEqual($0, rect) }) { seen.append(rect) }
        }
        return seen
    }

    /// The current match's VIEW-space rect (drawn stronger and outlined), or nil when
    /// there is no current match or its bounds are unknown.
    static func currentViewRect(_ matches: [DrawingTextFind.Match], current: Int?, mapping: EditorCanvasMapping) -> CGRect? {
        guard let current, matches.indices.contains(current) else { return nil }
        let device = matches[current].boundsDevice
        guard !device.isNull, !device.isEmpty else { return nil }
        return mapping.viewRect(fromDevice: device).standardized
    }

    /// The DEVICE-space bounds of a single match, usable for scroll-into-view; nil when
    /// the match index is out of range or the bounds are unknown.
    static func matchDeviceRect(_ matches: [DrawingTextFind.Match], current: Int?) -> CGRect? {
        guard let current, matches.indices.contains(current) else { return nil }
        let device = matches[current].boundsDevice
        return (device.isNull || device.isEmpty) ? nil : device.standardized
    }

    /// The zoom a match should drop to so its whole mapped view rect fits inside
    /// `viewport` (with a small margin), or nil when the match already fits at
    /// `currentZoom`. Used to zoom out before scrolling a match larger than the viewport
    /// into view. The result is clamped to `[minZoom, currentZoom]` — this never zooms
    /// IN, only out, and never past the viewer's own minimum.
    static func zoomToFit(
        deviceRect: CGRect,
        mapping: EditorCanvasMapping,
        viewport: CGSize,
        currentZoom: CGFloat,
        minZoom: CGFloat,
        margin: CGFloat = 24
    ) -> CGFloat? {
        let viewRect = mapping.viewRect(fromDevice: deviceRect).standardized
        guard viewRect.width > 0, viewRect.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        // The match occupies `viewRect * currentZoom` points on screen; it fits when that
        // is inside the viewport minus the margin on each side.
        let availW = max(viewport.width - margin * 2, 1)
        let availH = max(viewport.height - margin * 2, 1)
        let onScreenW = viewRect.width * currentZoom
        let onScreenH = viewRect.height * currentZoom
        guard onScreenW > availW || onScreenH > availH else { return nil }
        let target = min(availW / viewRect.width, availH / viewRect.height)
        return max(min(target, currentZoom), minZoom)
    }

    /// Two rects equal within half a point, so sub-pixel rounding of the same device
    /// bounds through the mapping doesn't produce near-duplicate highlight fills.
    private static func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}
