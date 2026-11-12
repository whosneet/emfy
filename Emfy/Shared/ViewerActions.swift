import SwiftUI

/// The focused viewer's menu-exposable actions, published to the scene by whichever
/// viewer is showing and read by the menu commands through `@FocusedValue`. Shared by
/// both platforms (C4b K1): the Mac menu bar drives whichever library window is key;
/// on iPad the menu bar / key-command HUD fires these even while the sidebar holds
/// first responder, which a view-level `.keyboardShortcut` cannot (the K1 bug).
///
/// `focusedSceneValue` is scene-scoped, not focus-scoped, so the value resolves from
/// the focused window regardless of which view inside it has keyboard focus.
///
/// The zoom actions are platform-neutral. The Mac fills in export/share; iOS leaves
/// those as no-ops and instead provides the immersive chrome and inspector toggles.
struct ViewerActions {
    var isDocumentLoaded: Bool
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fit: () -> Void
    var actualSize: () -> Void

    // Mac File ▸ Export / Share (iOS leaves these as no-ops — it shares through the
    // bottom toolbar's Share menu and its sheets).
    var exportPNG: () -> Void = {}
    var exportPDF: () -> Void = {}
    var exportSVG: () -> Void = {}
    var shareFile: () -> Void = {}
    var sharePNG: () -> Void = {}
    var sharePDF: () -> Void = {}
    var shareSVG: () -> Void = {}

    /// Copies the current file's privacy-safe diagnostic report to the clipboard
    /// (S1a-6), surfaced in the Mac Help menu. `nil` when no file is shown, so the
    /// menu item reads as disabled.
    var copyDiagnosticReport: (() -> Void)? = nil

    // Editing (E2a): Mac File ▸ Save and Revert to Opened Version. `nil` disables the
    // menu item — Save is `nil` unless there are unsaved edits; Revert is `nil` unless
    // an opened-version snapshot exists and the Settings toggle is on.
    var save: (() -> Void)? = nil
    var revertToOpenedVersion: (() -> Void)? = nil

    // Editing (E2b): Mac Edit ▸ Select All / Deselect, present only while editing.
    // Select All is `nil` unless in edit mode; Deselect is `nil` unless something is
    // selected.
    var selectAllElements: (() -> Void)? = nil
    var deselectElements: (() -> Void)? = nil

    // Editing (E2c): Edit ▸ Delete, present only while editing with a selection
    // (`nil` disables the menu item).
    var deleteSelection: (() -> Void)? = nil

    // Editing (E3c): Insert ▸ Image…, present only while editing (`nil` disables the
    // menu item). Opens the image file picker and inserts the chosen image.
    var insertImage: (() -> Void)? = nil

    // Editing (E3d): the Arrange menu — reorder the selection within its layer. Each is
    // `nil` (the menu item disabled) unless in edit mode with a non-empty selection.
    var bringToFront: (() -> Void)? = nil
    var bringForward: (() -> Void)? = nil
    var sendBackward: (() -> Void)? = nil
    var sendToBack: (() -> Void)? = nil

    // Editing (E3e): Arrange ▸ Align / Distribute. `align` is `nil` unless in edit mode
    // with a non-empty selection; `distribute` additionally needs `canDistribute` (3+).
    var alignSelection: ((EditorArrange.Alignment) -> Void)? = nil
    var distributeSelection: ((EditorArrange.Distribution) -> Void)? = nil
    var canDistribute: Bool = false

    // Editing (E3e): View ▸ grid + snapping. The toggles are `nil` unless editing; the
    // flags drive the menu checkmarks and the "Show/Hide Grid" label.
    var toggleGrid: (() -> Void)? = nil
    var toggleSnapToGrid: (() -> Void)? = nil
    var toggleSnapToGuides: (() -> Void)? = nil
    var isGridShown: Bool = false
    var isSnapToGrid: Bool = true
    var isSnapToGuides: Bool = true

    // iOS/iPadOS immersive chrome + the Info inspector, surfaced in the iOS View menu
    // (K1). `nil` on the Mac, which has its own View toggles and toolbar.
    var toggleChrome: (() -> Void)? = nil
    var toggleInfo: (() -> Void)? = nil
    /// Whether the chrome is currently hidden, so the iOS View menu can label its
    /// toggle "Show Controls" vs "Hide Controls".
    var isChromeHidden: Bool = false
}

extension FocusedValues {
    /// The focused window's viewer actions, or `nil` when no viewer is showing
    /// (menu items then read as disabled).
    @Entry var viewerActions: ViewerActions?
}
