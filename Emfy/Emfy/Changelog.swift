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
            version: "3.1",
            build: "6",
            date: "November 2026",
            changes: [
                "Windows Metafile (.wmf) files now open, preview, and thumbnail, alongside EMF.",
                "Compressed metafiles open too: .wmz (gzip-wrapped WMF) and .emz (gzip-wrapped EMF).",
                "WMF coverage spans the record types LibreOffice exports; when a WMF carries a complete embedded EMF, Emfy plays that for higher fidelity.",
                "New iPhone and iPad app: a viewer with sharp zoom at any scale, file details, and sharing or export to PNG and PDF.",
                "Quick Look previews and thumbnails for EMF and WMF files in Files, Mail, and Messages on iPhone and iPad.",
                "The iPhone and iPad app supports iPhone Duo.",
                "Steadier rendering of unusual and malformed metafiles.",
            ]
        ),
        ChangelogEntry(
            version: "2.0.2",
            build: "5",
            date: "November 2026",
            changes: [
                "Refreshed app icon with the Liquid Glass effect.",
                "Leaner build: unused code is now stripped from the app and its Quick Look extensions.",
            ]
        ),
        ChangelogEntry(
            version: "2.0.1",
            build: "4",
            date: "November 2026",
            changes: [
                "Verified on macOS 27.2: the viewer, Quick Look previews, and Finder thumbnails.",
                "Fixed a hang on macOS 27.2 where rendering text could stall indefinitely when several previews or thumbnails were drawn at once.",
                "Text now renders using only the fonts installed on your Mac, so opening or previewing a file can never trigger a font download.",
            ]
        ),
        ChangelogEntry(
            version: "2.0",
            build: "3",
            date: "August 2026",
            changes: [
                "Full EMF+ (GDI+) rendering — vector shapes, gradients, images, and text now draw in the viewer, Quick Look previews, and Finder thumbnails.",
                "Dual-format files now play their higher-fidelity EMF+ content instead of the GDI fallback.",
                "Files whose drawing content exists only as EMF+ now render fully, instead of showing a partial-rendering notice.",
                "Render Details now itemizes any EMF+ feature Emfy approximated or skipped.",
                "Rendering fidelity: rotated text, standard dashed pens, elliptical arc angles, physical font and page units, and text wrapping now match GDI+.",
                "Hardened against malformed files — stricter parsing limits, and Render Details now reports any EMF+ content that couldn't be read.",
            ]
        ),
        ChangelogEntry(
            version: "1.4",
            build: "2",
            date: "August 2026",
            changes: [
                "Large embedded bitmaps are now decoded only at the size they are shown, reducing memory use in Quick Look previews, Finder thumbnails, and the viewer window.",
                "Render Details now notes when a bitmap was decoded below its full resolution — no visible detail is lost.",
                "Expanded automated rendering coverage for Chinese, Japanese, and Korean text.",
            ]
        ),
        ChangelogEntry(
            version: "1.3",
            build: "1",
            date: "August 2026",
            changes: [
                "The viewer canvas now follows the system appearance, so the window and toolbar stay readable in Dark Mode.",
            ]
        ),
        ChangelogEntry(
            version: "1.2",
            build: "1",
            date: "July 2026",
            changes: [
                "Oversized embedded bitmaps are now skipped before they can use excessive memory, keeping the viewer and Quick Look more resilient to hostile files.",
                "New Render Details panel shows parser diagnostics and rendering notes, including a clear no-diagnostics state.",
                "File > Open… is always available with Command-O, while Emfy continues to avoid creating blank documents.",
            ]
        ),
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
