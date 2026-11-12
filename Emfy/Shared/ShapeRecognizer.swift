import CoreGraphics
import EMFEdit
import Foundation

/// Clean-room "snap to shape" recogniser (E3b design call 4). Given the raw device-space
/// points of a freehand stroke, it decides whether the gesture was MEANT to be a perfect
/// line, ellipse, rectangle or triangle. A match is committed as that shape (with the
/// pen's stroke, no fill) instead of the smoothed curve; no match leaves the curve.
///
/// Pure and deterministic, so it is unit-tested directly. The caller runs it only when the
/// pointer/Pencil held still at the end of the stroke, so a normal scribble is never snapped.
enum ShapeRecognizer {

    /// The shape a stroke was recognised as, plus the device-space rectangle to build it in
    /// (`SceneFactory.makeShape` sizes every kind from a rect; a line keeps its direction
    /// through a signed rect).
    struct Match: Equatable {
        var kind: ShapeToolKind
        var rect: CGRect
    }

    // MARK: - Thresholds (device-independent ratios, reported in the brief)

    /// Endpoints within this fraction of the bounding-box diagonal count the stroke as a
    /// CLOSED loop (an ellipse/rect/triangle candidate); otherwise it is open.
    static let closedFraction: CGFloat = 0.22
    /// A line's points must all sit within this fraction of the chord length from the
    /// chord (max perpendicular deviation), and the chord must be the dominant extent.
    static let lineDeviationFraction: CGFloat = 0.08
    /// An ellipse matches when the mean relative radial error (point radius vs the box's
    /// inscribed ellipse) is under this.
    static let ellipseRadialError: CGFloat = 0.16
    /// A polygon corner counts as a right angle when its interior angle is within this many
    /// radians of 90°.
    static let rightAngleTolerance: CGFloat = 20 * .pi / 180

    /// Recognises `points` (device space). `rdpTolerance` is the corner-detection tolerance
    /// in device units (the caller passes the same ~1.5 view-pt value the smoother uses,
    /// scaled a little for corners). Returns `nil` when nothing matches well.
    static func recognize(points: [CGPoint], rdpTolerance: CGFloat) -> Match? {
        guard points.count >= 4 else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 1 else { return nil }

        let first = points[0]
        let last = points[points.count - 1]
        let isClosed = hypot(last.x - first.x, last.y - first.y) <= closedFraction * diagonal

        // An OPEN stroke can only be a straight line.
        if !isClosed, let line = matchLine(points) { return line }
        guard isClosed else { return nil }

        // A closed stroke: corner-count via RDP on the closed polyline decides the polygon,
        // then an ellipse test, else no match.
        let corners = polygonCorners(points, tolerance: max(rdpTolerance * 2, diagonal * 0.04))
        if corners == 3 { return Match(kind: .triangle, rect: box) }
        if corners == 4, rectangleAnglesAreRight(points, tolerance: max(rdpTolerance * 2, diagonal * 0.04)) {
            return Match(kind: .rect, rect: box)
        }
        if ellipseError(points, box: box) <= ellipseRadialError { return Match(kind: .ellipse, rect: box) }
        return nil
    }

    // MARK: - Line

    private static func matchLine(_ points: [CGPoint]) -> Match? {
        let a = points[0], b = points[points.count - 1]
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord > 1 else { return nil }
        var maxDev: CGFloat = 0
        for p in points { maxDev = max(maxDev, StrokeSmoothing.perpendicularDistance(p, from: a, to: b)) }
        guard maxDev <= lineDeviationFraction * chord else { return nil }
        // A signed rect from a to b keeps the drawn direction.
        return Match(kind: .line, rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
    }

    // MARK: - Polygon corners

    /// The number of distinct corners of the closed polyline, via RDP. The stroke is closed
    /// by appending the first point; RDP's shared endpoint is then de-duplicated.
    static func polygonCorners(_ points: [CGPoint], tolerance: CGFloat) -> Int {
        var closed = points
        if let f = points.first, let l = points.last, f != l { closed.append(f) }
        let simplified = StrokeSmoothing.douglasPeucker(closed, tolerance: tolerance)
        // The first and last of `simplified` are the same vertex (the loop closure).
        var corners = simplified
        if corners.count >= 2, corners.first == corners.last { corners.removeLast() }
        return corners.count
    }

    /// Whether a 4-corner closed stroke's interior angles are all near 90°.
    private static func rectangleAnglesAreRight(_ points: [CGPoint], tolerance: CGFloat) -> Bool {
        var closed = points
        if let f = points.first, let l = points.last, f != l { closed.append(f) }
        let simplified = StrokeSmoothing.douglasPeucker(closed, tolerance: tolerance)
        var verts = simplified
        if verts.count >= 2, verts.first == verts.last { verts.removeLast() }
        guard verts.count == 4 else { return false }
        for i in 0 ..< 4 {
            let prev = verts[(i + 3) % 4], cur = verts[i], next = verts[(i + 1) % 4]
            let v1 = CGVector(dx: prev.x - cur.x, dy: prev.y - cur.y)
            let v2 = CGVector(dx: next.x - cur.x, dy: next.y - cur.y)
            let n1 = hypot(v1.dx, v1.dy), n2 = hypot(v2.dx, v2.dy)
            guard n1 > 0, n2 > 0 else { return false }
            let cosA = (v1.dx * v2.dx + v1.dy * v2.dy) / (n1 * n2)
            let angle = acos(max(-1, min(1, cosA)))
            if abs(angle - .pi / 2) > rightAngleTolerance { return false }
        }
        return true
    }

    // MARK: - Ellipse

    /// The mean relative error between each point's radius and the inscribed ellipse's
    /// radius in that point's direction. 0 is a perfect ellipse in the box.
    static func ellipseError(_ points: [CGPoint], box: CGRect) -> CGFloat {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 0, ry > 0 else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        var count = 0
        for p in points {
            let dx = (p.x - cx) / rx, dy = (p.y - cy) / ry
            let r = hypot(dx, dy)           // 1.0 exactly on the ellipse
            total += abs(r - 1)
            count += 1
        }
        return count > 0 ? total / CGFloat(count) : .greatestFiniteMagnitude
    }

    // MARK: - Helpers

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
