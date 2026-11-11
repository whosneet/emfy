import CoreGraphics
import EMFEdit
import Foundation

/// The eight resize handles of a selection's bounding box, named by their VISUAL
/// position (the overlay works in view space, where "top" is the smaller y). The
/// resize maths below operate in the caller's space; the overlay conjugates the
/// result into device space through `EditorCanvasMapping.deviceTransform(fromView:)`.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Corner handles drive proportional resize and, with ⌘ on the Mac, rotation.
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }

    var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// This handle's point on `rect` (its own coordinate space).
    func point(in rect: CGRect) -> CGPoint {
        let r = rect.standardized
        let x = movesLeftEdge ? r.minX : (movesRightEdge ? r.maxX : r.midX)
        let y = movesTopEdge ? r.minY : (movesBottomEdge ? r.maxY : r.midY)
        return CGPoint(x: x, y: y)
    }
}

/// Pure resize / rotation / nudge maths for the selection overlay (design call
/// E2b-6). Everything here is a self-consistent operation on a rectangle and a
/// drag, so it is unit-tested without a view; the overlay supplies view-space
/// values and conjugates the result into device space.
enum EditorTransform {

    /// The affine that resizes `bounds` when `handle` is dragged by `translation`
    /// (both in the same space). The opposite corner/edge stays fixed (the anchor),
    /// unless `fromCenter` (Option) pins the centre instead; `aspectLocked` (Shift)
    /// keeps the width:height ratio. New extents are clamped to `minSize`, so the
    /// selection never flips through zero — a negative drag stalls at the minimum.
    static func resizeTransform(
        bounds: CGRect,
        handle: ResizeHandle,
        translation: CGVector,
        aspectLocked: Bool,
        fromCenter: Bool,
        minSize: CGFloat = 1
    ) -> CGAffineTransform {
        let b = bounds.standardized
        guard b.width >= minSize, b.height >= minSize else { return .identity }

        // An edge handle doesn't move in the perpendicular axis.
        let dx = (handle.movesLeftEdge || handle.movesRightEdge) ? translation.dx : 0
        let dy = (handle.movesTopEdge || handle.movesBottomEdge) ? translation.dy : 0

        // The signed extent change: a right/bottom edge grows with +drag, a
        // left/top edge grows with −drag. `fromCenter` moves both edges, doubling it.
        let factor: CGFloat = fromCenter ? 2 : 1
        var newWidth = b.width + factor * ((handle.movesRightEdge ? dx : 0) - (handle.movesLeftEdge ? dx : 0))
        var newHeight = b.height + factor * ((handle.movesBottomEdge ? dy : 0) - (handle.movesTopEdge ? dy : 0))

        if aspectLocked {
            let sx = newWidth / b.width
            let sy = newHeight / b.height
            let uniform: CGFloat
            if handle.isCorner {
                uniform = abs(sx - 1) >= abs(sy - 1) ? sx : sy
            } else if handle.movesLeftEdge || handle.movesRightEdge {
                uniform = sx
            } else {
                uniform = sy
            }
            newWidth = b.width * uniform
            newHeight = b.height * uniform
        }

        newWidth = max(newWidth, minSize)
        newHeight = max(newHeight, minSize)

        let anchor: CGPoint
        if fromCenter {
            anchor = CGPoint(x: b.midX, y: b.midY)
        } else {
            let ax = handle.movesLeftEdge ? b.maxX : (handle.movesRightEdge ? b.minX : b.midX)
            let ay = handle.movesTopEdge ? b.maxY : (handle.movesBottomEdge ? b.minY : b.midY)
            anchor = CGPoint(x: ax, y: ay)
        }
        let sx = newWidth / b.width
        let sy = newHeight / b.height
        // Scale about `anchor`, written as an explicit matrix so there is no
        // chaining-order ambiguity: p' = s·(p − anchor) + anchor.
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy,
            tx: anchor.x - sx * anchor.x,
            ty: anchor.y - sy * anchor.y
        )
    }

    /// The affine that rotates about `center` by the angle swept from `from` to `to`
    /// (all in the same space). The overlay feeds it the pointer's start and current
    /// points relative to the selection centre.
    static func rotationTransform(center: CGPoint, from: CGPoint, to: CGPoint) -> CGAffineTransform {
        let delta = rotationDelta(center: center, from: from, to: to)
        let cosA = cos(delta), sinA = sin(delta)
        // p' = R·(p − center) + center, written explicitly.
        return CGAffineTransform(
            a: cosA, b: sinA, c: -sinA, d: cosA,
            tx: center.x - cosA * center.x + sinA * center.y,
            ty: center.y - sinA * center.x - cosA * center.y
        )
    }

    /// The signed angle (radians) swept from `from` to `to` about `center`.
    static func rotationDelta(center: CGPoint, from: CGPoint, to: CGPoint) -> CGFloat {
        atan2(to.y - center.y, to.x - center.x) - atan2(from.y - center.y, from.x - center.x)
    }

    /// The live rotation readout in degrees, normalised to (−180, 180].
    static func rotationDegrees(center: CGPoint, from: CGPoint, to: CGPoint) -> CGFloat {
        var degrees = rotationDelta(center: center, from: from, to: to) * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees <= -180 { degrees += 360 }
        if degrees > 180 { degrees -= 360 }
        return degrees
    }
}

/// Arrow-key nudging (design call E2b-6): 1 device unit, or 10 with Shift. A run of
/// nudges coalesces into one undo entry through `coalescingKey`.
enum EditorNudge {
    static let coalescingKey = SceneCoalescingKey("editor.nudge")

    /// The device-space delta for an arrow nudge. `dx`/`dy` are the unit direction
    /// (−1, 0, or +1) the caller resolves from the pressed arrow and the view→device
    /// y-flip; `large` is Shift.
    static func delta(dx: Int, dy: Int, large: Bool) -> CGVector {
        let step: CGFloat = large ? 10 : 1
        return CGVector(dx: CGFloat(dx) * step, dy: CGFloat(dy) * step)
    }
}
