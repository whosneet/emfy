import CoreGraphics
import EMFEdit

/// Routes a single colour pick in the light editor (E4 design call 2) to the right
/// paint channel for each selected element, and builds the `SceneCommand`s it emits.
/// Pure and testable: the colour sheet and `DocumentSession.applyColor` hold no
/// routing logic of their own.
///
/// The design: "setFill to closed shapes, setStroke colour to lines and paths, and
/// text colour to text." A text run's colour is set through `setFill` — the scene
/// mutation maps a text element's fill colour onto its glyph colour
/// (`Scene.setFill`), which is exactly how the E2c Format inspector recolours text,
/// so no new EMFEdit command is needed. The decision reads the element's existing
/// paint first (a filled shape recolours its fill, a stroke-only line its stroke)
/// and falls back to the kind for an element that carries neither — matching the
/// defaults the creation tools give new shapes (closed → fill, line → stroke).
enum LightColorRouter {

    /// The paint channel a colour pick sets for one element.
    enum Channel: Equatable {
        /// A solid fill (closed shapes, and text — a text run's fill is its glyph colour).
        case fill
        /// The stroke colour (lines and open/stroked paths).
        case stroke
        /// No colourable paint (images, groups, passthrough) — skipped.
        case skip
    }

    /// Which channel a colour pick sets for `element`.
    static func channel(for element: Element) -> Channel {
        switch element.kind {
        case .text:
            return .fill   // a text run's fill colour is its glyph colour
        case .image, .group, .passthrough:
            return .skip
        case .rect, .ellipse, .roundRect, .polygon, .path, .polyline, .line, .arc, .bezier:
            // Prefer the element's existing paint, so a recolour matches what the user
            // sees; fall back to the kind for an element drawn with neither.
            if element.style.fill != nil { return .fill }
            if element.style.stroke != nil { return .stroke }
            switch element.kind {
            case .line, .polyline, .path, .arc, .bezier: return .stroke
            default: return .fill
            }
        }
    }

    /// The commands a colour pick emits for `elements`: at most one `setFill` over
    /// every fill-channel (and text) element, and one `setStroke` over every
    /// stroke-channel element. `evenOdd: false` matches the E2c recolour, which also
    /// resets the fill rule on a recolour. The stroke keeps a representative width and
    /// dash from the first stroked element in the selection (or a 1-unit solid stroke
    /// when none carries one), applied to all — light editing recolours, it does not
    /// re-dash.
    static func commands(for elements: [Element], color: SceneColor) -> [SceneCommand] {
        var fillIDs: Set<Int> = []
        var strokeIDs: Set<Int> = []
        for element in elements {
            switch channel(for: element) {
            case .fill: fillIDs.insert(element.id)
            case .stroke: strokeIDs.insert(element.id)
            case .skip: break
            }
        }
        var commands: [SceneCommand] = []
        if !fillIDs.isEmpty {
            commands.append(.setFill(ids: fillIDs, SceneFill(color: color, evenOdd: false, gradient: nil)))
        }
        if !strokeIDs.isEmpty {
            commands.append(.setStroke(ids: strokeIDs, strokeTemplate(for: elements, strokeIDs: strokeIDs, color: color)))
        }
        return commands
    }

    /// A stroke carrying the new colour, keeping width/dash/cap/join from the first
    /// stroked element in the selection, or a plain 1-unit solid stroke when none has one.
    private static func strokeTemplate(for elements: [Element], strokeIDs: Set<Int>, color: SceneColor) -> SceneStroke {
        if let existing = elements.first(where: { strokeIDs.contains($0.id) })?.style.stroke {
            return SceneStroke(
                color: color, isCosmetic: existing.isCosmetic, width: existing.width,
                dash: existing.dash, cap: existing.cap, join: existing.join, miterLimit: existing.miterLimit
            )
        }
        return SceneStroke(color: color, isCosmetic: false, width: 1, dash: .solid, cap: .round, join: .round, miterLimit: 10)
    }
}
