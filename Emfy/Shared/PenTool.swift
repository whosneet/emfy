import CoreGraphics
import EMFEdit
import Foundation

/// The pen's current colour and width (E3b design call 3). Held on `EditorModel`, so the
/// choice persists for the editing session. Width is in typographic points; the tool
/// converts it to device units through `Scene.deviceUnitsPerPoint` so a 2 pt stroke is the
/// right physical size on any document.
struct PenStyle: Equatable, Sendable {
    var color: SceneColor
    var widthPoints: CGFloat

    static let `default` = PenStyle(color: PenPalette.black, widthPoints: 2)
}

/// The fixed pen palette the toolbar menu offers (E3b design call 3): six colours and
/// three widths. Pure data, shared by the Mac and iPad palettes.
enum PenPalette {
    static let black = SceneColor(red: 0, green: 0, blue: 0)
    static let blue = SceneColor(red: 10.0 / 255, green: 132.0 / 255, blue: 255.0 / 255)
    static let red = SceneColor(red: 255.0 / 255, green: 59.0 / 255, blue: 48.0 / 255)
    static let green = SceneColor(red: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255)
    static let orange = SceneColor(red: 255.0 / 255, green: 149.0 / 255, blue: 0)
    static let purple = SceneColor(red: 175.0 / 255, green: 82.0 / 255, blue: 222.0 / 255)

    /// Swatches in menu order, with a display name.
    static let colors: [(name: String, color: SceneColor)] = [
        ("Black", black), ("Blue", blue), ("Red", red),
        ("Green", green), ("Orange", orange), ("Purple", purple),
    ]

    /// Stroke widths in points, in menu order.
    static let widths: [CGFloat] = [1, 2, 4]
}

/// Builds the single undoable insert for a committed pen stroke (E3b design call 1/4). Kept
/// here so the Mac and iPad canvases — and the DEBUG script — share one definition of the
/// stroke style, the new id and the top-of-z-order placement. A pen stroke is NEVER
/// auto-selected (the pen stays armed), so the caller just applies the command.
enum PenToolInsertion {
    /// Resolves the pen style to a device-space stroke style for `scene`.
    static func strokeStyle(_ pen: PenStyle, in scene: Scene) -> SceneStyle {
        let widthDevice = Double(ShapeToolGeometry.pointsToDevice(pen.widthPoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint))
        return SceneFactory.penStyle(color: pen.color, widthDevice: widthDevice)
    }

    /// The insert command for a smoothed freehand stroke (`geometryDevice` in device space),
    /// plus its new id. Goes at the top of the z-order in the first editable layer.
    static func strokeCommand(geometryDevice: ScenePath, pen: PenStyle, in scene: Scene) -> (command: SceneCommand, id: Int) {
        let id = SceneFactory.nextElementID(in: scene)
        let element = SceneFactory.makeStroke(geometryDevice: geometryDevice, style: strokeStyle(pen, in: scene), id: id)
        let topZ = scene.layers.first?.elements.count ?? 0
        return (.insert(element: element, at: topZ), id)
    }

    /// The insert command for a snapped-to-shape stroke: the perfect shape, built with the
    /// PEN's stroke and no fill (design call 4). Reuses `SceneFactory.makeShape`.
    static func snappedShapeCommand(kind: ShapeToolKind, rectDevice: CGRect, pen: PenStyle, in scene: Scene) -> (command: SceneCommand, id: Int) {
        let id = SceneFactory.nextElementID(in: scene)
        let element = SceneFactory.makeShape(kind: kind.elementKind, rectDevice: rectDevice, style: strokeStyle(pen, in: scene), id: id)
        let topZ = scene.layers.first?.elements.count ?? 0
        return (.insert(element: element, at: topZ), id)
    }
}

/// The pen's end-to-end commit decision (E3b design call 1/2/4), shared by the live tool
/// and the DEBUG `pen-strokes` script so BOTH run the identical pipeline: when the gesture
/// ended on a HOLD, try the recogniser and snap on a match; otherwise (or on no match)
/// commit the smoothed curve. Pure given its raw device points.
enum PenCommit {
    /// Decides the insert command for a finished stroke. `rawDevicePoints` are the stroke's
    /// samples in device space; `held` is whether the pointer/Pencil paused ≥ 0.5 s before
    /// release; `minSpacing`/`rdpTolerance` are the smoothing/recognition tolerances in
    /// device units.
    static func command(
        rawDevicePoints: [CGPoint], held: Bool,
        minSpacing: CGFloat, rdpTolerance: CGFloat,
        pen: PenStyle, in scene: Scene
    ) -> (command: SceneCommand, id: Int)? {
        guard rawDevicePoints.count >= 2 else { return nil }
        if held, let match = ShapeRecognizer.recognize(points: rawDevicePoints, rdpTolerance: rdpTolerance) {
            return PenToolInsertion.snappedShapeCommand(kind: match.kind, rectDevice: match.rect, pen: pen, in: scene)
        }
        let geometry = StrokeSmoothing.smooth(devicePoints: rawDevicePoints, minSpacing: minSpacing, rdpTolerance: rdpTolerance)
        guard !geometry.isEmpty, geometry.segments.count >= 2 else { return nil }
        return PenToolInsertion.strokeCommand(geometryDevice: geometry, pen: pen, in: scene)
    }
}

/// What a one-touch drag on the iPad canvas should do in edit mode (E3b design call 1).
/// Pure so the touch-routing decision is unit-tested without a Pencil or Simulator.
/// Apple Pencil ALWAYS draws; a finger selects/moves unless a tool is armed.
enum PenDrawMode: Equatable {
    /// Draw the armed shape tool.
    case shape
    /// Draw a freehand pen stroke.
    case pen
    /// Normal selection/move/resize (no drawing).
    case select

    static func resolve(isPencil: Bool, armedPen: Bool, armedShape: Bool) -> PenDrawMode {
        if armedShape { return .shape }          // a shape tool wins for pencil and finger
        if isPencil { return .pen }              // the Pencil always draws the pen
        if armedPen { return .pen }              // a finger draws only when the pen is armed
        return .select
    }
}

/// How a Pencil double-tap should be handled, respecting the user's system preference
/// (E3b design call 5). The UIKit `UIPencilPreferredAction` is mapped to this mirror enum
/// in the iPad glue, so the decision logic is testable on any platform.
enum PenPencilTapPreference: Equatable, Sendable {
    case ignore
    case switchTool
    case showPalette
    case systemDefault
}

/// The action a Pencil double-tap or squeeze resolves to.
enum PenPencilAction: Equatable, Sendable {
    case togglePenSelect
    case showPalette
    case none
}

/// Pure Pencil decision helpers (E3b design call 5). Hover/squeeze/double-tap glue is thin
/// UIKit that can't run in the Simulator, so the logic lives here and is unit-tested.
enum PencilSupport {
    /// The double-tap action for the user's preferred tap action.
    static func doubleTapAction(for preference: PenPencilTapPreference) -> PenPencilAction {
        switch preference {
        case .ignore: return .none
        case .showPalette: return .showPalette
        case .switchTool, .systemDefault: return .togglePenSelect
        }
    }

    /// A squeeze always offers the palette (design call 5).
    static func squeezeAction() -> PenPencilAction { .showPalette }

    /// The diameter (device units) of the hover preview ring for a pen of `widthDevice`,
    /// floored so a 1 pt pen still shows a visible ring.
    static func hoverRingDiameter(widthDevice: CGFloat, minimum: CGFloat = 8) -> CGFloat {
        max(minimum, widthDevice)
    }
}
