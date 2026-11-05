import Foundation

/// The window-routing policy for opening a file (v3-plan §9.1, §11.2). Pure and
/// platform-neutral so it is unit-tested without a scene: given where an open
/// came from and whether the platform can show more than one window, it decides
/// whether the file lands in the front window or a new one, and whether an
/// "Open in New Window" affordance should be shown at all — hidden on the iPhone
/// Duo outer display, which can't host a second window.
enum OpenRouting {
    /// Where an open request originated.
    enum Source: Equatable, Sendable {
        /// Finder / Files / Mail / Messages — `onOpenURL` or the app delegate's
        /// `application(_:open:)` fallback.
        case externalFileOpen
        /// The sidebar "Open…" button, or selecting a recent inside this window.
        case inWindowOpen
        /// File ▸ New Window (⌘N).
        case newWindowCommand
        /// The per-row "Open in New Window" context action.
        case openInNewWindow
    }

    /// The window an open request targets.
    enum Destination: Equatable, Sendable {
        /// Reuse the current/front window and set its selection.
        case frontWindow
        /// Spawn a window that owns its own selection.
        case newWindow
    }

    /// Routes an open request to a window.
    ///
    /// - A file arriving from outside opens in the front window and is added to
    ///   Recents (owner decision, §9.1); only when no window exists does it open
    ///   one.
    /// - An in-window open stays in that window.
    /// - ⌘N and "Open in New Window" make a new window where the platform allows
    ///   more than one, and fall back to the front window where it doesn't (the
    ///   Duo outer display, a single-scene phone).
    static func destination(
        for source: Source,
        hasOpenWindow: Bool,
        supportsMultipleWindows: Bool
    ) -> Destination {
        switch source {
        case .externalFileOpen:
            return hasOpenWindow ? .frontWindow : .newWindow
        case .inWindowOpen:
            return .frontWindow
        case .newWindowCommand, .openInNewWindow:
            return supportsMultipleWindows ? .newWindow : .frontWindow
        }
    }

    /// Whether to surface an "Open in New Window" / New Window affordance. Gated on
    /// multi-window support so it hides on the Duo outer display (Axiom
    /// iphone-duo.md: the system `supportsMultipleWindows` pattern).
    static func offersNewWindow(supportsMultipleWindows: Bool) -> Bool {
        supportsMultipleWindows
    }
}
