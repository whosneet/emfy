import Foundation

/// Decides which recent a freshly-appeared library window selects (S1a-5 Library ›
/// Reopen last file at launch). Pure and platform-neutral so the choice is
/// unit-tested without a scene; the window applies it, then checks the entry still
/// exists.
///
/// An explicit request — a window opened by "Open in New Window" carrying an entry —
/// is always honoured, on both platforms, regardless of the setting: it's a direct
/// instruction, not a restoration. Otherwise the window's stored last selection is
/// restored only when "Reopen last file at launch" is on; with it off every window
/// starts empty (Mac and iPad/iPhone).
enum LaunchSelection {
    static func restored(reopenLastFile: Bool, requested: UUID?, stored: UUID?) -> UUID? {
        if let requested { return requested }
        return reopenLastFile ? stored : nil
    }
}
