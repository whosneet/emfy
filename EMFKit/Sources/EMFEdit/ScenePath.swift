import CoreGraphics
import Foundation

/// An editor-friendly, value-type path: a flat list of segments. Unlike
/// `CGPath` it is `Equatable`, `Sendable`, and editable point-by-point, which
/// the scene model (undo as value diffs, E1c) requires. It round-trips to and
/// from `CGPath` losslessly for the segment kinds EMF geometry produces.
///
/// Coordinates are in the scene's DEVICE space (the source's y-down device
/// coordinates, see `Scene`); the renderer applies the device→target fit and
/// the single y-flip when it draws.
public struct ScenePath: Sendable, Equatable {

    /// One path segment. Quadratic and cubic curves are both carried so a
    /// `CGPath` built by CoreGraphics (e.g. an ellipse's cubic arcs) survives
    /// the round trip exactly.
    public enum Segment: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case cubicCurve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }

    /// Flattens a `CGPath` into value-type segments.
    public init(_ cgPath: CGPath) {
        var collected: [Segment] = []
        cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                collected.append(.move(element.points[0]))
            case .addLineToPoint:
                collected.append(.line(element.points[0]))
            case .addQuadCurveToPoint:
                collected.append(.quadCurve(to: element.points[1], control: element.points[0]))
            case .addCurveToPoint:
                collected.append(.cubicCurve(to: element.points[2], control1: element.points[0], control2: element.points[1]))
            case .closeSubpath:
                collected.append(.close)
            @unknown default:
                break
            }
        }
        self.segments = collected
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Rebuilds a `CGPath` for drawing or hit-testing.
    public var cgPath: CGPath {
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .quadCurve(let to, let control):
                path.addQuadCurve(to: to, control: control)
            case .cubicCurve(let to, let control1, let control2):
                path.addCurve(to: to, control1: control1, control2: control2)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    /// The device-space bounding box (control-point box via CoreGraphics), or
    /// `.null` when empty.
    public var boundingBox: CGRect {
        isEmpty ? .null : cgPath.boundingBoxOfPath
    }
}
