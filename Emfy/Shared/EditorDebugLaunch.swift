#if DEBUG
import Foundation

/// DEBUG-only launch hook (design call E2b-8). Screenshots can't be scripted with a
/// pointer, so a launch-argument path opens a file, enters edit mode, and selects the
/// first N editable elements — so a launched app shows edit mode with selection
/// handles without any clicks:
///
///   -EmfyDebugOpen <path>   a file to open at launch
///   -EmfyDebugEdit YES      enter edit mode after it loads
///   -EmfyDebugSelect <n>    select the first n editable elements
///
/// The whole type is inside `#if DEBUG`, so Release contains none of its symbols
/// (proven with `nm`/`strings` on the Release build).
enum EditorDebugLaunch {
    /// The file to open at launch, or nil when the hook is inactive.
    static var openPath: String? { value(for: "-EmfyDebugOpen") }

    /// Whether to enter edit mode once the file loads.
    static var editOnOpen: Bool { (value(for: "-EmfyDebugEdit") ?? "NO").uppercased() == "YES" }

    /// How many editable elements to pre-select (0 = none).
    static var selectFirst: Int { value(for: "-EmfyDebugSelect").flatMap(Int.init) ?? 0 }

    /// `-EmfyDebugShot <basepath>`: when set, the Mac pane captures the window at fit
    /// and at 400% (to `<base>-fit.png` / `<base>-400.png`) then quits.
    static var screenshotBase: String? { value(for: "-EmfyDebugShot") }

    /// `-EmfyDebugInspector YES`: open the file-details/Format inspector after edit mode
    /// and selection, so a capture shows the Format panel (E2c).
    static var showInspector: Bool { (value(for: "-EmfyDebugInspector") ?? "NO").uppercased() == "YES" }

    /// `-EmfyDebugSelectText YES`: select the first text element (instead of the first N
    /// editable ids) so a capture shows the Text section (E2c screenshot 2).
    static var selectText: Bool { (value(for: "-EmfyDebugSelectText") ?? "NO").uppercased() == "YES" }

    /// `-EmfyDebugTextEdit YES`: open the text-edit popover on the first text element
    /// after entering edit mode, so a capture shows the popover (E2c design call 5).
    static var textEdit: Bool { (value(for: "-EmfyDebugTextEdit") ?? "NO").uppercased() == "YES" }

    /// Whether any E2c screenshot flag is driving this run (distinct capture path).
    static var isE2cCapture: Bool { showInspector || selectText || textEdit || recolorDelete }

    /// `-EmfyDebugRecolorDelete YES`: recolour the selection red, then delete the first
    /// selected element, so a capture shows the canvas updated by a recolour + delete
    /// (E2c acceptance screenshot 4).
    static var recolorDelete: Bool { (value(for: "-EmfyDebugRecolorDelete") ?? "NO").uppercased() == "YES" }

    /// `-EmfyDebugAppearance dark|light`: forces THIS app's appearance (never the
    /// system's) so a capture can show both, in-process. `nil` leaves it unchanged.
    static var appearance: String? { value(for: "-EmfyDebugAppearance")?.lowercased() }

    /// `-EmfyDebugScrollInspector YES`: scrolls the Format inspector to its Text section
    /// so a capture shows the font controls (E2c screenshot 2).
    static var scrollInspectorToText: Bool { (value(for: "-EmfyDebugScrollInspector") ?? "NO").uppercased() == "YES" }

    /// Whether the launch hook is driving this run.
    static var isActive: Bool { openPath != nil }

    /// A temp-directory COPY of `openPath`, so a DEBUG run never opens a tracked file
    /// (e.g. anything under `corpus/`) in place — an armed autosave could otherwise
    /// write into it. The original is always copied first; if the copy fails the path
    /// is refused (`nil`), so the run never falls back to opening the original.
    static func safeCopiedOpenPath() -> String? {
        guard let path = openPath else { return nil }
        let source = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyDebugOpen-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(source.lastPathComponent.isEmpty ? "debug.emf" : source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            // Refuse if, somehow, the copy still resolves inside a corpus directory.
            guard !destination.path.contains("/corpus/") else { return nil }
            return destination.path
        } catch {
            return nil
        }
    }

    private static func value(for key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
