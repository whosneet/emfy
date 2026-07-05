import Foundation

/// A single released version and the user-facing changes it shipped. Drives
/// both the What's New panel (latest entry) and the Changelog window (all
/// entries). Purely presentational data — no parsing or rendering here.
struct ChangelogEntry: Identifiable {
    var id: String { version }
    let version: String
    let build: String
    let date: String
    let changes: [String]
}

/// The app's release history, newest first. `latest` is the entry for the
/// version the user currently has installed.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.1",
            build: "2",
            date: "July 2026",
            changes: [
                "PNG and PDF export now work reliably, and Emfy tells you when an export can't be completed instead of failing silently.",
                "Emfy now uses a single Dock icon no matter how many files you open.",
                "EMF+ documents once again show the partial-rendering notice correctly.",
                "Large and unusual files are handled more robustly — no hangs or excessive memory use on malformed input.",
                "Quick Look previews and Finder thumbnails are more memory-efficient.",
                "New Help menu: Developer Documentation, What's New, Changelog, and Contact the Developer.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.0",
            build: "1",
            date: "July 2026",
            changes: [
                "First public release of Emfy.",
                "Quick Look spacebar previews and Finder thumbnails for .emf files.",
                "Renders vector shapes, paths, clipping, styled pens and brushes, transforms, text, and embedded bitmaps.",
                "Viewer with zoom, pan, fit-to-window, and export to PNG or true-vector PDF.",
            ]
        ),
    ]

    /// The most recent release — the version the running app corresponds to.
    static var latest: ChangelogEntry { entries[0] }
}
