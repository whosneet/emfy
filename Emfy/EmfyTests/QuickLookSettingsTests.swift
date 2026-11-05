import EMFRender
import Foundation
import Testing

// Shared sources (EmfySettings, SharedRenderSettings, AppGroup) are compiled
// directly into this logic-test bundle, so they're in-module — no `import Emfy`.

/// S1b-2b unit tests: the two Quick Look settings persist through the App Group
/// seam, the extensions' `SharedRenderSettings` reader agrees with the app model
/// and tolerates hostile input, and the one-time `.standard` → App Group
/// migration runs exactly once. Multiplatform: macOS and the iOS simulator.
@Suite(.serialized)
struct QuickLookSettingsTests {

    @MainActor
    private func freshSuites() throws -> (main: UserDefaults, mainName: String, shared: UserDefaults, sharedName: String) {
        let mainName = "EmfyQLMain-\(UUID().uuidString)"
        let sharedName = "EmfyQLShared-\(UUID().uuidString)"
        let main = try #require(UserDefaults(suiteName: mainName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        return (main, mainName, shared, sharedName)
    }

    // MARK: - Quick Look settings defaults and persistence

    @Test @MainActor
    func quickLookDefaultsReproduceTodaysBehaviour() throws {
        let (main, mainName, shared, sharedName) = try freshSuites()
        defer {
            main.removePersistentDomain(forName: mainName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let s = EmfySettings(defaults: main, sharedDefaults: shared)
        #expect(s.thumbnailBackground == .white)
        #expect(s.previewSharpness == .standard)
    }

    @Test @MainActor
    func quickLookSettingsPersistThroughSharedDefaultsOnly() throws {
        let (main, mainName, shared, sharedName) = try freshSuites()
        defer {
            main.removePersistentDomain(forName: mainName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let s = EmfySettings(defaults: main, sharedDefaults: shared)
        s.thumbnailBackground = .transparent
        s.previewSharpness = .high

        // The two keys land in the shared suite, never the main store.
        #expect(main.object(forKey: SharedRenderSettings.Keys.thumbnailBackground) == nil)
        #expect(main.object(forKey: SharedRenderSettings.Keys.previewSharpness) == nil)
        #expect(shared.string(forKey: SharedRenderSettings.Keys.thumbnailBackground) == "transparent")
        #expect(shared.string(forKey: SharedRenderSettings.Keys.previewSharpness) == "high")

        // A fresh instance over the same suites observes the written values.
        let reloaded = EmfySettings(defaults: main, sharedDefaults: shared)
        #expect(reloaded.thumbnailBackground == .transparent)
        #expect(reloaded.previewSharpness == .high)
    }

    // MARK: - SharedRenderSettings reader (what the extensions call)

    @Test
    func readerFallsBackToDefaultsForNilAndEmptySuites() throws {
        // A nil suite (unentitled extension) → built-in defaults.
        let none = SharedRenderSettings.load(from: nil)
        #expect(none.renderOptions == RenderOptions.default)
        #expect(none.thumbnailBackground == .white)
        #expect(none.previewSharpness == .standard)

        // An empty suite reads the same defaults.
        let name = "EmfyReaderEmpty-\(UUID().uuidString)"
        let empty = try #require(UserDefaults(suiteName: name))
        defer { empty.removePersistentDomain(forName: name) }
        let loaded = SharedRenderSettings.load(from: empty)
        #expect(loaded.renderOptions == RenderOptions.default)
        #expect(loaded.thumbnailBackground == .white)
        #expect(loaded.previewSharpness == .standard)
    }

    /// The reader produces exactly the `RenderOptions` and Quick Look values the
    /// app persisted — so a Finder/Files preview matches the viewer. Includes a
    /// half-entered font row, which the reader drops just as the app's
    /// `renderOptions` does.
    @Test @MainActor
    func readerAgreesWithTheAppModel() throws {
        let (main, mainName, shared, sharedName) = try freshSuites()
        defer {
            main.removePersistentDomain(forName: mainName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let s = EmfySettings(defaults: main, sharedDefaults: shared)
        s.renderEdges = .crisp
        s.emfPlusSource = .gdi
        s.useEmbeddedEMF = false
        s.fontSubstitutions = [
            FontSubstitutionEntry(requested: "Calibri", replacement: "Helvetica"),
            FontSubstitutionEntry(requested: "   ", replacement: "Helvetica"),   // blank → dropped
            FontSubstitutionEntry(requested: "Cambria", replacement: "  "),       // blank → dropped
        ]
        s.thumbnailBackground = .transparent
        s.previewSharpness = .high

        let reader = SharedRenderSettings.load(from: shared)
        // The reader's options equal the app's computed options exactly.
        #expect(reader.renderOptions == s.renderOptions)
        #expect(reader.renderOptions.antialiasing == .crisp)
        #expect(reader.renderOptions.emfPlusArbitration == .gdi)
        #expect(reader.renderOptions.useEmbeddedEMF == false)
        #expect(reader.renderOptions.fontSubstitutions
                == [FontSubstitution(requestedFamily: "Calibri", replacementFamily: "Helvetica")])
        #expect(reader.thumbnailBackground == .transparent)
        #expect(reader.previewSharpness == .high)
    }

    @Test
    func readerToleratesCorruptAndOutOfRangeValues() throws {
        let name = "EmfyReaderHostile-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }

        // Corrupt font JSON, and unknown raw strings for the enum-backed keys.
        d.set(Data("definitely not json".utf8), forKey: SharedRenderSettings.Keys.fontSubstitutions)
        d.set("sideways", forKey: SharedRenderSettings.Keys.renderEdges)
        d.set("neither", forKey: SharedRenderSettings.Keys.emfPlusSource)
        d.set("mauve", forKey: SharedRenderSettings.Keys.thumbnailBackground)
        d.set("ultra", forKey: SharedRenderSettings.Keys.previewSharpness)

        let r = SharedRenderSettings.load(from: d)
        #expect(r.renderOptions.fontSubstitutions.isEmpty)
        #expect(r.renderOptions.antialiasing == .smooth)        // unknown → default
        #expect(r.renderOptions.emfPlusArbitration == .emfPlus)  // unknown → default
        #expect(r.thumbnailBackground == .white)                 // unknown → default
        #expect(r.previewSharpness == .standard)                 // unknown → default
    }

    // MARK: - One-time App Group migration

    @Test @MainActor
    func migrationCopiesMissingSharedKeysOnceWithoutOverwriting() throws {
        let (standard, standardName, group, groupName) = try freshSuites()
        defer {
            standard.removePersistentDomain(forName: standardName)
            group.removePersistentDomain(forName: groupName)
        }

        // A user who set Rendering options before the App Group existed has them
        // in `.standard`. The group already carries a different thumbnail choice.
        standard.set("crisp", forKey: SharedRenderSettings.Keys.renderEdges)
        standard.set("white", forKey: SharedRenderSettings.Keys.thumbnailBackground)
        group.set("transparent", forKey: SharedRenderSettings.Keys.thumbnailBackground)

        EmfySettings.migrateSharedKeysIfNeeded(from: standard, to: group)

        // The missing key migrated; the one already in the group was NOT overwritten.
        #expect(group.string(forKey: SharedRenderSettings.Keys.renderEdges) == "crisp")
        #expect(group.string(forKey: SharedRenderSettings.Keys.thumbnailBackground) == "transparent")

        // A second run is a no-op even after `.standard` changes again.
        standard.set("smooth", forKey: SharedRenderSettings.Keys.renderEdges)
        EmfySettings.migrateSharedKeysIfNeeded(from: standard, to: group)
        #expect(group.string(forKey: SharedRenderSettings.Keys.renderEdges) == "crisp")
    }
}
