import CoreGraphics

/// Pure initial-zoom choice for the viewer (S1a-4 Viewer › Default zoom on open).
///
/// A file opens Fit (the picture scaled to the viewport) or Actual size (100%,
/// one device pixel per point), per the setting, clamped into the scroll view's
/// magnification range. It's applied only on a genuinely fresh open — the viewer
/// keeps the view (and its zoom) across an identical-content reload (C4a M4), so
/// this never overrides a zoom the user set.
enum ViewerZoomPolicy {
    static func initialScale(
        for setting: EmfySettings.DefaultZoom,
        fit: CGFloat,
        minScale: CGFloat,
        maxScale: CGFloat
    ) -> CGFloat {
        let target: CGFloat = setting == .actualSize ? 1 : fit
        return min(max(target, minScale), maxScale)
    }
}
