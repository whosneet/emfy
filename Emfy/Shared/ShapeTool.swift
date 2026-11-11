import CoreGraphics
import EMFEdit
import Foundation

/// The shape kinds the creation tool offers, in menu order (E3a design call 5).
/// Pure data shared by the Mac and iPad canvases, so the tool's menu, cursor and
/// geometry are identical on both.
enum ShapeToolKind: String, CaseIterable, Identifiable, Sendable {
    case rect
    case roundRect
    case ellipse
    case line
    case triangle

    var id: String { rawValue }

    /// The EMFEdit element kind this tool inserts (a triangle is a `.polygon`).
    var elementKind: ElementKind {
        switch self {
        case .rect: return .rect
        case .roundRect: return .roundRect
        case .ellipse: return .ellipse
        case .line: return .line
        case .triangle: return .polygon
        }
    }

    var title: String {
        switch self {
        case .rect: return "Rectangle"
        case .roundRect: return "Rounded Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .triangle: return "Triangle"
        }
    }

    /// The SF Symbol for the menu row.
    var systemImage: String {
        switch self {
        case .rect: return "rectangle"
        case .roundRect: return "rectangle.roundedtop"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .triangle: return "triangle"
        }
    }

    /// Whether this kind fills a closed area (so it gets the default fill style) vs a
    /// line (which gets the default stroke style).
    var isClosed: Bool { self != .line }
}

/// Pure geometry for the shapes tool (E3a design call 5): it turns a drag — a start
/// and current point plus the Shift/Option modifiers — into the shape's rectangle,
/// and supplies the click-without-drag default. The maths is coordinate-space
/// agnostic (it holds for the editor's device↔view mapping, a y-flip and uniform
/// scale), so a caller can constrain in view space and map the result to device.
enum ShapeToolGeometry {

    /// A drag shorter than this many points (on screen) is treated as a click, which
    /// inserts the default-sized shape instead of a swept one.
    static let clickThresholdPoints: CGFloat = 4

    /// The default shape's side length in points for a click without a drag
    /// (100 × 100 pt, design call 5).
    static let defaultSidePoints: CGFloat = 100

    /// Points → device units at the from-scratch authoring resolution (96 DPI): a
    /// point is 1/72 inch, so a 2 pt line or a 100 pt box maps to the page's device
    /// units "correctly" for a document authored by `SceneFactory`.
    static func pointsToDevice(_ points: CGFloat) -> CGFloat {
        points * CGFloat(SceneFactory.dotsPerInch) / 72
    }

    /// The default line width in device units for a new line (2 pt, design call 5).
    static var defaultLineWidthDevice: Double { Double(pointsToDevice(2)) }

    /// The rectangle a drag sweeps, honouring Shift (a square — equal width and
    /// height) and Option (drawn from the centre, so `start` is the midpoint). The
    /// returned rect keeps a signed size, so a `.line`'s direction survives.
    static func sweptRect(kind: ShapeToolKind, start: CGPoint, current: CGPoint, shift: Bool, fromCentre: Bool) -> CGRect {
        if kind == .line {
            var delta = CGSize(width: current.x - start.x, height: current.y - start.y)
            if shift { delta = snapTo45(delta) }
            if fromCentre {
                return CGRect(x: start.x - delta.width, y: start.y - delta.height,
                              width: delta.width * 2, height: delta.height * 2)
            }
            return CGRect(origin: start, size: delta)
        }

        var size = CGSize(width: current.x - start.x, height: current.y - start.y)
        if shift {
            // A square: use the larger extent for both sides, keeping each sign.
            let side = max(abs(size.width), abs(size.height))
            size = CGSize(width: side * signOrOne(size.width), height: side * signOrOne(size.height))
        }
        if fromCentre {
            return CGRect(x: start.x - size.width, y: start.y - size.height,
                          width: size.width * 2, height: size.height * 2)
        }
        return CGRect(origin: start, size: size)
    }

    /// The default rect for a click without a drag: a `sideDevice`-square box centred
    /// at the device point.
    static func defaultRect(centreDevice: CGPoint, sideDevice: CGFloat) -> CGRect {
        CGRect(x: centreDevice.x - sideDevice / 2, y: centreDevice.y - sideDevice / 2,
               width: sideDevice, height: sideDevice)
    }

    /// Whether a drag from `start` to `current`, measured on screen at `magnification`,
    /// is long enough to be a sweep rather than a click.
    static func isDrag(start: CGPoint, current: CGPoint, magnification: CGFloat) -> Bool {
        hypot(current.x - start.x, current.y - start.y) * max(magnification, 0.0001) >= clickThresholdPoints
    }

    /// Snaps a delta vector to the nearest 45°, preserving its length (line Shift).
    private static func snapTo45(_ delta: CGSize) -> CGSize {
        let length = hypot(delta.width, delta.height)
        guard length > 0 else { return delta }
        let step = CGFloat.pi / 4
        let angle = (atan2(delta.height, delta.width) / step).rounded() * step
        return CGSize(width: cos(angle) * length, height: sin(angle) * length)
    }

    private static func signOrOne(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }
}

/// Builds the single undoable insert for a drawn shape (E3a design call 5). Kept here
/// so the Mac and iPad canvases share one definition of the default style, the new
/// id, and the top-of-z-order placement.
enum ShapeToolInsertion {
    /// The insert command for a `kind` shape filling `rectDevice` (device space) in
    /// `scene`, plus the new element's unique id so the caller can select it. The
    /// element goes at the top of the z-order in the first (top) editable layer.
    static func command(kind: ShapeToolKind, rectDevice: CGRect, in scene: Scene) -> (command: SceneCommand, id: Int) {
        let id = SceneFactory.nextElementID(in: scene)
        let style = kind.isClosed
            ? SceneFactory.defaultShapeStyle
            : SceneFactory.defaultLineStyle(widthDevice: ShapeToolGeometry.defaultLineWidthDevice)
        let cornerRadius: CGFloat = kind == .roundRect ? ShapeToolGeometry.pointsToDevice(16) : 0
        let element = SceneFactory.makeShape(
            kind: kind.elementKind, rectDevice: rectDevice, style: style, id: id, cornerRadiusDevice: cornerRadius
        )
        let topZ = scene.layers.first?.elements.count ?? 0
        return (.insert(element: element, at: topZ), id)
    }
}
