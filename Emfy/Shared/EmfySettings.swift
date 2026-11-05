import EMFRender
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
/// Keys are namespaced under `settings.*`. The four **Rendering** keys (S1b) go
/// through a SEPARATE injectable `sharedDefaults` so the next slice can point it
/// at the App Group suite — letting the Quick Look extensions read the same
/// rendering choices — without disturbing the rest. For now `sharedDefaults`
/// defaults to `.standard`, exactly as the main store does, so there is no
/// behavioural change yet.
@MainActor
@Observable
final class EmfySettings {
    /// The shared app instance. The main store is `.standard`; the Rendering and
    /// Quick Look keys go through the **App Group** suite so the Quick Look
    /// extensions read the same choices (S1b-2b). If the group can't be resolved
    /// the shared store falls back to `.standard`, exactly as before. Tests
    /// construct their own with explicit suites.
    static let shared: EmfySettings = {
        guard let group = AppGroup.defaults() else { return EmfySettings() }
        migrateSharedKeysIfNeeded(from: .standard, to: group)
        return EmfySettings(sharedDefaults: group)
    }()

    @ObservationIgnored private let defaults: UserDefaults
    /// The defaults the four Rendering keys (S1b) persist through — a clean seam
    /// so the next slice can swap in the App Group suite without touching the rest.
    @ObservationIgnored private let sharedDefaults: UserDefaults

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

    // MARK: Rendering (S1b — persisted through `sharedDefaults`)

    /// Edge treatment: smooth antialiasing (today's behaviour) or crisp hard pixel
    /// edges like Windows. Default `.smooth`, matching `RenderOptions.default`.
    var renderEdges: RenderEdges {
        didSet { sharedDefaults.set(renderEdges.rawValue, forKey: Keys.renderEdges) }
    }
    /// For an EMF+ dual file (one carrying both an EMF+ and a GDI description),
    /// which to show. Default `.emfPlus`, matching `RenderOptions.default`.
    var emfPlusSource: EMFPlusSource {
        didSet { sharedDefaults.set(emfPlusSource.rawValue, forKey: Keys.emfPlusSource) }
    }
    /// Whether a WMF's complete, parseable built-in EMF supersedes its own records.
    /// Default `true`, matching `RenderOptions.default`.
    var useEmbeddedEMF: Bool {
        didSet { sharedDefaults.set(useEmbeddedEMF, forKey: Keys.useEmbeddedEMF) }
    }
    /// The user's missing-family substitution table, consulted before the built-in
    /// table when a drawing asks for a font this device doesn't have. Persisted as
    /// JSON and kept within bounds on every write (`fontSubstitutionRowLimit` rows,
    /// `fontSubstitutionNameLimit` characters per name); the reassignment inside
    /// `didSet` is idempotent (`bounded(bounded) == bounded`), so it settles after
    /// one pass and persists exactly once. Default `[]`, matching
    /// `RenderOptions.default`.
    var fontSubstitutions: [FontSubstitutionEntry] = [] {
        didSet {
            let bounded = Self.bounded(fontSubstitutions)
            if bounded != fontSubstitutions {
                fontSubstitutions = bounded
            } else {
                sharedDefaults.set(Self.encodeSubstitutions(bounded), forKey: Keys.fontSubstitutions)
            }
        }
    }

    // MARK: Quick Look options (S1b-2b — persisted through `sharedDefaults`)

    /// The background a Finder/Files thumbnail is drawn on. Default `.white`,
    /// matching today's extensions (dark ink stays legible on a white page).
    var thumbnailBackground: SharedRenderSettings.ThumbnailBackground {
        didSet { sharedDefaults.set(thumbnailBackground.rawValue, forKey: Keys.thumbnailBackground) }
    }
    /// The Quick Look preview long-edge cap. Default `.standard` — today's caps
    /// exactly, so a preview is byte-identical until the user raises it.
    var previewSharpness: SharedRenderSettings.PreviewSharpness {
        didSet { sharedDefaults.set(previewSharpness.rawValue, forKey: Keys.previewSharpness) }
    }

    /// The four Rendering settings mapped to EMFKit's `RenderOptions`, ready to pass
    /// to every render/export call (S1b). Incomplete substitution rows (a blank
    /// requested or replacement family) are dropped so a half-entered row never
    /// shadows the built-in table. Equals `RenderOptions.default` while every
    /// Rendering setting is at its default.
    var renderOptions: RenderOptions {
        RenderOptions(
            antialiasing: renderEdges == .crisp ? .crisp : .smooth,
            fontSubstitutions: fontSubstitutions.compactMap { entry in
                let requested = entry.requested.trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !requested.isEmpty, !replacement.isEmpty else { return nil }
                return FontSubstitution(requestedFamily: requested, replacementFamily: replacement)
            },
            emfPlusArbitration: emfPlusSource == .gdi ? .gdi : .emfPlus,
            useEmbeddedEMF: useEmbeddedEMF
        )
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard, sharedDefaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults
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
        // Rendering (S1b) reads from `sharedDefaults`. As with every other setting,
        // assignment in `init` doesn't trigger `didSet`, so construction reads without
        // writing back; the decoded table is already bounded.
        renderEdges = Self.string(sharedDefaults, Keys.renderEdges, default: .smooth)
        emfPlusSource = Self.string(sharedDefaults, Keys.emfPlusSource, default: .emfPlus)
        useEmbeddedEMF = Self.bool(sharedDefaults, Keys.useEmbeddedEMF, default: true)
        fontSubstitutions = Self.decodeSubstitutions(sharedDefaults, Keys.fontSubstitutions)
        thumbnailBackground = Self.string(sharedDefaults, Keys.thumbnailBackground, default: .white)
        previewSharpness = Self.string(sharedDefaults, Keys.previewSharpness, default: .standard)
    }

    // MARK: - App Group migration (one-time)

    /// A one-time flag in the destination suite so the migration runs exactly once
    /// per App Group container.
    private nonisolated static let migratedFlagKey = "settings.sharedKeys.migratedToAppGroup"

    /// Copies any shared-suite key that lives in `source` but not yet in
    /// `destination` across once — so a user who set Rendering options before the
    /// App Group existed (when `sharedDefaults` was `.standard`) keeps them. A
    /// per-container flag makes it idempotent; it never overwrites a value already
    /// in the group. `nonisolated` so `shared` can run it before construction and
    /// tests can drive it with throwaway suites.
    nonisolated static func migrateSharedKeysIfNeeded(from source: UserDefaults, to destination: UserDefaults) {
        guard !destination.bool(forKey: migratedFlagKey) else { return }
        for key in SharedRenderSettings.Keys.all
        where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) {
                destination.set(value, forKey: key)
            }
        }
        destination.set(true, forKey: migratedFlagKey)
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

    // MARK: - Font substitution table (JSON, bounded, corruption-tolerant)

    /// The most substitution rows the table keeps. Matches
    /// `FontMapper.userSubstitutionLimit` (the renderer's own consumption cap).
    /// `nonisolated` so the UI footers and bounds can reference it off the actor.
    nonisolated static let fontSubstitutionRowLimit = 64
    /// The longest family name a row keeps, in characters.
    nonisolated static let fontSubstitutionNameLimit = 128

    /// Clamps a table to the row and name-length limits (idempotent).
    nonisolated static func bounded(_ entries: [FontSubstitutionEntry]) -> [FontSubstitutionEntry] {
        entries.prefix(fontSubstitutionRowLimit).map { entry in
            FontSubstitutionEntry(
                id: entry.id,
                requested: String(entry.requested.prefix(fontSubstitutionNameLimit)),
                replacement: String(entry.replacement.prefix(fontSubstitutionNameLimit))
            )
        }
    }

    private nonisolated static func encodeSubstitutions(_ entries: [FontSubstitutionEntry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data()
    }

    /// Decodes the persisted table, bounded. Corrupt or absent data falls back to
    /// an empty table — a hostile or stale blob never throws or over-allocates.
    private nonisolated static func decodeSubstitutions(_ d: UserDefaults, _ key: String) -> [FontSubstitutionEntry] {
        guard let data = d.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FontSubstitutionEntry].self, from: data)
        else { return [] }
        return bounded(decoded)
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
        // Rendering (S1b) and Quick Look options (S1b-2b) persist through
        // `sharedDefaults` (the App Group suite). The key STRINGS live in
        // `SharedRenderSettings.Keys` — the single source of truth the Quick Look
        // extensions also read — so the writer here and that reader never drift.
        static let renderEdges = SharedRenderSettings.Keys.renderEdges
        static let emfPlusSource = SharedRenderSettings.Keys.emfPlusSource
        static let useEmbeddedEMF = SharedRenderSettings.Keys.useEmbeddedEMF
        static let fontSubstitutions = SharedRenderSettings.Keys.fontSubstitutions
        static let thumbnailBackground = SharedRenderSettings.Keys.thumbnailBackground
        static let previewSharpness = SharedRenderSettings.Keys.previewSharpness
    }
}

// MARK: - Font substitution entry

/// One user-defined missing-family substitution row (S1b Settings › Rendering).
/// A UI-facing, persistable mirror of EMFKit's render-time `FontSubstitution`: it
/// carries a stable `id` for SwiftUI list identity and editing, and plain strings
/// for the requested and replacement family names. Mapped to `FontSubstitution`
/// (dropping blank rows) in `EmfySettings.renderOptions`.
struct FontSubstitutionEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// The family name as it appears in the drawing, typed freely by the user.
    var requested: String
    /// The installed family to use instead.
    var replacement: String

    init(id: UUID = UUID(), requested: String, replacement: String) {
        self.id = id
        self.requested = requested
        self.replacement = replacement
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
    enum RenderEdges: String, CaseIterable, Sendable { case smooth, crisp }
    enum EMFPlusSource: String, CaseIterable, Sendable { case emfPlus, gdi }

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
