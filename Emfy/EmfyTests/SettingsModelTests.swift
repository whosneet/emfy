import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import ImageIO
import Testing

// Shared sources (EmfySettings, RecentEntry, RecentSort, ExportScale,
// DiagnosticReport, RecentsCapPolicy, RecentsStore) are compiled directly into
// this logic-test bundle, so they're in-module — no `import Emfy`.

/// S1a-1 unit tests: the settings model, the pin field, and the pure library /
/// export / diagnostics helpers. Multiplatform: macOS and the iOS simulator.
@Suite(.serialized)
struct SettingsModelTests {

    // MARK: - Helpers

    @MainActor
    private func freshDefaults() throws -> (UserDefaults, String) {
        let name = "EmfySettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    /// Two throwaway suites, so a test can prove the Rendering keys (S1b) land in the
    /// separate `sharedDefaults` and never the main store.
    @MainActor
    private func freshSuites() throws -> (main: UserDefaults, mainName: String, shared: UserDefaults, sharedName: String) {
        let mainName = "EmfyMain-\(UUID().uuidString)"
        let sharedName = "EmfyShared-\(UUID().uuidString)"
        let main = try #require(UserDefaults(suiteName: mainName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        return (main, mainName, shared, sharedName)
    }

    /// The Rendering table's persistence key (private in the model; kept stable).
    private static let fontSubstitutionsKey = "settings.rendering.fontSubstitutions"
    private static let renderEdgesKey = "settings.rendering.edges"

    private func entry(
        name: String,
        bytes: Int64,
        opened: Date,
        received: Bool = false,
        pinned: Bool? = nil
    ) -> RecentEntry {
        RecentEntry(
            id: UUID(),
            displayName: name,
            formatLabel: "EMF",
            fullFormatName: "Enhanced Metafile",
            byteCount: bytes,
            openedAt: opened,
            bookmark: Data(),
            thumbnailFileName: nil,
            fileIdentity: nil,
            importedFileName: received ? "copy-\(UUID().uuidString).emf" : nil,
            reloadToken: nil,
            isPinned: pinned
        )
    }

    // MARK: - Store helpers (injected temp directory)

    @MainActor
    private func makeDirStore() -> (URL, RecentsStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyS1a5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
            privateImportedDirectory: dir.appendingPathComponent("PrivateImports", isDirectory: true)))
        return (dir, store)
    }

    /// Adds a file from the temp directory, so it imports a copy and reads as received.
    @MainActor
    @discardableResult
    private func addReceived(_ store: RecentsStore, in dir: URL, name: String) async -> UUID? {
        let url = dir.appendingPathComponent(name)
        try? EmfyTests.minimalEMF().write(to: url)
        return await store.handleOpenedURL(url)
    }

    /// The display names currently on disk in recents.json.
    private func persistedNames(_ store: RecentsStore) -> [String] {
        guard let data = try? Data(contentsOf: store.locations.storeURL),
              let arr = try? JSONDecoder().decode([RecentEntry].self, from: data) else { return [] }
        return arr.map(\.displayName)
    }

    /// `<repo>/corpus/gate-p4-text.emf`, from this file's compile-time path.
    static let corpusTextURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EmfyTests
        .deletingLastPathComponent()   // Emfy
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("corpus/gate-p4-text.emf")

    // MARK: - Settings model

    @Test @MainActor
    func defaultsReproduceTodaysBehaviour() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = EmfySettings(defaults: defaults)

        #expect(s.defaultZoomOnOpen == .fit)
        #expect(s.pageBackground == .whitePage)
        #expect(s.showPartialSupportBanner == true)
        #expect(s.recognizeTextInPictures == true)
        #expect(s.darkPageMode == .off)
        #expect(s.pageShadow == true)
        #expect(s.openFilesIn == .frontWindow)
        #expect(s.macScrollAction == .pan)
        #expect(s.recentsToKeep == .fifty)
        #expect(s.recentsToKeep.count == RecentsStore.maxEntries)   // == today's cap
        #expect(s.reopenLastFileAtLaunch == true)
        #expect(s.showWhatsNewAfterUpdates == true)
        #expect(s.sortRecentsBy == .date)
        #expect(s.recentsLayout == .grid)
        #expect(s.thumbnailSize == .medium)
        #expect(s.privateMode == false)
        #expect(s.defaultPNGScale == .x2)
        #expect(s.defaultPNGScale.multiplier == 2)
        #expect(s.pngBackground == .white)
        #expect(s.defaultExportFormat == .png)
    }

    @Test @MainActor
    func everySettingPersistsAcrossInstances() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let s = EmfySettings(defaults: defaults)
        s.defaultZoomOnOpen = .actualSize
        s.pageBackground = .checkerboard
        s.showPartialSupportBanner = false
        s.recognizeTextInPictures = false
        s.darkPageMode = .invert
        s.pageShadow = false
        s.openFilesIn = .newWindow
        s.macScrollAction = .zoom
        s.recentsToKeep = .hundred
        s.reopenLastFileAtLaunch = false
        s.showWhatsNewAfterUpdates = false
        s.sortRecentsBy = .size
        s.recentsLayout = .list
        s.thumbnailSize = .large
        s.privateMode = true
        s.defaultPNGScale = .x3
        s.pngBackground = .transparent
        s.defaultExportFormat = .pdf

        // A fresh instance over the same suite must observe every written value.
        let reloaded = EmfySettings(defaults: defaults)
        #expect(reloaded.defaultZoomOnOpen == .actualSize)
        #expect(reloaded.pageBackground == .checkerboard)
        #expect(reloaded.showPartialSupportBanner == false)
        #expect(reloaded.recognizeTextInPictures == false)
        #expect(reloaded.darkPageMode == .invert)
        #expect(reloaded.pageShadow == false)
        #expect(reloaded.openFilesIn == .newWindow)
        #expect(reloaded.macScrollAction == .zoom)
        #expect(reloaded.recentsToKeep == .hundred)
        #expect(reloaded.reopenLastFileAtLaunch == false)
        #expect(reloaded.showWhatsNewAfterUpdates == false)
        #expect(reloaded.sortRecentsBy == .size)
        #expect(reloaded.recentsLayout == .list)
        #expect(reloaded.thumbnailSize == .large)
        #expect(reloaded.privateMode == true)
        #expect(reloaded.defaultPNGScale == .x3)
        #expect(reloaded.pngBackground == .transparent)
        #expect(reloaded.defaultExportFormat == .pdf)
    }

    // MARK: - Rendering settings (S1b)

    @Test @MainActor
    func renderingDefaultsEqualRenderOptionsDefault() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = EmfySettings(defaults: defaults, sharedDefaults: defaults)

        #expect(s.renderEdges == .smooth)
        #expect(s.emfPlusSource == .emfPlus)
        #expect(s.useEmbeddedEMF == true)
        #expect(s.fontSubstitutions.isEmpty)
        // The computed options reproduce EMFKit's default exactly.
        #expect(s.renderOptions == RenderOptions.default)
    }

    @Test @MainActor
    func renderingSettingsPersistThroughSharedDefaultsOnly() throws {
        let (defaults, mainName, shared, sharedName) = try freshSuites()
        defer {
            defaults.removePersistentDomain(forName: mainName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let s = EmfySettings(defaults: defaults, sharedDefaults: shared)
        s.renderEdges = .crisp
        s.emfPlusSource = .gdi
        s.useEmbeddedEMF = false
        s.fontSubstitutions = [FontSubstitutionEntry(requested: "Calibri", replacement: "Helvetica")]

        // The four Rendering keys land in sharedDefaults, never the main store.
        #expect(defaults.object(forKey: Self.renderEdgesKey) == nil)
        #expect(defaults.object(forKey: Self.fontSubstitutionsKey) == nil)
        #expect(shared.string(forKey: Self.renderEdgesKey) == "crisp")
        #expect(shared.data(forKey: Self.fontSubstitutionsKey) != nil)

        // A fresh instance over the same suites observes every written value.
        let reloaded = EmfySettings(defaults: defaults, sharedDefaults: shared)
        #expect(reloaded.renderEdges == .crisp)
        #expect(reloaded.emfPlusSource == .gdi)
        #expect(reloaded.useEmbeddedEMF == false)
        #expect(reloaded.fontSubstitutions.map(\.requested) == ["Calibri"])
        #expect(reloaded.fontSubstitutions.map(\.replacement) == ["Helvetica"])
    }

    @Test @MainActor
    func corruptFontSubstitutionJSONFallsBackToEmpty() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("definitely not json".utf8), forKey: Self.fontSubstitutionsKey)

        let s = EmfySettings(defaults: defaults, sharedDefaults: defaults)
        #expect(s.fontSubstitutions.isEmpty)
        #expect(s.renderOptions.fontSubstitutions.isEmpty)
    }

    @Test @MainActor
    func fontSubstitutionsAreBoundedToRowAndNameLimits() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = EmfySettings(defaults: defaults, sharedDefaults: defaults)

        // More rows than the cap clamp to the row limit on write.
        s.fontSubstitutions = (0..<70).map { FontSubstitutionEntry(requested: "req\($0)", replacement: "rep\($0)") }
        #expect(s.fontSubstitutions.count == EmfySettings.fontSubstitutionRowLimit)

        // An over-long name truncates to the character limit on write.
        let long = String(repeating: "A", count: 200)
        s.fontSubstitutions = [FontSubstitutionEntry(requested: long, replacement: long)]
        #expect(s.fontSubstitutions[0].requested.count == EmfySettings.fontSubstitutionNameLimit)
        #expect(s.fontSubstitutions[0].replacement.count == EmfySettings.fontSubstitutionNameLimit)

        // A hostile raw blob of 100 rows persisted directly still decodes bounded.
        let rawMany = (0..<100).map { FontSubstitutionEntry(requested: "r\($0)", replacement: "x\($0)") }
        defaults.set(try JSONEncoder().encode(rawMany), forKey: Self.fontSubstitutionsKey)
        let reloaded = EmfySettings(defaults: defaults, sharedDefaults: defaults)
        #expect(reloaded.fontSubstitutions.count == EmfySettings.fontSubstitutionRowLimit)
    }

    @Test @MainActor
    func renderOptionsMapSettingsAndDropBlankRows() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = EmfySettings(defaults: defaults, sharedDefaults: defaults)
        s.renderEdges = .crisp
        s.emfPlusSource = .gdi
        s.useEmbeddedEMF = false
        s.fontSubstitutions = [
            FontSubstitutionEntry(requested: "Calibri", replacement: "Helvetica"),
            FontSubstitutionEntry(requested: "   ", replacement: "Helvetica"),   // blank requested → dropped
            FontSubstitutionEntry(requested: "Cambria", replacement: "  "),       // blank replacement → dropped
        ]

        let options = s.renderOptions
        #expect(options.antialiasing == .crisp)
        #expect(options.emfPlusArbitration == .gdi)
        #expect(options.useEmbeddedEMF == false)
        #expect(options.fontSubstitutions == [FontSubstitution(requestedFamily: "Calibri", replacementFamily: "Helvetica")])
    }

    // MARK: - "Drawn from" mapping (S1b)

    @Test
    func drawnFromReflectsEmbeddedChoiceAndEMFPlusArbitration() {
        // A WMF that played its reassembled embedded EMF.
        #expect(DrawnFrom.label(kind: .emf, embeddedEMF: .played, hasGDICopy: false, arbitration: .emfPlus) == "Built-in EMF copy")
        // The built-in EMF turned off (option 4): the records play, labelled so.
        #expect(DrawnFrom.label(kind: .wmfRecords, embeddedEMF: .declined, hasGDICopy: false, arbitration: .emfPlus)
                == "WMF records (built-in EMF copy turned off)")
        // Plain WMF record playback (no embedded EMF at all).
        #expect(DrawnFrom.label(kind: .wmfRecords, embeddedEMF: .absent, hasGDICopy: false, arbitration: .emfPlus) == "WMF records")
        // A plain EMF.
        #expect(DrawnFrom.label(kind: .emf, embeddedEMF: .notApplicable, hasGDICopy: false, arbitration: .emfPlus) == "EMF records")
        // A dual EMF+ file shown normally still reads as its EMF records.
        #expect(DrawnFrom.label(kind: .emf, embeddedEMF: .notApplicable, hasGDICopy: true, arbitration: .emfPlus) == "EMF records")
        // A dual EMF+ file the user chose to show as GDI draws from the GDI copy.
        #expect(DrawnFrom.label(kind: .emf, embeddedEMF: .notApplicable, hasGDICopy: true, arbitration: .gdi) == "GDI copy")
        // GDI arbitration on a non-dual EMF has no GDI copy, so it stays EMF records.
        #expect(DrawnFrom.label(kind: .emf, embeddedEMF: .notApplicable, hasGDICopy: false, arbitration: .gdi) == "EMF records")
    }

    // MARK: - RecentEntry.isPinned decoding

    @Test
    func recentEntryDecodesPreS1aJSONWithoutPinField() throws {
        // An entry written before S1a has no "isPinned" key; it must decode to nil.
        // Matches the default JSONEncoder format recents.json uses (Date as a
        // reference-date Double, Data as base64).
        let json = try #require("""
        {
          "id": "\(UUID().uuidString)",
          "displayName": "House.emf",
          "formatLabel": "EMF",
          "fullFormatName": "Enhanced Metafile",
          "byteCount": 2048,
          "openedAt": 760000000,
          "bookmark": "",
          "reloadToken": "\(UUID().uuidString)"
        }
        """.data(using: .utf8))

        let decoded = try JSONDecoder().decode(RecentEntry.self, from: json)
        #expect(decoded.isPinned == nil)
        #expect(decoded.displayName == "House.emf")

        // And a pinned entry round-trips.
        var pinned = decoded
        pinned.isPinned = true
        let reencoded = try JSONEncoder().encode(pinned)
        let redecoded = try JSONDecoder().decode(RecentEntry.self, from: reencoded)
        #expect(redecoded.isPinned == true)
    }

    // MARK: - Cap eviction (pinned-exempt, owned never evicted — ST3)

    @Test
    func capEvictsOldestUnpinnedNonReceivedFirstAndExemptsPinned() {
        let now = Date()
        func at(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

        let pinnedOld = entry(name: "pinned-old.emf", bytes: 1, opened: at(0), pinned: true)
        let normalOld = entry(name: "normal-old.emf", bytes: 1, opened: at(10))
        let receivedMid = entry(name: "recv.emf", bytes: 1, opened: at(20), received: true)
        let normalNew = entry(name: "normal-new.emf", bytes: 1, opened: at(30))
        let entries = [pinnedOld, normalOld, receivedMid, normalNew]

        // Cap 3 → evict the oldest unpinned non-received only.
        #expect(RecentsStore.entriesToEvict(from: entries, max: 3).map(\.id) == [normalOld.id])

        // Cap 2 → both normals go before the received copy; pinned exempt.
        #expect(Set(RecentsStore.entriesToEvict(from: entries, max: 2).map(\.id))
                == Set([normalOld.id, normalNew.id]))

        // Cap 1 → both normals go; the received copy and the pinned entry are exempt
        // (ST3: owned drawings are never evicted), so the list sits above the cap.
        let evict3 = RecentsStore.entriesToEvict(from: entries, max: 1)
        #expect(Set(evict3.map(\.id)) == Set([normalOld.id, normalNew.id]))
        #expect(!evict3.contains { $0.id == receivedMid.id })
        #expect(!evict3.contains { $0.id == pinnedOld.id })

        // All pinned, over the cap → nothing evicted.
        let allPinned = [
            entry(name: "a", bytes: 1, opened: at(0), pinned: true),
            entry(name: "b", bytes: 1, opened: at(1), pinned: true),
            entry(name: "c", bytes: 1, opened: at(2), pinned: true),
        ]
        #expect(RecentsStore.entriesToEvict(from: allPinned, max: 1).isEmpty)
    }

    // MARK: - Cap-shrink decision

    @Test
    func capShrinkReportsEvictionAndReceivedFlag() {
        let now = Date()
        func at(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

        let normalOld = entry(name: "n1.emf", bytes: 1, opened: at(0))
        let normalMid = entry(name: "n2.emf", bytes: 1, opened: at(10))
        let received = entry(name: "r.emf", bytes: 1, opened: at(20), received: true)
        let normalNew = entry(name: "n3.emf", bytes: 1, opened: at(30))
        let entries = [normalOld, normalMid, received, normalNew]

        let to3 = RecentsCapPolicy.shrink(entries, to: 3)
        #expect(to3.evicted.map(\.id) == [normalOld.id])
        #expect(to3.dropsReceivedFile == false)

        let to1 = RecentsCapPolicy.shrink(entries, to: 1)
        #expect(Set(to1.evicted.map(\.id)) == Set([normalOld.id, normalMid.id, normalNew.id]))
        #expect(to1.dropsReceivedFile == false)

        // ST3: even a cap of 0 never evicts the received (owned) copy — only the three
        // plain references go, and the received copy keeps the list above the cap.
        let to0 = RecentsCapPolicy.shrink(entries, to: 0)
        #expect(to0.evicted.count == 3)
        #expect(to0.dropsReceivedFile == false)
        #expect(!to0.evicted.contains { $0.id == received.id })

        #expect(RecentsCapPolicy.shrink(entries, to: 10).evicted.isEmpty)
    }

    // MARK: - Sorting

    @Test
    func sortByDateMatchesStoreOrderingPlusNameAndSize() {
        let now = Date()
        let a = entry(name: "b.emf", bytes: 10, opened: now.addingTimeInterval(-100))
        let b = entry(name: "a.emf", bytes: 30, opened: now)
        let c = entry(name: "c.emf", bytes: 20, opened: now.addingTimeInterval(-50))
        let input = [a, b, c]

        let byDate = RecentSort.sorted(input, by: .date)
        #expect(byDate.map(\.id) == input.sorted { $0.openedAt > $1.openedAt }.map(\.id))
        #expect(byDate.map(\.id) == [b.id, c.id, a.id])            // newest first

        #expect(RecentSort.sorted(input, by: .name).map(\.displayName) == ["a.emf", "b.emf", "c.emf"])
        #expect(RecentSort.sorted(input, by: .size).map(\.byteCount) == [30, 20, 10])   // largest first
    }

    // MARK: - Section building (sort + pin + private)

    @Test
    func sectionsSplitTodayEarlierByDateAndCollapseForNameSize() {
        let now = Date()
        let today1 = entry(name: "b.emf", bytes: 10, opened: now)
        let today2 = entry(name: "a.emf", bytes: 30, opened: now.addingTimeInterval(-60))
        let earlier = entry(name: "c.emf", bytes: 20, opened: now.addingTimeInterval(-90_000))
        let input = [today1, today2, earlier]

        // Date keeps the Today / Earlier split, newest first within each.
        let byDate = RecentSections.build(input, sort: .date, now: now)
        #expect(byDate.map(\.kind) == [.today, .earlier])
        #expect(byDate[0].entries.map(\.id) == [today1.id, today2.id])
        #expect(byDate[1].entries.map(\.id) == [earlier.id])

        // Name collapses to one untitled section, alphabetical.
        let byName = RecentSections.build(input, sort: .name, now: now)
        #expect(byName.map(\.kind) == [.all])
        #expect(byName[0].title == nil)
        #expect(byName[0].entries.map(\.displayName) == ["a.emf", "b.emf", "c.emf"])

        // Size collapses to one section, largest first.
        let bySize = RecentSections.build(input, sort: .size, now: now)
        #expect(bySize.map(\.kind) == [.all])
        #expect(bySize[0].entries.map(\.byteCount) == [30, 20, 10])
    }

    @Test
    func pinnedSectionLeadsEverySortAndIsDrawnOut() {
        let now = Date()
        let pinned = entry(name: "pin.emf", bytes: 5, opened: now.addingTimeInterval(-99_999), pinned: true)
        let today = entry(name: "today.emf", bytes: 10, opened: now)
        let input = [pinned, today]
        for sort in EmfySettings.SortOrder.allCases {
            let sections = RecentSections.build(input, sort: sort, now: now)
            #expect(sections.first?.kind == .pinned)
            #expect(sections.first?.entries.map(\.id) == [pinned.id])
            // A pinned file is drawn out of the later sections, never shown twice.
            let later = sections.dropFirst().flatMap { $0.entries.map(\.id) }
            #expect(!later.contains(pinned.id))
            #expect(later.contains(today.id))
        }
    }

    @Test
    func privateSectionLeadsAndSearchIsJustPreFiltering() {
        let now = Date()
        let priv = entry(name: "secret.emf", bytes: 10, opened: now)
        let pinned = entry(name: "pin.emf", bytes: 10, opened: now, pinned: true)
        let normal = entry(name: "normal.emf", bytes: 10, opened: now)
        let input = [priv, pinned, normal]

        let sections = RecentSections.build(input, sort: .date, privateIDs: [priv.id], now: now)
        #expect(sections.map(\.kind) == [.privateSession, .pinned, .today])
        #expect(sections[0].entries.map(\.id) == [priv.id])

        // Search filters before sectioning, so every sort still searches.
        let filtered = input.filter { $0.displayName.localizedStandardContains("normal") }
        let searched = RecentSections.build(filtered, sort: .name, privateIDs: [priv.id], now: now)
        #expect(searched.map(\.kind) == [.all])
        #expect(searched.flatMap { $0.entries.map(\.id) } == [normal.id])
    }

    // MARK: - Launch selection (reopen last file)

    @Test
    func launchSelectionHonoursReopenSettingAndExplicitRequests() {
        let requested = UUID()
        let stored = UUID()
        // Reopen on: restore the stored selection. Off: start empty.
        #expect(LaunchSelection.restored(reopenLastFile: true, requested: nil, stored: stored) == stored)
        #expect(LaunchSelection.restored(reopenLastFile: false, requested: nil, stored: stored) == nil)
        // An explicit request (Open in New Window) always wins, whatever the setting.
        #expect(LaunchSelection.restored(reopenLastFile: false, requested: requested, stored: stored) == requested)
        #expect(LaunchSelection.restored(reopenLastFile: true, requested: requested, stored: stored) == requested)
        // Nothing stored: nil even with reopen on.
        #expect(LaunchSelection.restored(reopenLastFile: true, requested: nil, stored: nil) == nil)
    }

    // MARK: - What's New gating

    @Test
    func whatsNewRespectsTheShowAfterUpdatesSetting() {
        // Enabled: the version decision stands.
        #expect(WhatsNew.shouldShow(enabled: true, lastSeenVersion: nil, currentVersion: "3.0"))
        #expect(!WhatsNew.shouldShow(enabled: true, lastSeenVersion: "3.0", currentVersion: "3.0"))
        #expect(WhatsNew.shouldShow(enabled: true, lastSeenVersion: "2.9", currentVersion: "3.0"))
        // Disabled: never shows, whatever the versions.
        #expect(!WhatsNew.shouldShow(enabled: false, lastSeenVersion: nil, currentVersion: "3.0"))
        #expect(!WhatsNew.shouldShow(enabled: false, lastSeenVersion: "2.9", currentVersion: "3.0"))
    }

    // MARK: - Cap shrink: affected received files

    @Test
    func capShrinkReportsAffectedReceivedFiles() {
        let now = Date()
        func at(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }
        let n1 = entry(name: "n1.emf", bytes: 1, opened: at(0))
        let r1 = entry(name: "r1.emf", bytes: 1, opened: at(10), received: true)
        let r2 = entry(name: "r2.emf", bytes: 1, opened: at(20), received: true)
        let r3 = entry(name: "r3.emf", bytes: 1, opened: at(30), received: true)
        let entries = [n1, r1, r2, r3]

        // ST3: received (owned) copies are never evicted, so even an aggressive shrink
        // drops only the lone non-received reference and affects no received file.
        let to1 = RecentsCapPolicy.shrink(entries, to: 1)
        #expect(to1.dropsReceivedFile == false)
        #expect(to1.evictedReceived.isEmpty)
        #expect(to1.evicted.map(\.id) == [n1.id])

        // Cap 3 → only the non-received drops; no received file is affected.
        let to3 = RecentsCapPolicy.shrink(entries, to: 3)
        #expect(to3.dropsReceivedFile == false)
        #expect(to3.evictedReceived.isEmpty)
    }

    // MARK: - Private mode: persistence gating

    @Test @MainActor
    func privateModeAddsSessionEntryWithoutWritingHistoryOrThumbnails() async throws {
        // Not "EmfyPrivate-…": that prefix is what the launch sweep reclaims (S-M3),
        // and this fixture dir sits directly under the temporary directory.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyPrivTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
            privateImportedDirectory: dir.appendingPathComponent("PrivateImports", isDirectory: true)
        ))

        store.setPrivate(true)
        let url = dir.appendingPathComponent("secret.emf")
        try EmfyTests.minimalEMF().write(to: url)
        let id = try #require(await store.handleOpenedURL(url))

        // The session entry is visible and marked private.
        #expect(store.entries.contains { $0.id == id })
        #expect(store.isSessionPrivate(id))

        // Private mode writes no recents.json and no thumbnail PNG to disk.
        #expect(!FileManager.default.fileExists(atPath: store.locations.storeURL.path))
        let thumbs = (try? FileManager.default.contentsOfDirectory(atPath: store.locations.thumbnailsDirectory.path)) ?? []
        #expect(thumbs.isEmpty)

        // Turning Private mode off drops the session entry.
        store.setPrivate(false)
        #expect(store.entries.isEmpty)
    }

    // MARK: - Private mode: persist non-private changes (review #1)

    @Test @MainActor
    func privateModeStillPersistsRemovalOfAHistoryEntry() async throws {
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try #require(await addReceived(store, in: dir, name: "keep.emf"))
        let goneID = try #require(await addReceived(store, in: dir, name: "gone.emf"))
        await store.waitForPersistenceForTesting()
        let copy = store.locations.importedDirectory
            .appendingPathComponent(try #require(store.entry(id: goneID)?.importedFileName))
        #expect(FileManager.default.fileExists(atPath: copy.path))

        // Private on, open a private file, then remove a PERSISTED entry.
        store.setPrivate(true)
        await addReceived(store, in: dir, name: "secret.emf")
        store.remove(goneID)
        store.commitPendingRemoval()                 // delete the removed entry's side files now
        await store.waitForPersistenceForTesting()

        // The removal reached disk (no dangling entry), the copy is gone, and the
        // private entry was never written.
        let names = persistedNames(store)
        #expect(!names.contains("gone.emf"))
        #expect(names.contains("keep.emf"))
        #expect(!names.contains("secret.emf"))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test @MainActor
    func privateModeStillPersistsPinningAHistoryEntry() async throws {
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(await addReceived(store, in: dir, name: "doc.emf"))
        await store.waitForPersistenceForTesting()

        store.setPrivate(true)
        await addReceived(store, in: dir, name: "secret.emf")
        store.setPinned(id, true)
        await store.waitForPersistenceForTesting()

        // A fresh store over the same locations sees the pin; the private entry is gone.
        let reloaded = RecentsStore(locations: store.locations)
        await reloaded.loadIfNeeded()
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entry(id: id)?.isPinned == true)
        #expect(reloaded.entries.first?.displayName == "doc.emf")
    }

    @Test @MainActor
    func privateModeEntriesAreExemptFromTheCap() async throws {
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        await addReceived(store, in: dir, name: "a.emf")
        await addReceived(store, in: dir, name: "b.emf")
        await store.waitForPersistenceForTesting()

        store.setPrivate(true)
        for i in 0..<3 { await addReceived(store, in: dir, name: "p\(i).emf") }
        #expect(store.entries.count == 5)
        #expect(store.privateIDs.count == 3)

        // Lower the cap to 1: no private entry is touched (they never count toward the
        // cap), and the two persisted entries are owned copies, which ST3 never evicts —
        // so both survive and the list sits above the cap rather than lose a drawing.
        store.applyCap(1)
        await store.waitForPersistenceForTesting()
        #expect(store.privateIDs.count == 3)
        #expect(persistedNames(store).count == 2)
    }

    // MARK: - Cold-launch ordering (review #2)

    @Test @MainActor
    func aStoreMadePrivateBeforeItsFirstOpenPersistsNothing() async throws {
        // Simulates the EmfyApp.init sync setting Private on before any open arrives.
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        store.setPrivate(true)
        let id = try #require(await addReceived(store, in: dir, name: "secret.emf"))
        #expect(store.isSessionPrivate(id))
        await store.waitForPersistenceForTesting()
        #expect(!FileManager.default.fileExists(atPath: store.locations.storeURL.path))
    }

    // MARK: - Cap-reduction controller (review #3)

    @MainActor
    private func seededCapScenario(count: Int) async throws -> (URL, RecentsStore, EmfySettings, String, CapReductionController) {
        let (dir, store) = makeDirStore()
        for i in 0..<count { await addReceived(store, in: dir, name: "r\(i).emf") }
        await store.waitForPersistenceForTesting()
        let (defaults, name) = try freshDefaults()
        let settings = EmfySettings(defaults: defaults)
        settings.recentsToKeep = .fifty
        return (dir, store, settings, name, CapReductionController())
    }

    // ST3: a library of owned copies is never shrunk by lowering the cap. Lowering the
    // cap raises no "drop a received copy" confirmation (that path is obsolete), opens
    // no exporter, and keeps every owned drawing — the list simply sits above the cap.
    @Test @MainActor
    func capControllerNeverDropsOwnedDrawingsWhenLoweringTheCap() async throws {
        let (dir, store, settings, suite, cap) = try await seededCapScenario(count: 12)
        defer { try? FileManager.default.removeItem(at: dir); UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Lowering 50 → 10 over 12 owned copies: no confirmation, no exporter, applied
        // at once — and every owned drawing survives (ST3).
        cap.handleChange(from: .fifty, to: .ten, store: store)
        await store.waitForPersistenceForTesting()
        #expect(cap.pending == nil)
        #expect(cap.isExporting == false)
        #expect(store.entries.count == 12)        // owned copies never evicted
    }

    // MARK: - Export scale/cap selection

    @Test
    func exportScaleFitsOneCapWithoutUpscaling() {
        // One cap, both platforms, sourced from the renderer (Mac/iOS parity).
        #expect(ExportScale.areaCap == EMFRenderer.canvasAreaCap)
        let cap = ExportScale.areaCap   // 32 MP

        // Small picture: 3× fits unchanged.
        let small = ExportScale.select(baseWidth: 400, baseHeight: 300, requested: 3, areaCap: cap)
        #expect(small.multiplier == 3)
        #expect(small.width == 1200 && small.height == 900)
        #expect(small.wasReduced == false)

        // 2000×1500: 3× = 27 MP (< 32) → stays 3×.
        let fits = ExportScale.select(baseWidth: 2000, baseHeight: 1500, requested: 3, areaCap: cap)
        #expect(fits.multiplier == 3 && fits.wasReduced == false)

        // 2500×2000: 3× = 45 MP (over), 2× = 20 MP (fits) → 2×.
        let mid = ExportScale.select(baseWidth: 2500, baseHeight: 2000, requested: 3, areaCap: cap)
        #expect(mid.multiplier == 2 && mid.wasReduced == true)

        // 4000×3000: 3× = 108 MP, 2× = 48 MP (both over), 1× = 12 MP → drops to 1×.
        let big = ExportScale.select(baseWidth: 4000, baseHeight: 3000, requested: 3, areaCap: cap)
        #expect(big.multiplier == 1 && big.wasReduced == true)

        // 1× never upscales even with headroom.
        let one = ExportScale.select(baseWidth: 100, baseHeight: 100, requested: 1, areaCap: cap)
        #expect(one.multiplier == 1 && one.wasReduced == false)

        // The PNGScale convenience agrees.
        #expect(ExportScale.select(baseWidth: 400, baseHeight: 300, requested: EmfySettings.PNGScale.x2, areaCap: cap).multiplier == 2)
    }

    // MARK: - Initial zoom (default zoom on open)

    @Test
    func initialZoomChoosesFitOrActualAndClamps() {
        // Actual size = 100%, within range.
        #expect(ViewerZoomPolicy.initialScale(for: .actualSize, fit: 0.4, minScale: 0.1, maxScale: 8) == 1)
        // Fit uses the fit scale.
        #expect(ViewerZoomPolicy.initialScale(for: .fit, fit: 0.4, minScale: 0.1, maxScale: 8) == 0.4)
        // Clamped into range: 100% above the max comes down to the max.
        #expect(ViewerZoomPolicy.initialScale(for: .actualSize, fit: 0.4, minScale: 0.1, maxScale: 0.8) == 0.8)
        // A fit below the min clamps up.
        #expect(ViewerZoomPolicy.initialScale(for: .fit, fit: 0.05, minScale: 0.1, maxScale: 8) == 0.1)
    }

    // MARK: - Tile paint (page background + dark-mode treatment)

    @Test
    func tilePaintResolvesBackgroundAndTreatment() {
        // Page background.
        #expect(ViewerTilePaint.page(for: .whitePage, isDark: true) == .white)
        #expect(ViewerTilePaint.page(for: .checkerboard, isDark: false) == .checkerboard)
        #expect(ViewerTilePaint.page(for: .matchAppearance, isDark: false) == .white)
        #expect(ViewerTilePaint.page(for: .matchAppearance, isDark: true) == .dark)
        // Treatment is viewer-only AND dark-only: Light is always none.
        #expect(ViewerTilePaint.treatment(for: .invert, isDark: false) == TilePaint.Treatment.none)
        #expect(ViewerTilePaint.treatment(for: .dim, isDark: false) == TilePaint.Treatment.none)
        #expect(ViewerTilePaint.treatment(for: .off, isDark: true) == TilePaint.Treatment.none)
        #expect(ViewerTilePaint.treatment(for: .dim, isDark: true) == .dim)
        #expect(ViewerTilePaint.treatment(for: .invert, isDark: true) == .invert)
    }

    /// Invert needs a white page beneath it, so "match appearance" + Invert in Dark
    /// resolves to a WHITE page (which inverts to dark), not the dark match page
    /// (which would invert to light) — the S1a-4c fix. Dim keeps the dark page.
    @Test
    func invertForcesAWhitePageSoMatchAppearanceStaysDark() {
        // The bug: match appearance in Dark + Invert must not leave a dark page that
        // inverts to light.
        let invert = ViewerTilePaint.make(background: .matchAppearance, darkMode: .invert, isDark: true)
        #expect(invert.treatment == .invert)
        #expect(invert.page == .white)
        // Dim over the dark match page is unchanged.
        let dim = ViewerTilePaint.make(background: .matchAppearance, darkMode: .dim, isDark: true)
        #expect(dim.treatment == .dim)
        #expect(dim.page == .dark)
        // A plain white page under Invert is already white.
        #expect(ViewerTilePaint.make(background: .whitePage, darkMode: .invert, isDark: true).page == .white)
        // In Light mode Invert is inactive, so match appearance stays its white page.
        let light = ViewerTilePaint.make(background: .matchAppearance, darkMode: .invert, isDark: false)
        #expect(light.treatment == TilePaint.Treatment.none)
        #expect(light.page == .white)
    }

    /// Renders a solid colour, applies the invert sequence, and samples: white→black,
    /// black→white, red stays red-ish (hue preserved, lightness flipped).
    @Test
    func huePreservingInvertFlipsLightnessKeepsHue() throws {
        func invertedCentre(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> (r: Double, g: Double, b: Double) {
            let w = 8, h = 8
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try #require(CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let colour = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let replay: (CGContext) -> Void = { c in c.setFillColor(colour); c.fill(rect) }
            replay(ctx)                                             // ink first
            TilePainter.applyInvert(into: ctx, rect: rect, replayInk: replay)
            let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            let i = 4 * ctx.bytesPerRow + 4 * 4                     // pixel (4,4)
            return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
        }
        let white = try invertedCentre(1, 1, 1)
        #expect(white.r < 0.2 && white.g < 0.2 && white.b < 0.2)   // white → black
        let black = try invertedCentre(0, 0, 0)
        #expect(black.r > 0.8 && black.g > 0.8 && black.b > 0.8)    // black → white
        let red = try invertedCentre(1, 0, 0)
        #expect(red.r > red.g && red.r > red.b)                    // red stays red-ish
    }

    // MARK: - Diagnostic report privacy (S1a-6)

    /// The report is built exactly as the app builds it — `prepare()` for the
    /// record-kind counts, and a `FileInfo` whose only file-derived input is the
    /// EXTENSION of a name that, along with the path and the drawing text, carries
    /// a sentinel. None of those sentinels can appear in the report.
    @Test
    func diagnosticReportLeaksNoFileNamePathOrDrawingText() throws {
        let data = try #require(
            try? Data(contentsOf: Self.corpusTextURL),
            "corpus/gate-p4-text.emf must be readable at \(Self.corpusTextURL.path)"
        )
        let file = try EMFFile.parse(data)
        let texts: [String] = file.records.compactMap { record in
            if case .extTextOutW(let payload) = file.payload(of: record), !payload.string.isEmpty {
                return payload.string
            }
            return nil
        }
        #expect(!texts.isEmpty, "the corpus file must carry text for this test to mean anything")

        let prepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(data)))
        let fileInfo = DiagnosticReport.fileInfo(
            fileExtension: ("SENTINELNAME.emf" as NSString).pathExtension,
            byteCount: Int64(data.count),
            recordKinds: prepared.recordKinds.map { DiagnosticReport.RecordKind(name: $0.name, count: $0.count) },
            couldNotShow: []
        )
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3.0", appBuild: "300", osVersion: "Test OS 1.0", deviceClass: "Mac", file: fileInfo
        ))

        // No file name, no path (the path is never even an input to the builder).
        #expect(!report.contains("SENTINELNAME"))
        #expect(!report.contains("/Users/sentinel/SENTINELPATH"))
        // No drawing text.
        for text in texts {
            #expect(!report.contains(text), "report leaked drawing text: \(text)")
        }
        // No exact byte count — only a coarse bucket.
        #expect(!report.contains(String(data.count)))
        #expect(report.contains("Size: \(DiagnosticReport.byteSizeBucket(Int64(data.count)))"))
        // The safe fields are present: format, record counts by kind.
        #expect(report.contains("EMF"))
        #expect(report.contains("Enhanced Metafile"))
        #expect(report.contains("Records by kind"))
        #expect(report.contains("EMR_HEADER"))
    }

    /// Even a note whose TECHNICAL detail carries a sentinel (e.g. a requested font
    /// face name) cannot leak: the report prints the plain-language summary only.
    /// Extended to the REAL substitution note, whose `used` name may be a
    /// user-configured replacement family — it must not reach the report either (S-L4).
    @Test
    func diagnosticReportUsesNoteSummariesNotTechnicalDetail() {
        let note = DiagnosticNote(
            summary: "A font the file asked for wasn’t available, so a substitute was used.",
            technicalDetail: "Used Helvetica instead of unavailable font SENTINELFONT (1 occurrence)."
        )
        // The real note the renderer builds, with a user-chosen replacement as `used`.
        let userSubNote = EMFRenderLog.Entry
            .fontSubstituted(requested: "Arial", used: "SENTINELREPLACEMENT", count: 2).note
        let info = DiagnosticReport.fileInfo(
            fileExtension: "emf", byteCount: 1234, recordKinds: [], couldNotShow: [note, userSubNote]
        )
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3", appBuild: "3", osVersion: "x", deviceClass: "Mac", file: info
        ))
        #expect(!report.contains("SENTINELFONT"))
        #expect(!report.contains("SENTINELREPLACEMENT"))
        #expect(report.contains("A font the file asked for"))
    }

    /// A system-only report (the Settings row, no file) carries app/system/device
    /// only — no File or Records section at all.
    @Test
    func systemOnlyDiagnosticReportHasNoFileSection() {
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3.0", appBuild: "300", osVersion: "macOS 14.0", deviceClass: "Mac", file: nil
        ))
        #expect(report.contains("App: Emfy 3.0 (300)"))
        #expect(report.contains("Device: Mac"))
        #expect(!report.contains("Records by kind"))
        #expect(!report.contains("Format:"))
    }

    @Test
    func byteSizeBucketIsCoarseAndOrdered() {
        #expect(DiagnosticReport.byteSizeBucket(500) == "under 10 KB")
        #expect(DiagnosticReport.byteSizeBucket(50_000) == "10 KB to 100 KB")
        #expect(DiagnosticReport.byteSizeBucket(500_000) == "100 KB to 1 MB")
        #expect(DiagnosticReport.byteSizeBucket(5_000_000) == "1 MB to 10 MB")
        #expect(DiagnosticReport.byteSizeBucket(500_000_000) == "over 100 MB")
    }

    /// The report lists at most 30 record kinds in full, then summarises the rest as
    /// "and N other kinds" (S-L6).
    @Test
    func diagnosticReportCapsRecordKindsAt30() {
        let kinds = (0..<45).map { DiagnosticReport.RecordKind(name: "EMR_KIND_\($0)", count: 45 - $0) }
        let info = DiagnosticReport.fileInfo(fileExtension: "emf", byteCount: 1, recordKinds: kinds, couldNotShow: [])
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3", appBuild: "3", osVersion: "x", deviceClass: "Mac", file: info
        ))
        let bulletLines = report.split(separator: "\n").filter { $0.hasPrefix("• EMR_KIND_") }
        #expect(bulletLines.count == 30)
        #expect(report.contains("• and 15 other kinds"))
    }

    @Test
    func diagnosticReportRecordKindsSingularTail() {
        let kinds = (0..<31).map { DiagnosticReport.RecordKind(name: "EMR_KIND_\($0)", count: 31 - $0) }
        let info = DiagnosticReport.fileInfo(fileExtension: "emf", byteCount: 1, recordKinds: kinds, couldNotShow: [])
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3", appBuild: "3", osVersion: "x", deviceClass: "Mac", file: info
        ))
        #expect(report.contains("• and 1 other kind"))
        #expect(!report.contains("other kinds"))
    }

    @Test
    func diagnosticReportBelow30KindsHasNoOverflowLine() {
        let kinds = (0..<5).map { DiagnosticReport.RecordKind(name: "EMR_KIND_\($0)", count: 1) }
        let info = DiagnosticReport.fileInfo(fileExtension: "emf", byteCount: 1, recordKinds: kinds, couldNotShow: [])
        let report = DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: "3", appBuild: "3", osVersion: "x", deviceClass: "Mac", file: info
        ))
        #expect(!report.contains("other kind"))
    }

    // MARK: - Private entries kept out of Open Recent and Clear counts (S-M2)

    @Test @MainActor
    func nonPrivateEntriesExcludesSessionPrivateFromOpenRecent() async throws {
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let shownID = try #require(await addReceived(store, in: dir, name: "shown.emf"))
        store.setPrivate(true)
        let secretID = try #require(await addReceived(store, in: dir, name: "secret.emf"))

        // Both entries are in `entries` (the library shows the private one, marked),
        // but only the non-private one is eligible for the Mac Open Recent menu.
        #expect(store.entries.contains { $0.id == secretID })
        let visible = store.nonPrivateEntries
        #expect(visible.contains { $0.id == shownID })
        #expect(!visible.contains { $0.id == secretID })

        let recentItems = OpenRecentList.items(from: store.nonPrivateEntries)
        #expect(recentItems.contains { $0.id == shownID })
        #expect(!recentItems.contains { $0.id == secretID })
        #expect(!recentItems.contains { $0.displayName == "secret.emf" })
    }

    // MARK: - Private imports stage under the temporary directory, not Imported/ (S-M3)

    @Test @MainActor
    func privateImportGoesToTempNotImportedAndIsClearable() async throws {
        let (dir, store) = makeDirStore(); defer { try? FileManager.default.removeItem(at: dir) }
        store.setPrivate(true)
        // `dir` is an ephemeral-looking location, so the open imports a copy.
        let id = try #require(await addReceived(store, in: dir, name: "secret.emf"))
        let copyName = try #require(store.entry(id: id)?.importedFileName)

        // The copy is in the per-launch temp directory, and Imported/ is empty.
        let privateCopy = store.locations.privateImportedDirectory.appendingPathComponent(copyName)
        let importedCopy = store.locations.importedDirectory.appendingPathComponent(copyName)
        #expect(FileManager.default.fileExists(atPath: privateCopy.path))
        #expect(!FileManager.default.fileExists(atPath: importedCopy.path))
        let importedContents = (try? FileManager.default.contentsOfDirectory(atPath: store.locations.importedDirectory.path)) ?? []
        #expect(importedContents.isEmpty)

        // The quit/background cleanup removes the whole staging directory.
        store.clearPrivateImports()
        #expect(!FileManager.default.fileExists(atPath: privateCopy.path))
        #expect(!FileManager.default.fileExists(atPath: store.locations.privateImportedDirectory.path))
    }

    // MARK: - Export menu ordering (default export format)

    @Test
    func exportMenuOrdersPrimaryFormatFirst() {
        #expect(ExportMenuOrder.formats(default: .png) == [.png, .pdf])
        #expect(ExportMenuOrder.formats(default: .pdf) == [.pdf, .png])
    }

    // MARK: - PNG export scale (wired path, including the cap)

    @Test @MainActor
    func pngExportScaleDrivesPixelSizeIncludingCap() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EmfySettings(defaults: defaults)

        func pixels(width: Int32, height: Int32, scale: EmfySettings.PNGScale) throws -> (Int, Int) {
            settings.defaultPNGScale = scale
            let prepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(EmfyTests.minimalEMF(width: width, height: height))))
            let opts = ExportScale.pngOptions(for: prepared.naturalSize, settings: settings)
            let (image, _) = try #require(MetafileRenderer.makeImage(prepared, scale: opts.scale, background: opts.background))
            return (image.width, image.height)
        }

        #expect(try pixels(width: 100, height: 100, scale: .x1) == (100, 100))
        #expect(try pixels(width: 100, height: 100, scale: .x2) == (200, 200))
        #expect(try pixels(width: 100, height: 100, scale: .x3) == (300, 300))
        // 5000×5000 at 3× = 225 MP and at 2× = 100 MP both exceed the 32 MP cap,
        // so the fallback lands on 1× → the natural 5000×5000.
        #expect(try pixels(width: 5000, height: 5000, scale: .x3) == (5000, 5000))
    }

    // MARK: - PNG export background (white vs transparent)

    @Test
    func pngExportBackgroundDrivesCornerAlpha() throws {
        let prepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(Self.filledRectEMF())))

        // Transparent: an empty corner is clear, the filled shape is opaque.
        let (clearImage, _) = try #require(MetafileRenderer.makeImage(prepared, scale: 1, background: .transparent))
        let clearPNG = try #require(EMFExport.pngData(from: clearImage))
        let clear = try #require(Self.decodePNG(clearPNG))
        #expect(Self.alpha(of: clear, x: 5, y: 5) == 0)
        #expect(Self.alpha(of: clear, x: clear.width / 2, y: clear.height / 2) == 255)

        // White: opaque everywhere, including the empty corner.
        let (whiteImage, _) = try #require(MetafileRenderer.makeImage(prepared, scale: 1, background: .white))
        let whitePNG = try #require(EMFExport.pngData(from: whiteImage))
        let white = try #require(Self.decodePNG(whitePNG))
        #expect(Self.alpha(of: white, x: 5, y: 5) == 255)
        #expect(Self.alpha(of: white, x: white.width / 2, y: white.height / 2) == 255)
    }

    // MARK: - Test fixtures for the PNG background test

    /// A 100×100 EMF that fills a centred rectangle (25,25)-(75,75) solid red with a
    /// brush, leaving the corners empty. Record layouts per [MS-EMF] §2.3.7.1
    /// (CREATEBRUSHINDIRECT), §2.3.8.5 (SELECTOBJECT), §2.3.5.34 (RECTANGLE).
    static func filledRectEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        // EMR_HEADER (88-byte base variant); bytes/records set true (88+24+12+24+20, 5).
        u32(1); u32(88)
        i32(0); i32(0); i32(99); i32(99)
        i32(0); i32(0); i32(2117); i32(2117)
        u32(0x464D4520); u32(0x0001_0000)
        u32(168); u32(5)
        u16(1); u16(0)
        u32(0); u32(0); u32(0)
        i32(1920); i32(1080); i32(508); i32(286)
        // EMR_CREATEBRUSHINDIRECT: ihBrush 0, BS_SOLID, ColorRef red (R,G,B,0), hatch 0.
        u32(39); u32(24); u32(0); u32(0); u32(0x0000_00FF); u32(0)
        // EMR_SELECTOBJECT: table index 0.
        u32(37); u32(12); u32(0)
        // EMR_RECTANGLE: Box (25,25,75,75).
        u32(43); u32(24); i32(25); i32(25); i32(75); i32(75)
        // EMR_EOF.
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    /// The alpha byte at (x, y) of `image`, read by drawing it into a known
    /// premultiplied-last sRGB buffer (so padding and premultiply never confuse the
    /// read).
    static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 0 }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer[(y * w + x) * 4 + 3]
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
