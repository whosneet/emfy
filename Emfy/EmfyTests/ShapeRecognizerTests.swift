import CoreGraphics
import EMFEdit
import Foundation
import Testing

// E3b: the snap-to-shape recogniser. Positive cases for line/ellipse/rect/triangle and
// negative cases for a scribble and an open arc. Deterministic synthetic strokes.

@Suite struct ShapeRecognizerTests {

    /// A small deterministic wobble so a synthetic stroke looks hand-drawn, not perfect.
    private func wobble(_ i: Int, _ amp: CGFloat) -> CGFloat { sin(CGFloat(i) * 0.9) * amp }

    // MARK: - Positives

    @Test func straightStrokeSnapsToLine() {
        let a = CGPoint(x: 60, y: 80), b = CGPoint(x: 420, y: 300)
        let points = (0 ... 40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: a.x + (b.x - a.x) * t + wobble(i, 1.5), y: a.y + (b.y - a.y) * t + wobble(i, 1.5))
        }
        let match = ShapeRecognizer.recognize(points: points, rdpTolerance: 3)
        #expect(match?.kind == .line)
    }

    @Test func roundStrokeSnapsToEllipse() {
        let cx: CGFloat = 250, cy: CGFloat = 250, r: CGFloat = 120
        var points = (0 ... 72).map { i -> CGPoint in
            let a = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: cx + cos(a) * r + wobble(i, 3), y: cy + sin(a) * r + wobble(i, 3))
        }
        points.append(points[0])   // close
        let match = ShapeRecognizer.recognize(points: points, rdpTolerance: 3)
        #expect(match?.kind == .ellipse)
    }

    @Test func boxyStrokeSnapsToRectangle() {
        // Four edges, sampled with a little wobble, returning to the start.
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 280), CGPoint(x: 100, y: 280)]
        var points: [CGPoint] = []
        for edge in 0 ..< 4 {
            let p0 = corners[edge], p1 = corners[(edge + 1) % 4]
            for i in 0 ..< 15 {
                let t = CGFloat(i) / 15
                points.append(CGPoint(x: p0.x + (p1.x - p0.x) * t + wobble(i, 1.2), y: p0.y + (p1.y - p0.y) * t + wobble(i, 1.2)))
            }
        }
        points.append(corners[0])
        let match = ShapeRecognizer.recognize(points: points, rdpTolerance: 3)
        #expect(match?.kind == .rect)
    }

    @Test func triangularStrokeSnapsToTriangle() {
        let corners = [CGPoint(x: 250, y: 80), CGPoint(x: 420, y: 360), CGPoint(x: 80, y: 360)]
        var points: [CGPoint] = []
        for edge in 0 ..< 3 {
            let p0 = corners[edge], p1 = corners[(edge + 1) % 3]
            for i in 0 ..< 20 {
                let t = CGFloat(i) / 20
                points.append(CGPoint(x: p0.x + (p1.x - p0.x) * t + wobble(i, 1.2), y: p0.y + (p1.y - p0.y) * t + wobble(i, 1.2)))
            }
        }
        points.append(corners[0])
        let match = ShapeRecognizer.recognize(points: points, rdpTolerance: 3)
        #expect(match?.kind == .triangle)
    }

    // MARK: - Negatives

    @Test func scribbleStaysACurve() {
        // A wavy open zigzag: not close to a straight chord, and not closed.
        let points = (0 ... 60).map { i -> CGPoint in
            CGPoint(x: CGFloat(i) * 6, y: 200 + sin(CGFloat(i) * 0.8) * 90)
        }
        #expect(ShapeRecognizer.recognize(points: points, rdpTolerance: 3) == nil)
    }

    @Test func openArcStaysACurve() {
        // A half-circle: curved (so not a line) and open (endpoints far apart) → no match.
        let cx: CGFloat = 250, cy: CGFloat = 250, r: CGFloat = 120
        let points = (0 ... 40).map { i -> CGPoint in
            let a = CGFloat(i) / 40 * .pi   // 0 … π, a semicircle
            return CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
        #expect(ShapeRecognizer.recognize(points: points, rdpTolerance: 3) == nil)
    }

    @Test func tooFewPointsIsNoMatch() {
        #expect(ShapeRecognizer.recognize(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], rdpTolerance: 3) == nil)
    }
}
