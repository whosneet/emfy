import CoreGraphics
import Foundation

/// Pure zoom maths for the Mac tiled viewer (`MacMetafileScrollView`). Extracted
/// from the view so the step zoom, the fit→range derivation, the "was it fitted"
/// test, and the anchor point are unit-tested without an `NSScrollView` (mirrors
/// the way `ViewerFit` is tested). Everything here is CoreGraphics-only, so the
/// tests compile and run on macOS and the iOS simulator.
enum ZoomMath {
    /// Zoom In / Zoom Out move the magnification in multiplicative 25% steps, so a
    /// "step" is the same perceived change across the 2%…800% range (an additive
    /// 25% would jump a tiny fitted picture and crawl near 800%).
    static let zoomStep: CGFloat = 1.25
    /// The ceiling the viewer allows: 800%.
    static let maxZoom: CGFloat = 8
    /// How close the current magnification must sit to the fit scale to count as
    /// "fitted" (so a window resize keeps refitting rather than freezing the zoom).
    static let fitTolerance: CGFloat = 0.01
    /// How many trackpad-equivalent points one mouse-wheel line counts for. A wheel
    /// reports ⌘-scroll deltas in lines (~1 per notch); without this, 1% per notch.
    static let lineScrollPoints: CGFloat = 10

    /// Clamps `value` into `[lo, hi]`, falling back to `lo` for a non-finite input.
    static func clamped(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard value.isFinite else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }

    /// One Zoom In step (× `step`), unclamped — the caller clamps into the scroll
    /// view's current range.
    static func stepIn(from current: CGFloat, step: CGFloat = zoomStep) -> CGFloat {
        guard current.isFinite, current > 0 else { return step }
        return current * step
    }

    /// One Zoom Out step (÷ `step`), unclamped.
    static func stepOut(from current: CGFloat, step: CGFloat = zoomStep) -> CGFloat {
        guard current.isFinite, current > 0, step > 0 else { return 1 }
        return current / step
    }

    /// Whether the picture is currently at the fit scale (within tolerance). Must
    /// be read BEFORE the scroll view's `minMagnification` is reassigned, because
    /// lowering the minimum clamps the live magnification and corrupts the compare.
    static func wasFitted(current: CGFloat, fit: CGFloat, tolerance: CGFloat = fitTolerance) -> Bool {
        abs(current - fit) < tolerance
    }

    /// The scroll view's minimum magnification for a given fit scale: fit, or 100%,
    /// whichever is smaller, so Actual Size is always reachable even when fit > 1
    /// never happens (fit is capped at 1) and a tiny picture can still shrink.
    static func minMagnification(fit: CGFloat) -> CGFloat {
        Swift.min(fit, 1)
    }

    /// The scroll view's maximum magnification: 800%, but never below the fit scale
    /// itself, so the range always contains the current zoom.
    static func maxMagnification(fit: CGFloat) -> CGFloat {
        Swift.max(maxZoom, fit)
    }

    /// The centre of a rectangle — the anchor a button/keyboard zoom keeps fixed
    /// (in the scroll view's content-view coordinate space, per
    /// `setMagnification(_:centeredAt:)`).
    static func visibleCentre(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The new magnification for one ⌘-scroll step. The caller anchors it at the
    /// cursor. `scrollDelta` is vertical scroll (positive = zoom in); the exponential
    /// keeps zoom-in and zoom-out symmetric and never produces a non-positive factor.
    /// A non-precise (mouse wheel) delta is in lines, so it is scaled up by
    /// `lineScrollPoints` to make one notch a meaningful step rather than ~1%.
    static func scrollZoomMagnification(
        current: CGFloat,
        scrollDelta: CGFloat,
        precise: Bool = true,
        sensitivity: CGFloat = 0.01,
        min lo: CGFloat,
        max hi: CGFloat
    ) -> CGFloat {
        guard current.isFinite, current > 0, scrollDelta.isFinite else {
            return clamped(current, min: lo, max: hi)
        }
        let delta = precise ? scrollDelta : scrollDelta * lineScrollPoints
        let factor = CGFloat(exp(Double(delta * sensitivity)))
        return clamped(current * factor, min: lo, max: hi)
    }

    /// The number of `CATiledLayer` levels of detail to maintain for a page whose
    /// longest side (in points) is `longSide`. `bias` magnified levels keep zoom-in
    /// crisp (4 → 16×, enough for 800% on a 2× display); below the base, enough
    /// reduced levels are added that the coarsest level draws the whole page at a
    /// long side of about `coarsestLongSide` — so a huge page renders a small,
    /// cheap tile at fit instead of a 1/8-resolution giant. The total is clamped
    /// to `minLevels…maxLevels`.
    static func tiledLevelsOfDetail(
        forLongSide longSide: CGFloat,
        bias: Int = 4,
        coarsestLongSide: CGFloat = 256,
        minLevels: Int = 4,
        maxLevels: Int = 14
    ) -> Int {
        let safeLong = longSide.isFinite && longSide > 0 ? longSide : coarsestLongSide
        let ratio = Swift.max(1, safeLong / Swift.max(1, coarsestLongSide))
        let reduced = Swift.max(0, Int(ceil(log2(Double(ratio)))))
        let total = bias + 1 + reduced
        return Swift.min(Swift.max(total, minLevels), maxLevels)
    }
}
