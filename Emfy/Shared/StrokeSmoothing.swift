import CoreGraphics
import EMFEdit
import Foundation

/// Clean-room freehand-stroke smoothing (E3b design call 2). A raw pointer/Pencil
/// drag is a noisy polyline; this turns it into a compact piecewise cubic Bézier
/// `ScenePath` in DEVICE units, so a committed stroke is a smooth vector curve that
/// exports and re-imports as a path ([MS-EMF] has no analytic "freehand" record).
///
/// Pressure and tilt are IGNORED for geometry: an EMF stroke has a constant pen
/// width, so only the (x, y) sample positions shape the curve.
///
/// Three pure, tested stages:
///  1. drop samples closer than `minSpacing` (de-dupe pointer jitter);
///  2. Ramer–Douglas–Peucker simplify at `rdpTolerance` (shed near-collinear runs);
///  3. fit a Catmull-Rom spline and convert each segment to a cubic Bézier, whose
///     shared knot tangents give G1 (in fact C1) continuity through the interior.
enum StrokeSmoothing {
    /// A §8 cap on the raw sample count: a hostile or stuck input can never allocate an
    /// unbounded curve. Beyond this many points the input is uniformly decimated to the
    /// cap before any processing.
    static let maxRawSamples = 10_000

    /// Smooths raw device-space sample points into a cubic-Bézier `ScenePath`.
    static func smooth(devicePoints raw: [CGPoint], minSpacing: CGFloat, rdpTolerance: CGFloat) -> ScenePath {
        let capped = decimated(raw, to: maxRawSamples)
        let spaced = dropCloseSamples(capped, minSpacing: max(0, minSpacing))
        let simplified = douglasPeucker(spaced, tolerance: max(0, rdpTolerance))
        return fitCubicBezier(through: simplified)
    }

    /// Uniformly decimates `points` to at most `cap` samples, keeping the first and last.
    static func decimated(_ points: [CGPoint], to cap: Int) -> [CGPoint] {
        guard cap >= 2, points.count > cap else { return points }
        var out: [CGPoint] = []
        out.reserveCapacity(cap)
        let step = Double(points.count - 1) / Double(cap - 1)
        for i in 0 ..< cap { out.append(points[Int((Double(i) * step).rounded())]) }
        return out
    }

    /// Drops each intermediate sample within `minSpacing` of the last kept one. The very
    /// first and last samples are always kept, so the stroke's extent never shrinks.
    static func dropCloseSamples(_ points: [CGPoint], minSpacing: CGFloat) -> [CGPoint] {
        guard points.count > 2, minSpacing > 0 else { return points }
        var kept: [CGPoint] = [points[0]]
        for p in points[1 ..< (points.count - 1)] {
            if let last = kept.last, hypot(p.x - last.x, p.y - last.y) >= minSpacing { kept.append(p) }
        }
        kept.append(points[points.count - 1])
        return kept
    }

    /// Ramer–Douglas–Peucker polyline simplification: recursively keep the point of
    /// greatest perpendicular distance from the chord while it exceeds `tolerance`.
    static func douglasPeucker(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifySegment(points, 0, points.count - 1, tolerance, &keep)
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private static func simplifySegment(_ pts: [CGPoint], _ lo: Int, _ hi: Int, _ tol: CGFloat, _ keep: inout [Bool]) {
        guard hi > lo + 1 else { return }
        var maxDist: CGFloat = -1
        var idx = lo
        for i in (lo + 1) ..< hi {
            let d = perpendicularDistance(pts[i], from: pts[lo], to: pts[hi])
            if d > maxDist { maxDist = d; idx = i }
        }
        if maxDist > tol {
            keep[idx] = true
            simplifySegment(pts, lo, idx, tol, &keep)
            simplifySegment(pts, idx, hi, tol, &keep)
        }
    }

    /// Perpendicular distance from `p` to the infinite line through a→b (point distance
    /// when a == b).
    static func perpendicularDistance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-12 else { return hypot(p.x - a.x, p.y - a.y) }
        let cross = (p.x - a.x) * dy - (p.y - a.y) * dx
        return abs(cross) / len2.squareRoot()
    }

    /// Fits a Catmull-Rom spline through `points` and emits it as cubic Béziers. Fewer
    /// than two points draw nothing; exactly two make a straight line.
    static func fitCubicBezier(through points: [CGPoint]) -> ScenePath {
        guard points.count >= 2 else {
            if let p = points.first { return ScenePath(segments: [.move(p)]) }
            return ScenePath()
        }
        if points.count == 2 { return ScenePath(segments: [.move(points[0]), .line(points[1])]) }
        var segments: [ScenePath.Segment] = [.move(points[0])]
        let n = points.count
        for i in 0 ..< n - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(n - 1, i + 2)]
            // Catmull-Rom → Bézier control points (tension 0): the tangent at p1 is
            // (p2 - p0)/2 and at p2 is (p3 - p1)/2, so adjacent segments SHARE a tangent
            // vector at their common knot → C1 (hence G1) continuity.
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            segments.append(.cubicCurve(to: p2, control1: c1, control2: c2))
        }
        return ScenePath(segments: segments)
    }
}
