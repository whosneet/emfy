import Foundation

/// Decides whether to show the "What's New" screen, once per installed version
/// (v3-plan §10, C3b scope 7). Pure and injectable so the decision is unit-tested
/// without touching real `UserDefaults` or a window; the presentation (the macOS
/// Window, the iOS sheet) lives in the scenes and calls these helpers.
///
/// Owner rule (literal): a missing stored value counts as "show" — that covers a
/// fresh install and every existing 2.x user who never had the key. After it is
/// shown, the current version is recorded, so the same version never shows twice.
enum WhatsNew {
    /// The `UserDefaults` key holding the last version whose What's New was shown.
    static let lastSeenVersionKey = "whatsNew.lastSeenVersion"

    #if DEBUG
    /// A DEBUG-only launch argument that clears the stored version before deciding,
    /// so a test run can force the first-launch path (then a second run without it
    /// proves the once-per-version behaviour).
    static let resetLaunchArgument = "-emfy-reset-whats-new"
    #endif

    /// The core decision: show when nothing is stored (owner rule) or when the
    /// stored version differs from the current one. Pure — the unit test drives it.
    static func shouldShow(lastSeenVersion: String?, currentVersion: String) -> Bool {
        guard let lastSeenVersion else { return true }
        return lastSeenVersion != currentVersion
    }

    /// The decision gated by the "Show What's New after updates" setting (S1a-5):
    /// when the setting is off, What's New never presents on launch, whatever the
    /// stored version. Pure — the unit test drives it.
    static func shouldShow(enabled: Bool, lastSeenVersion: String?, currentVersion: String) -> Bool {
        enabled && shouldShow(lastSeenVersion: lastSeenVersion, currentVersion: currentVersion)
    }

    /// The launch-time decision, reading the stored version from `defaults`. In
    /// DEBUG, the reset launch argument clears the stored version first.
    static func shouldShowOnLaunch(
        defaults: UserDefaults = .standard,
        currentVersion: String = Changelog.latest.version,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        #if DEBUG
        if arguments.contains(resetLaunchArgument) {
            defaults.removeObject(forKey: lastSeenVersionKey)
        }
        #endif
        return shouldShow(lastSeenVersion: defaults.string(forKey: lastSeenVersionKey), currentVersion: currentVersion)
    }

    /// Records that the current version's What's New has been shown, so it won't
    /// show again until the version changes.
    static func recordShown(
        defaults: UserDefaults = .standard,
        currentVersion: String = Changelog.latest.version
    ) {
        defaults.set(currentVersion, forKey: lastSeenVersionKey)
    }
}

/// A once-per-launch guard for the What's New presentation. The decision is
/// once-per-version; this additionally keeps a second window/scene opened in the
/// same launch from presenting it again (macOS opens one Window, iOS one sheet).
@MainActor
enum WhatsNewPresenter {
    static var didPresentThisLaunch = false

    /// Returns `true` at most once per launch, and only when the version-gated
    /// decision says to show. Records the version as shown on the `true` result,
    /// so the next launch of the same version is silent.
    static func claimLaunchPresentation() -> Bool {
        guard !didPresentThisLaunch, WhatsNew.shouldShowOnLaunch() else { return false }
        didPresentThisLaunch = true
        WhatsNew.recordShown()
        return true
    }

    /// As `claimLaunchPresentation`, but gated by the "Show What's New after updates"
    /// setting (S1a-5). When the setting is off it returns `false` and records
    /// nothing — so turning the setting back on later still shows the latest.
    static func claimLaunchPresentation(enabled: Bool) -> Bool {
        guard enabled else { return false }
        return claimLaunchPresentation()
    }
}
