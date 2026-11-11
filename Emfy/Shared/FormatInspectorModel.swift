import CoreGraphics
import EMFEdit

/// The Format inspector's derived, testable state (E2c): it reads a selection of
/// editable `Element`s and reports the displayed value of each property, or a
/// `mixed`/`none` state when the selection disagrees, exactly like Keynote's and
/// Pages' Format panel. It also builds the `SceneCommand`s an edit emits, so the
/// view holds no model logic beyond gesture coalescing. Pure and `Equatable`, so the
/// whole derivation is unit-tested from hand-built scenes.

// MARK: - Per-property display states

/// The fill shown for the selection. A gradient (or any non-solid brush the scene
/// lifted) is read-only — the editor can only replace it with a solid colour.
enum InspectorFill: Equatable {
    /// No selected element carries a fill.
    case none
    /// Every selected fill is the same solid colour.
    case color(SceneColor)
    /// A single selected element has a gradient fill (read-only).
    case gradient
    /// The selected elements' fills disagree.
    case mixed
}

/// The stroke shown for the selection. Dash is reported but edited read-only (the
/// editor sets colour and width only).
enum InspectorStroke: Equatable {
    case none
    case uniform(color: SceneColor, width: Double, cosmetic: Bool, dash: SceneStroke.Dash)
    case mixed
}

/// The opacity shown for the selection.
enum InspectorOpacity: Equatable {
    case uniform(Double)
    case mixed
}

/// The single-text-element state driving the Text section. Present only when the
/// selection is exactly one text run.
struct InspectorText: Equatable {
    var id: Int
    var content: String
    var family: String
    /// The on-page (device) point size, derived from the run's logical height and
    /// its transform (see `FontSizeConversion`).
    var pointSize: Int
    var bold: Bool
    var italic: Bool
}

// MARK: - The model

/// The Format inspector state for a selection. Build it from the elements the
/// selection names; every section reads a property off it.
struct FormatInspectorModel: Equatable {
    /// The selected editable element ids, so the view can emit apply-to-many commands.
    var ids: Set<Int>
    var fill: InspectorFill
    var stroke: InspectorStroke
    var opacity: InspectorOpacity
    /// Present only when the selection is exactly one text element.
    var text: InspectorText?

    var isEmpty: Bool { ids.isEmpty }

    /// Derives the state from the selected elements (passthrough/locked elements are
    /// never in an editor selection, so every element here is editable).
    init(selected: [Element]) {
        self.ids = Set(selected.map(\.id))
        self.fill = Self.deriveFill(selected)
        self.stroke = Self.deriveStroke(selected)
        self.opacity = Self.deriveOpacity(selected)
        self.text = Self.deriveText(selected)
    }

    // MARK: Derivations

    private static func deriveFill(_ selected: [Element]) -> InspectorFill {
        guard !selected.isEmpty else { return .none }
        let fills = selected.map(\.style.fill)
        if fills.allSatisfy({ $0 == nil }) { return .none }
        if fills.contains(where: { $0?.gradient != nil }) {
            return selected.count == 1 ? .gradient : .mixed
        }
        let colours = Set(fills.map { $0?.color })
        if colours.count == 1, let only = colours.first, let colour = only { return .color(colour) }
        return .mixed
    }

    private static func deriveStroke(_ selected: [Element]) -> InspectorStroke {
        guard !selected.isEmpty else { return .none }
        let strokes = selected.map(\.style.stroke)
        let present = strokes.compactMap { $0 }
        if present.isEmpty { return .none }
        if present.count == strokes.count, let first = present.first, present.allSatisfy({ $0 == first }) {
            return .uniform(color: first.color, width: first.width, cosmetic: first.isCosmetic, dash: first.dash)
        }
        return .mixed
    }

    private static func deriveOpacity(_ selected: [Element]) -> InspectorOpacity {
        guard let first = selected.first?.style.opacity else { return .uniform(1) }
        if selected.allSatisfy({ abs($0.style.opacity - first) < 1e-9 }) { return .uniform(first) }
        return .mixed
    }

    private static func deriveText(_ selected: [Element]) -> InspectorText? {
        guard selected.count == 1, let element = selected.first,
              element.kind == .text, let text = element.text else { return nil }
        return InspectorText(
            id: element.id,
            content: text.string,
            family: text.fontFamily,
            pointSize: FontSizeConversion.displayPointSize(text, transform: element.transform),
            bold: text.bold,
            italic: text.italic
        )
    }

    // MARK: - Commands (pure; the view owns coalescing keys)

    /// A solid-colour fill for every selected element. `evenOdd` is kept from the
    /// first selected fill so the fill rule survives a recolour.
    func fillColorCommand(_ colour: SceneColor, evenOdd: Bool) -> SceneCommand {
        .setFill(ids: ids, SceneFill(color: colour, evenOdd: evenOdd, gradient: nil))
    }

    /// Clears the fill of every selected element (Fill ▸ None).
    func clearFillCommand() -> SceneCommand {
        .setFill(ids: ids, nil)
    }

    /// Sets the opacity of every selected element.
    func opacityCommand(_ value: Double) -> SceneCommand {
        .setOpacity(ids: ids, value)
    }

    /// Adds (or replaces) a solid stroke on every selected element, keeping the
    /// shown width/dash where they are uniform.
    func strokeCommand(color: SceneColor, width: Double) -> SceneCommand {
        let dash: SceneStroke.Dash
        let cosmetic: Bool
        if case .uniform(_, _, let c, let d) = stroke { dash = d; cosmetic = c } else { dash = .solid; cosmetic = false }
        return .setStroke(ids: ids, SceneStroke(
            color: color, isCosmetic: cosmetic, width: max(0, width),
            dash: dash, cap: .round, join: .round, miterLimit: 10
        ))
    }

    /// Removes the stroke from every selected element.
    func clearStrokeCommand() -> SceneCommand { .setStroke(ids: ids, nil) }
}

// MARK: - Font size conversion ([MS-EMF] §2.2.13 / §2.3.4.2)

/// Converts between a run's stored logical font height and the on-page point size the
/// inspector shows. `SceneText.logicalHeight` is a LOGFONT cell/em height in the run's
/// PRE-transform (logical/world) units; the rendered device em is that height times
/// the element transform's scale (`SceneSynthesis.emfTextBlock` scales the logical
/// height by exactly this factor before emitting). The inspector works in the
/// on-page size, so it multiplies/divides by that scale and `setFont` stores back a
/// logical height (its `size:` argument is a logical em height, see
/// `Scene.setFont`).
enum FontSizeConversion {
    /// The run's effective em in logical units (GDI height, or the EMF+ em size when
    /// the run carries no logical height).
    static func effectiveEm(_ text: SceneText) -> Double {
        let height = abs(Double(text.logicalHeight))
        if height >= 1 { return height }
        return text.emSize > 0 ? text.emSize : 16
    }

    /// The on-page (device) point size for a run, rounded for display.
    static func displayPointSize(_ text: SceneText, transform: CGAffineTransform) -> Int {
        let scale = Double(EditorCanvasMapping.averageScale(transform))
        let device = effectiveEm(text) * (scale <= 0 ? 1 : scale)
        return Int(device.rounded())
    }

    /// The logical em height `setFont` needs for a chosen on-page point size, clamped
    /// to a sane range.
    static func logicalSize(fromPoints points: Double, transform: CGAffineTransform) -> Int32 {
        let scale = Double(EditorCanvasMapping.averageScale(transform))
        let logical = points / (scale <= 0 ? 1 : scale)
        let clamped = min(100_000, max(1, logical.rounded()))
        return Int32(clamped)
    }

    /// A `setFont` command for a chosen on-page point size.
    static func fontCommand(id: Int, family: String, points: Double, transform: CGAffineTransform, bold: Bool, italic: Bool) -> SceneCommand {
        .setFont(id: id, family: family, size: logicalSize(fromPoints: points, transform: transform), bold: bold, italic: italic)
    }
}

// MARK: - Text sanitisation (§8: user-typed text is untrusted plain data)

/// Cleans user-typed text before it becomes a `setText` command: strips control
/// characters other than tab (so a pasted newline/escape never reaches the record
/// writer) and caps the length. Matches the §8 rule that drawing text is untrusted
/// input.
enum TextSanitizer {
    /// The maximum kept length, in UTF-16-ish scalars. A sane bound well under any
    /// record-size limit, per design call 5.
    static let maxScalars = 32_768

    static func sanitize(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if isAllowed(scalar) {
                out.append(scalar)
                if out.count >= maxScalars { break }
            }
        }
        return String(out)
    }

    /// Tab is kept; every other C0 control, DEL, and the C1 range are stripped.
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" { return true }
        let v = scalar.value
        if v < 0x20 { return false }
        if v == 0x7F { return false }
        if v >= 0x80 && v <= 0x9F { return false }
        return true
    }
}
