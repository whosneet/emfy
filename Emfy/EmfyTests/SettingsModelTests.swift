import CoreGraphics
import EMFParse
import EMFRender
import Foundation
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

    // MARK: - Cap eviction (pinned-exempt, received-last)

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

        // Cap 1 → both normals, then the received copy. Pinned still exempt.
        let evict3 = RecentsStore.entriesToEvict(from: entries, max: 1)
        #expect(Set(evict3.map(\.id)) == Set([normalOld.id, normalNew.id, receivedMid.id]))
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

        let to0 = RecentsCapPolicy.shrink(entries, to: 0)
        #expect(to0.evicted.count == 4)
        #expect(to0.dropsReceivedFile == true)

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

    // MARK: - Diagnostic report privacy

    @Test
    func diagnosticReportLeaksNoFileNameOrDrawingText() throws {
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

        let bounds = file.header.bounds
        let input = DiagnosticReport.input(
            fileExtension: ("Secret Plan.emf" as NSString).pathExtension,
            appVersion: "3.0",
            appBuild: "300",
            osVersion: "Test OS 1.0",
            deviceModel: "Test Device",
            byteCount: Int64(data.count),
            pixelWidth: Int(bounds.right - bounds.left + 1),
            pixelHeight: Int(bounds.bottom - bounds.top + 1),
            recordCount: file.records.count,
            couldNotShow: []
        )
        let report = DiagnosticReport.text(input)

        // No file name, no path.
        #expect(!report.contains("Secret"))
        #expect(!report.localizedCaseInsensitiveContains("secret plan"))
        // No drawing text.
        for text in texts {
            #expect(!report.contains(text), "report leaked drawing text: \(text)")
        }
        // The safe fields are present.
        #expect(report.contains("EMF"))
        #expect(report.contains("Records: \(file.records.count)"))
    }
}
