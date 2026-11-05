import Foundation
import Observation

/// Emfy's single settings store (S1a). One `@Observable` object backed by
/// `UserDefaults`, injected into the SwiftUI environment on both platforms.
///
/// **Every default reproduces Emfy's behaviour before Settings existed**, so a
/// user who never opens Settings sees no change. Each setting is a stored
/// property (so `@Observable` tracks it) that mirrors to `UserDefaults` on write
/// and loads from it on `init`; assignments in `init` don't trigger `didSet`, so
/// construction reads without writing back. `UserDefaults` is injectable so tests
/// use a throwaway suite, never the real domain.
///
/// Keys are namespaced under `settings.*`. S1b will move only the (not-yet-added)
/// Quick Look keys into an App Group suite, so the key set stays easy to split.
@MainActor
@Observable
final class EmfySettings {
    /// The shared app instance (standard defaults). Tests construct their own.
    static let shared = EmfySettings()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Viewer

    /// Default zoom when a file opens. Today the viewer opens fit-to-window
    /// (`ViewerFit.fitScale`, never upscaling), so `.fit` is the default.
    var defaultZoomOnOpen: DefaultZoom {
        didSet { defaults.set(defaultZoomOnOpen.rawValue, forKey: Keys.defaultZoomOnOpen) }
    }
    /// The viewer page background. Today the page is painted white, so
    /// `.whitePage` is the default (exports keep their own background setting).
    var pageBackground: PageBackground {
        didSet { defaults.set(pageBackground.rawValue, forKey: Keys.pageBackground) }
    }
    /// Whether the partial-support banner shows. Today it shows, so `true`.
    var showPartialSupportBanner: Bool {
        didSet { defaults.set(showPartialSupportBanner, forKey: Keys.showPartialSupportBanner) }
    }

    // MARK: Viewer extras

    /// How a dark drawing adapts in dark mode. Today there is no adaptation, so
    /// `.off` is the default (viewer only — never exports or thumbnails).
    var darkPageMode: DarkPageMode {
        didSet { defaults.set(darkPageMode.rawValue, forKey: Keys.darkPageMode) }
    }
    /// The paper drop shadow. Today it is drawn on both platforms, so `true`.
    var pageShadow: Bool {
        didSet { defaults.set(pageShadow, forKey: Keys.pageShadow) }
    }
    /// Where an opened file lands. Today it opens in the front window, so
    /// `.frontWindow` (the option is hidden where multiple windows aren't allowed).
    var openFilesIn: OpenFilesIn {
        didSet { defaults.set(openFilesIn.rawValue, forKey: Keys.openFilesIn) }
    }
    /// Mac trackpad/mouse scroll behaviour. Today scroll pans, so `.pan` (Mac only).
    var macScrollAction: MacScrollAction {
        didSet { defaults.set(macScrollAction.rawValue, forKey: Keys.macScrollAction) }
    }

    // MARK: Library

    /// How many recents to keep. Today's cap is 50, so `.fifty`.
    var recentsToKeep: RecentsCap {
        didSet { defaults.set(recentsToKeep.rawValue, forKey: Keys.recentsToKeep) }
    }
    /// Reopen the last file at launch. Default ON — reproduces today's per-window
    /// scene restoration (owner, S1a review).
    var reopenLastFileAtLaunch: Bool {
        didSet { defaults.set(reopenLastFileAtLaunch, forKey: Keys.reopenLastFileAtLaunch) }
    }
    /// Show What's New after an update. Today it shows, so `true`.
    var showWhatsNewAfterUpdates: Bool {
        didSet { defaults.set(showWhatsNewAfterUpdates, forKey: Keys.showWhatsNewAfterUpdates) }
    }

    // MARK: Library extras

    /// Recents ordering. Today recents sort by most-recently-opened, so `.date`.
    var sortRecentsBy: SortOrder {
        didSet { defaults.set(sortRecentsBy.rawValue, forKey: Keys.sortRecentsBy) }
    }
    /// The iOS recents layout. Today's look is a grid, so `.grid` (the Mac
    /// sidebar is always a list regardless of this).
    var recentsLayout: RecentsLayout {
        didSet { defaults.set(recentsLayout.rawValue, forKey: Keys.recentsLayout) }
    }
    /// Thumbnail size. Today's look is medium, so `.medium`.
    var thumbnailSize: ThumbnailSize {
        didSet { defaults.set(thumbnailSize.rawValue, forKey: Keys.thumbnailSize) }
    }
    /// Private mode — keeps no history. Off today (the feature is new), so `false`.
    var privateMode: Bool {
        didSet { defaults.set(privateMode, forKey: Keys.privateMode) }
    }

    // MARK: Export

    /// Default PNG export scale. Today's scale is 2×, so `.x2` (keeps Mac/iOS
    /// output matching).
    var defaultPNGScale: PNGScale {
        didSet { defaults.set(defaultPNGScale.rawValue, forKey: Keys.defaultPNGScale) }
    }
    /// PNG export background. Today exports are filled white, so `.white`.
    var pngBackground: PNGBackground {
        didSet { defaults.set(pngBackground.rawValue, forKey: Keys.pngBackground) }
    }
    /// The primary export format. Today the primary Export command is PNG, so `.png`.
    var defaultExportFormat: ExportFormat {
        didSet { defaults.set(defaultExportFormat.rawValue, forKey: Keys.defaultExportFormat) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultZoomOnOpen = Self.string(defaults, Keys.defaultZoomOnOpen, default: .fit)
        pageBackground = Self.string(defaults, Keys.pageBackground, default: .whitePage)
        showPartialSupportBanner = Self.bool(defaults, Keys.showPartialSupportBanner, default: true)
        darkPageMode = Self.string(defaults, Keys.darkPageMode, default: .off)
        pageShadow = Self.bool(defaults, Keys.pageShadow, default: true)
        openFilesIn = Self.string(defaults, Keys.openFilesIn, default: .frontWindow)
        macScrollAction = Self.string(defaults, Keys.macScrollAction, default: .pan)
        recentsToKeep = Self.int(defaults, Keys.recentsToKeep, default: .fifty)
        reopenLastFileAtLaunch = Self.bool(defaults, Keys.reopenLastFileAtLaunch, default: true)
        showWhatsNewAfterUpdates = Self.bool(defaults, Keys.showWhatsNewAfterUpdates, default: true)
        sortRecentsBy = Self.string(defaults, Keys.sortRecentsBy, default: .date)
        recentsLayout = Self.string(defaults, Keys.recentsLayout, default: .grid)
        thumbnailSize = Self.string(defaults, Keys.thumbnailSize, default: .medium)
        privateMode = Self.bool(defaults, Keys.privateMode, default: false)
        defaultPNGScale = Self.int(defaults, Keys.defaultPNGScale, default: .x2)
        pngBackground = Self.string(defaults, Keys.pngBackground, default: .white)
        defaultExportFormat = Self.string(defaults, Keys.defaultExportFormat, default: .png)
    }

    // MARK: - Backing reads (behaviour-preserving fallbacks)

    private nonisolated static func bool(_ d: UserDefaults, _ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    private nonisolated static func string<E: RawRepresentable>(_ d: UserDefaults, _ key: String, default def: E) -> E
    where E.RawValue == String {
        guard let raw = d.string(forKey: key), let value = E(rawValue: raw) else { return def }
        return value
    }

    private nonisolated static func int<E: RawRepresentable>(_ d: UserDefaults, _ key: String, default def: E) -> E
    where E.RawValue == Int {
        guard d.object(forKey: key) != nil, let value = E(rawValue: d.integer(forKey: key)) else { return def }
        return value
    }

    // MARK: - Keys

    private enum Keys {
        static let defaultZoomOnOpen = "settings.viewer.defaultZoomOnOpen"
        static let pageBackground = "settings.viewer.pageBackground"
        static let showPartialSupportBanner = "settings.viewer.showPartialSupportBanner"
        static let darkPageMode = "settings.viewer.darkPageMode"
        static let pageShadow = "settings.viewer.pageShadow"
        static let openFilesIn = "settings.viewer.openFilesIn"
        static let macScrollAction = "settings.viewer.macScrollAction"
        static let recentsToKeep = "settings.library.recentsToKeep"
        static let reopenLastFileAtLaunch = "settings.library.reopenLastFileAtLaunch"
        static let showWhatsNewAfterUpdates = "settings.library.showWhatsNewAfterUpdates"
        static let sortRecentsBy = "settings.library.sortRecentsBy"
        static let recentsLayout = "settings.library.recentsLayout"
        static let thumbnailSize = "settings.library.thumbnailSize"
        static let privateMode = "settings.library.privateMode"
        static let defaultPNGScale = "settings.export.defaultPNGScale"
        static let pngBackground = "settings.export.pngBackground"
        static let defaultExportFormat = "settings.export.defaultExportFormat"
    }
}

// MARK: - Option types
//
// Nested so they namespace cleanly (and `ExportFormat` doesn't clash with the
// iOS export-flow type of the same name). Nested types of a `@MainActor` class
// are not themselves actor-isolated, so they're usable from any context.

extension EmfySettings {
    enum DefaultZoom: String, CaseIterable, Sendable { case fit, actualSize }
    enum PageBackground: String, CaseIterable, Sendable { case whitePage, checkerboard, matchAppearance }
    enum DarkPageMode: String, CaseIterable, Sendable { case off, dim, invert }
    enum OpenFilesIn: String, CaseIterable, Sendable { case frontWindow, newWindow }
    enum MacScrollAction: String, CaseIterable, Sendable { case pan, zoom }
    enum SortOrder: String, CaseIterable, Sendable { case date, name, size }
    enum RecentsLayout: String, CaseIterable, Sendable { case grid, list }
    enum ThumbnailSize: String, CaseIterable, Sendable { case small, medium, large }
    enum PNGBackground: String, CaseIterable, Sendable { case white, transparent }
    enum ExportFormat: String, CaseIterable, Sendable { case png, pdf }

    /// The PNG export multiplier; its raw value is the integer scale.
    enum PNGScale: Int, CaseIterable, Sendable {
        case x1 = 1, x2 = 2, x3 = 3
        var multiplier: Int { rawValue }
    }

    /// Allowed recents caps; its raw value is the count.
    enum RecentsCap: Int, CaseIterable, Sendable {
        case ten = 10, twentyFive = 25, fifty = 50, hundred = 100
        var count: Int { rawValue }
    }
}
