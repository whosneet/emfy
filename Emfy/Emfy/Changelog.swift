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
            version: "3.0",
            build: "8",
            date: "November 2026",
            changes: version3Changes
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

    /// The 3.0 headline changes. The common bullets ship in every build; the Mac
    /// direct-download (GitHub) build adds one line for the features only it has —
    /// in-app updates and the local MCP server — via `EMFY_DMG`, so the App Store
    /// build never advertises an updater or server it doesn't contain.
    private static var version3Changes: [String] {
        var changes = [
            "Edit, create and save metafiles. Open EMF, WMF and their compressed .emz and .wmz forms, then change them: select and transform, draw shapes and freehand with Apple Pencil, add and style text, work in layers, and align and snap to a grid. Start a new drawing from scratch, save in place, or revert to the version you opened.",
            "On iPhone and iPad too. A viewer with razor-sharp zoom at any scale, light editing on iPhone with a full-editor toggle, and Quick Look previews and thumbnails in Files, Mail and Messages.",
            "Share in any format. Export to PNG, PDF and SVG, print, copy or drag out as true vector, and convert many files at once.",
            "Find and read the words. Find text across a drawing, read the text inside pictures on your device, show a Translate overlay, and surface your drawings in Spotlight.",
            "AI that stays in your control. Describe or ask about a drawing, add titles and tags, run an accessibility Check with fixes, compare versions, recolour, translate in place, or create a new drawing from a description. It runs on your device by default with Apple Intelligence; your own AI provider is used only with your key, after you consent, and Arrley receives nothing.",
            "Built for the Mac. A single library window with multiple windows, Shortcuts, Siri and Finder Services, and a record inspector that steps through a file.",
            "Sharper, faster rendering. Arcs, pies and gradients, pattern brushes, small and ANSI text, and more clipping — drawn faster, with a bitmap cache and adaptive tiles for large files.",
        ]
        #if EMFY_DMG
        changes.append("Mac direct-download version: automatic in-app updates when a new release is published, and a local MCP server so AI tools you run can read your drawings.")
        #endif
        return changes
    }
}
