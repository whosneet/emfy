import SwiftUI

/// The device family the editor-depth decision needs. A platform-free mirror of
/// `UIUserInterfaceIdiom`, so the resolver is pure and unit-testable on macOS (the
/// EmfyTests bundle builds for macOS). The iOS viewer maps the real idiom to this.
enum EditorDeviceIdiom: Equatable, Sendable {
    case phone, pad, other
}

/// Which editor the iOS viewer presents (E4, docs/v3-plan §11.1): the full editor
/// (iPad-style — all tools, the inspector, selection handles, resize and rotate) or
/// the light editor (compact iPhone — a bottom toolbar of Markup, Colour, Text,
/// Delete, Undo and Redo, selection without handles).
enum EditorMode: Equatable, Sendable {
    case light
    case full

    /// Resolves the editor depth from the environment (design call 1):
    /// - iPad → full (regardless of its horizontal size class; Split View / Slide
    ///   Over on iPad still edits fully).
    /// - iPhone in a REGULAR horizontal size class (iPhone Duo's inner display, a
    ///   large landscape phone) → full.
    /// - iPhone in a COMPACT size class → light, unless the Settings "Full editor on
    ///   iPhone" toggle is on, in which case full.
    ///
    /// `idiom` is taken as an explicit parameter — the one place the editor consults
    /// the device family, since the editor depth is an owner decision keyed on it
    /// (§11.1), distinct from the size-class-only layout rule in §6.
    static func resolve(
        horizontalSizeClass: UserInterfaceSizeClass?,
        fullEditorOnIPhone: Bool,
        idiom: EditorDeviceIdiom
    ) -> EditorMode {
        if idiom == .pad { return .full }
        // iPhone (or any other non-pad family): a regular width is a large screen
        // (iPhone Duo, landscape) and gets the full editor.
        if horizontalSizeClass == .regular { return .full }
        // Compact iPhone: light by default; the Settings toggle opts into full.
        return fullEditorOnIPhone ? .full : .light
    }

    /// Whether the selection shows resize/rotate handles. Light mode shows only a
    /// selection outline (design call 2: "no handles in light mode"); full mode shows
    /// handles and enables resize and rotate.
    var showsSelectionHandles: Bool { self == .full }
}
