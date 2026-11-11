import CoreGraphics
import Observation

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
}
