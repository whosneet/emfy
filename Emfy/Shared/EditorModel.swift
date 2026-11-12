import CoreGraphics
import Observation
import SwiftUI

/// Per-pane editor UI state, shared between the SwiftUI pane (toggle, menus,
/// selection pruning) and the AppKit/UIKit canvas coordinator (pointer and touch).
/// One per open document while editing; `@Observable` so the toolbar/menu enablement
/// and the rotation readout track it (design call E2b-4/-6).
@MainActor
@Observable
final class EditorModel {
    /// The current selection (ids). The canvas mutates it on click/tap/marquee; the
    /// pane mutates it for ⌘A / Deselect and prunes it after each `editVersion`.
    var selection = EditorSelection()

    /// The live rotation angle readout (e.g. "-12°") shown while a rotation drag is in
    /// flight, or nil when not rotating.
    var rotationReadout: String?

    /// A pending text-edit popover (design call E2c-5): set when the user double-clicks
    /// (Mac) or double-taps (iPad) a text element, read by the editing container to
    /// present a popover anchored to the element. `nil` when none is open.
    var textEdit: TextEditRequest?

    /// The armed shape-creation tool, or `nil` for the normal select/transform tool
    /// (E3a design call 5). Choosing a shape from the Shapes menu arms it; the canvas
    /// shows a crosshair, a drag draws it, and committing one disarms the tool
    /// (Keynote behaviour). Observed so the toolbar reflects the armed state.
    var armedShapeTool: ShapeToolKind?

    /// Whether the freehand pen tool is armed (E3b design call 1). Unlike a shape, the pen
    /// STAYS armed until Esc, another tool, or tapping the Pen button again (Freeform/
    /// Keynote behaviour). On the iPad an Apple Pencil draws the pen even while unarmed, so
    /// the canvas reads touch type separately; this flag only governs finger drawing and the
    /// toolbar's active state.
    var armedPen = false

    /// The pen's colour and width, persisted for the editing session (E3b design call 3).
    var penStyle = PenStyle.default

    /// Whether the pen palette popover is showing (iPad: opened by the Pencil squeeze or the
    /// Pen button's menu; design call 3/5). Observed so the screen presents it.
    var penPalettePresented = false

    /// Arms the pen and disarms any shape tool (the two creation tools are exclusive).
    func armPen() { armedPen = true; armedShapeTool = nil }

    /// Arms a shape tool and disarms the pen.
    func armShape(_ kind: ShapeToolKind) { armedShapeTool = kind; armedPen = false }

    /// Disarms every creation tool (Esc, leaving edit mode).
    func disarmTools() { armedShapeTool = nil; armedPen = false }
}

/// The state driving the text-edit popover: which text element, the point to anchor the
/// popover to (a fraction of the editing container's visible area, so the arrow points
/// at the run), and the run's current string. `Identifiable` so a `.popover(item:)`
/// tracks it.
struct TextEditRequest: Equatable, Identifiable {
    /// The text element's id (also the popover's identity).
    let id: Int
    /// The anchor point as a fraction (0…1 each axis) of the editing container; the
    /// popover's arrow points here.
    var anchor: UnitPoint
    /// The run's string when the popover opened.
    var initialText: String
}
