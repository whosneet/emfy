import CoreGraphics
import EMFParse
import Foundation

/// Geometry-record → CGPath construction. Paths are built in LOGICAL
/// coordinates with the full logical→target transform applied at construction
/// time (via the CGPath `transform:` parameters), so the renderer never sets
/// a CTM — pen widths stay under explicit control (see StrokeMapper).
enum PathBuilder {

    static func cgPoint(_ p: PointL) -> CGPoint {
        CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    static func cgPoint(_ p: PointS) -> CGPoint {
        CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// The continuous CGRect for an inclusive-inclusive logical RectL,
    /// normalised so hostile unordered corners (right < left) cannot produce
    /// negative sizes. GDI normalises the rectangle for Rectangle/Ellipse
    /// drawing the same way.
    static func cgRect(_ r: RectL) -> CGRect {
        let x0 = Double(min(r.left, r.right))
        let x1 = Double(max(r.left, r.right))
        let y0 = Double(min(r.top, r.bottom))
        let y1 = Double(max(r.top, r.bottom))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: - Poly paths

    /// One closed polygon subpath. Fewer than 2 points draws nothing (GDI
    /// no-op) and appends nothing.
    static func appendPolygon(_ points: [CGPoint], to path: CGMutablePath, transform: CGAffineTransform) {
        guard points.count >= 2, let first = points.first else { return }
        path.move(to: first, transform: transform)
        for point in points.dropFirst() {
            path.addLine(to: point, transform: transform)
        }
        path.closeSubpath()
    }

    /// One open polyline subpath; same degenerate rule.
    static func appendPolyline(_ points: [CGPoint], to path: CGMutablePath, transform: CGAffineTransform) {
        guard points.count >= 2, let first = points.first else { return }
        path.move(to: first, transform: transform)
        for point in points.dropFirst() {
            path.addLine(to: point, transform: transform)
        }
    }

    // MARK: - Bezier validation ([MS-EMF] §2.3.5.16/.18)

    /// How much of a poly-bezier record's point array is well-formed.
    ///
    /// Plain variants carry a start point plus control-control-end triples:
    /// a valid count is ≡ 1 (mod 3). The …To variants start from the current
    /// position and carry triples only: a valid count is ≡ 0 (mod 3). Any
    /// other count renders the largest well-formed prefix and logs.
    struct BezierShape: Equatable {
        /// Number of leading points that form complete curves.
        var usableCount: Int
        /// True when the record's count was not well-formed and a suffix was
        /// dropped (including a zero-point plain record, which lacks even its
        /// start point).
        var isMalformed: Bool
    }

    static func bezierShape(pointCount: Int, continuesFromCurrentPosition: Bool) -> BezierShape {
        if continuesFromCurrentPosition {
            return BezierShape(
                usableCount: pointCount - pointCount % 3,
                isMalformed: pointCount % 3 != 0
            )
        }
        guard pointCount >= 1 else {
            return BezierShape(usableCount: 0, isMalformed: true)
        }
        return BezierShape(
            usableCount: 1 + (pointCount - 1) / 3 * 3,
            isMalformed: pointCount % 3 != 1
        )
    }

    /// Appends the cubic curves of a plain poly-bezier: `points[0]` is the
    /// start, then control-control-end triples. `points.count` must already
    /// be a well-formed prefix (1 + 3k).
    static func appendBezier(_ points: [CGPoint], to path: CGMutablePath, transform: CGAffineTransform) {
        guard let first = points.first, points.count >= 4 else { return }
        path.move(to: first, transform: transform)
        appendBezierTriples(points.dropFirst(), to: path, transform: transform)
    }

    /// Appends control-control-end triples continuing an already-started
    /// subpath (the caller has done the `move`). Count must be a multiple
    /// of 3.
    static func appendBezierTriples<S: Collection>(
        _ points: S,
        to path: CGMutablePath,
        transform: CGAffineTransform
    ) where S.Element == CGPoint {
        var iterator = points.makeIterator()
        while let control1 = iterator.next() {
            guard let control2 = iterator.next(), let end = iterator.next() else { return }
            path.addCurve(to: end, control1: control1, control2: control2, transform: transform)
        }
    }

    // MARK: - Rounded rectangle (EMR_ROUNDRECT §2.3.5.35)

    /// The Corner SizeL is the WIDTH and HEIGHT of the rounding ellipse, so
    /// the per-corner radii are half of each — clamped into what the box can
    /// carry, because CGPath's addRoundedRect has a hard precondition that
    /// each corner radius is at most half the box side (a hostile corner
    /// value would trap).
    static func appendRoundRect(
        box: RectL,
        corner: SizeL,
        to path: CGMutablePath,
        transform: CGAffineTransform
    ) {
        let rect = cgRect(box)
        guard rect.width > 0, rect.height > 0 else {
            path.addRect(rect, transform: transform)
            return
        }
        let cornerWidth = min(abs(Double(corner.cx)) / 2, rect.width / 2)
        let cornerHeight = min(abs(Double(corner.cy)) / 2, rect.height / 2)
        if cornerWidth > 0, cornerHeight > 0 {
            path.addRoundedRect(
                in: rect,
                cornerWidth: cornerWidth,
                cornerHeight: cornerHeight,
                transform: transform
            )
        } else {
            path.addRect(rect, transform: transform)
        }
    }

    // MARK: - Elliptical arc (EMR_ARC §2.3.5.2)

    /// Appends the arc of the ellipse inscribed in `box`, from the radial
    /// through `start` to the radial through `end`, sweeping counterclockwise
    /// as seen on screen — the default arc direction ([MS-EMF] §2.3.5.2:
    /// drawing "MUST proceed counterclockwise" unless EMR_SETARCDIRECTION,
    /// which is outside the phase-2 set, changed it).
    ///
    /// Logical space is y-down, so "counterclockwise on screen" is the
    /// direction of DECREASING parameter angle θ where a point on the ellipse
    /// is (cx + rx·cosθ, cy + ry·sinθ). Radial endpoints map to parameter
    /// angles via θ = atan2(dy/ry, dx/rx), which normalises the anisotropic
    /// radii. Equal start/end radials draw the full ellipse (GDI behaviour).
    ///
    /// The curve is emitted as cubic segments of at most 90° using the
    /// standard 4/3·tan(Δ/4) control-point construction — CG's own
    /// `addArc(clockwise:)` flag semantics under flipped coordinate systems
    /// are a documented trap, and explicit cubics keep the math auditable.
    static func appendArc(
        box: RectL,
        start: PointL,
        end: PointL,
        to path: CGMutablePath,
        transform: CGAffineTransform
    ) {
        let rect = cgRect(box)
        let rx = rect.width / 2
        let ry = rect.height / 2
        // Degenerate ellipse: nothing visible, and rx/ry are divisors below.
        guard rx > 0, ry > 0 else { return }
        let cx = rect.midX
        let cy = rect.midY

        func parameterAngle(_ p: PointL) -> Double {
            // atan2(0, 0) is defined (0), so a radial point at the exact
            // centre degrades gracefully.
            atan2((Double(p.y) - cy) / ry, (Double(p.x) - cx) / rx)
        }

        let thetaStart = parameterAngle(start)
        let thetaEnd = parameterAngle(end)
        // Sweep magnitude in the decreasing-θ direction; coincident radials
        // mean a full ellipse.
        var sweep = thetaStart - thetaEnd
        if sweep <= 0 { sweep += 2 * Double.pi }

        func pointAt(_ theta: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(theta), y: cy + ry * sin(theta))
        }
        func derivativeAt(_ theta: Double) -> CGVector {
            CGVector(dx: -rx * sin(theta), dy: ry * cos(theta))
        }

        let segmentCount = max(1, Int((sweep / (Double.pi / 2)).rounded(.up)))
        let step = -sweep / Double(segmentCount)   // negative: θ decreases

        path.move(to: pointAt(thetaStart), transform: transform)
        var theta = thetaStart
        for _ in 0 ..< segmentCount {
            let next = theta + step
            // Standard cubic approximation of an elliptical arc segment:
            // C1 = P(θ1) + α·P′(θ1), C2 = P(θ2) − α·P′(θ2),
            // α = 4/3 · tan((θ2 − θ1)/4). Correct for either sweep direction.
            let alpha = 4.0 / 3.0 * tan((next - theta) / 4)
            let p1 = pointAt(theta)
            let p2 = pointAt(next)
            let d1 = derivativeAt(theta)
            let d2 = derivativeAt(next)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + alpha * d1.dx, y: p1.y + alpha * d1.dy),
                control2: CGPoint(x: p2.x - alpha * d2.dx, y: p2.y - alpha * d2.dy),
                transform: transform
            )
            theta = next
        }
    }
}
