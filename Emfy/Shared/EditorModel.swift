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
