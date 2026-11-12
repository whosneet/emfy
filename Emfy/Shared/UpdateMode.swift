#if EMFY_DMG
import Foundation

/// The four update modes (U1 §10.1) plus the pure policy, throttle and first-launch
/// decisions that drive the updater. All value types with unit tests; the
/// `UpdateController` is the only stateful, side-effecting consumer.
enum UpdateMode: String, CaseIterable, Codable, Sendable {
    /// Never check automatically.
    case off
    /// Check on launch and notify; the user starts the download and install.
    case notifyOnLaunch
    /// Check, download and verify in the background, then offer "Restart to Update".
    case autoDownload
    /// Check, download, verify and swap silently on the next quit.
    case autoUpdate
}

/// What the updater does once a newer, verifiable release is found, by mode.
enum PostFindAction: Equatable, Sendable {
    /// Surface it and wait for the user (notifyOnLaunch).
    case notify
    /// Download + verify + stage, then offer "Restart to Update" (autoDownload).
    case downloadAndOffer
    /// Download + verify + stage, then swap on the next quit (autoUpdate).
    case downloadAndStageSilently
    /// Do nothing (off — this is never reached because we don't check when off).
    case none
}

enum UpdatePolicy {
    /// Whether the updater checks at launch / on the timer for this mode.
    static func checksAutomatically(_ mode: UpdateMode) -> Bool {
        mode != .off
    }

    /// What to do after a check finds an installable update.
    static func actionAfterFound(_ mode: UpdateMode) -> PostFindAction {
        switch mode {
        case .off: return .none
        case .notifyOnLaunch: return .notify
        case .autoDownload: return .downloadAndOffer
        case .autoUpdate: return .downloadAndStageSilently
        }
    }

    /// Whether a staged, verified update should be swapped in on quit. In
    /// `autoUpdate` it always swaps; in `autoDownload` only after the user pressed
    /// "Restart to Update"; otherwise never.
    static func swapOnQuit(mode: UpdateMode, userRequestedInstall: Bool, hasStaged: Bool) -> Bool {
        guard hasStaged else { return false }
        switch mode {
        case .autoUpdate: return true
        case .autoDownload: return userRequestedInstall
        case .notifyOnLaunch: return userRequestedInstall
        case .off: return false
        }
    }
}

/// The at-most-every-24h check throttle. A check is allowed at launch (no prior
/// check) and thereafter only once the interval has elapsed.
enum UpdateThrottle {
    static let defaultInterval: TimeInterval = 24 * 60 * 60

    static func shouldCheck(now: Date, lastCheck: Date?, interval: TimeInterval = defaultInterval) -> Bool {
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

/// The pure decision on whether the running bundle can be replaced in place. The
/// controller gathers the three facts from the filesystem; this maps them to a
/// typed refusal (U1: refuse a translocated, read-only, or non-writable location).
enum UpdateInstallGuard {
    static func check(isWritable: Bool, isOnReadOnlyVolume: Bool, isTranslocated: Bool) -> UpdateError? {
        if isTranslocated { return .translocated }
        if isOnReadOnlyVolume { return .readOnlyVolume }
        if !isWritable { return .targetNotWritable }
        return nil
    }
}

/// The one-time first-launch "Keep Emfy up to date?" decision. The sheet shows only
/// until the user has chosen a mode; after that it never shows again.
enum UpdateFirstLaunch {
    /// Show the sheet when no mode has been chosen yet.
    static func shouldPrompt(hasChosenMode: Bool) -> Bool {
        !hasChosenMode
    }

    /// The default mode pre-selected in the sheet (owner: "Notify me").
    static let defaultMode: UpdateMode = .notifyOnLaunch
}
#endif
