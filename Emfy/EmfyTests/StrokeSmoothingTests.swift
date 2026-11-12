import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3b: the clean-room freehand smoothing pipeline — sample de-dup, RDP simplification,
// and Catmull-Rom → cubic Bézier fitting. Pure-logic tests in the EmfyTests bundle.

@Suite struct StrokeSmoothingTests {

    // MARK: - Point reduction

    @Test func denseStraightLineReducesToOneSegment() {
        // 200 collinear samples collapse to a single straight segment.
        let points = (0 ..< 200).map { CGPoint(x: Double($0), y: Double($0) * 0.5) }
        let path = StrokeSmoothing.smooth(devicePoints: points, minSpacing: 0.5, rdpTolerance: 1)
        #expect(path.segments.count == 2)   // .move + .line
        if case .line = path.segments[1] {} else { Issue.record("expected a straight line") }
    }

    @Test func rdpShedsNearCollinearPoints() {
        // A gently curved run of 100 points simplifies to far fewer knots.
        let points = (0 ..< 100).map { i -> CGPoint in
            let x = Double(i) * 3
            return CGPoint(x: x, y: 200 + sin(x / 120) * 40)
        }
        let simplified = StrokeSmoothing.douglasPeucker(points, tolerance: 2)
        #expect(simplified.count < points.count)
        #expect(simplified.count >= 2)
    }

    // MARK: - G1 / C1 continuity

    @Test func interiorJoinsAreTangentContinuous() {
        // Distinct knots → a cubic per segment; adjacent segments must share a tangent
        // DIRECTION at each interior knot (G1; Catmull-Rom actually gives C1).
        let knots = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 80), CGPoint(x: 220, y: 40),
            CGPoint(x: 300, y: 160), CGPoint(x: 420, y: 100),
        ]
        let path = StrokeSmoothing.fitCubicBezier(through: knots)
        // Reconstruct (start, c1, c2, end) per cubic.
        var cubics: [(start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint)] = []
        var current = CGPoint.zero
        for segment in path.segments {
            switch segment {
            case .move(let p): current = p
            case .cubicCurve(let to, let c1, let c2): cubics.append((current, c1, c2, to)); current = to
            default: break
            }
        }
        #expect(cubics.count == knots.count - 1)
        for i in 0 ..< cubics.count - 1 {
            // incoming tangent at the shared knot, and outgoing tangent of the next cubic.
            let incoming = CGVector(dx: cubics[i].end.x - cubics[i].c2.x, dy: cubics[i].end.y - cubics[i].c2.y)
            let outgoing = CGVector(dx: cubics[i + 1].c1.x - cubics[i + 1].start.x, dy: cubics[i + 1].c1.y - cubics[i + 1].start.y)
            let cross = incoming.dx * outgoing.dy - incoming.dy * outgoing.dx
            let dot = incoming.dx * outgoing.dx + incoming.dy * outgoing.dy
            #expect(abs(cross) < 1e-6)   // parallel
            #expect(dot > 0)             // same direction
        }
    }

    // MARK: - Endpoints preserved

    @Test func endpointsSurviveSmoothing() {
        let points = (0 ..< 50).map { i -> CGPoint in
            let t = Double(i)
            return CGPoint(x: t * 6, y: 100 + sin(t / 5) * 30)
        }
        let path = StrokeSmoothing.smooth(devicePoints: points, minSpacing: 1, rdpTolerance: 1.5)
        guard case .move(let first) = path.segments.first else { Issue.record("no move"); return }
        #expect(first == points.first)
        // The last segment's destination is the stroke's true endpoint.
        var last: CGPoint?
        if case .cubicCurve(let to, _, _) = path.segments.last { last = to }
        if case .line(let to) = path.segments.last { last = to }
        #expect(last == points.last)
    }

    // MARK: - §8 cap

    @Test func rawSampleCountIsCapped() {
        let huge = (0 ..< 25_000).map { CGPoint(x: Double($0) * 0.1, y: sin(Double($0) / 50) * 20) }
        #expect(StrokeSmoothing.decimated(huge, to: StrokeSmoothing.maxRawSamples).count == StrokeSmoothing.maxRawSamples)
        // With no simplification the fitted curve still cannot exceed the cap.
        let path = StrokeSmoothing.smooth(devicePoints: huge, minSpacing: 0, rdpTolerance: 0)
        #expect(path.segments.count <= StrokeSmoothing.maxRawSamples)
    }

    @Test func twoPointsMakeALine() {
        let path = StrokeSmoothing.fitCubicBezier(through: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 40)])
        #expect(path.segments.count == 2)
        if case .move = path.segments[0] {} else { Issue.record("no move") }
        if case .line = path.segments[1] {} else { Issue.record("no line") }
    }
}
