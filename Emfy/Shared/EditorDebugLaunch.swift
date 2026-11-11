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

    /// Whether the launch hook is driving this run.
    static var isActive: Bool { openPath != nil }

    private static func value(for key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
