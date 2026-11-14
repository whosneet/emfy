import AppIntents
import Foundation
import Testing
import UniformTypeIdentifiers

// F4a unit tests for the App Intents surface: the pure `DrawingEntityFactory`
// (suggestions, name search, Private-mode and session-private filtering) and the
// convert / text / info intents driven through `perform()` with temp copies of
// committed corpus files — no network, no shared store, no singletons.

@Suite struct AppIntentsTests {

    // MARK: - Fixtures

    private func corpusURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("corpus/\(name)")
    }

    /// A unique temp copy of a corpus file, so the intent reads a handed-in file,
    /// never the repo original.
    private func tempCopy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyIntentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: corpusURL(name), to: dest)
        return dest
    }

    private func intentFile(_ name: String) throws -> IntentFile {
        IntentFile(fileURL: try tempCopy(name), filename: name)
    }

    private func entry(_ name: String, opened: Date = Date()) -> RecentEntry {
        let names = MetafileFormatLabel.names(for: name)
        return RecentEntry(
            id: UUID(),
            displayName: name,
            formatLabel: names.short,
            fullFormatName: names.full,
            byteCount: 1024,
            openedAt: opened,
            bookmark: Data(),
            thumbnailFileName: nil,
            fileIdentity: nil,
            importedFileName: nil,
            reloadToken: UUID()
        )
    }

    private var tmp: URL { FileManager.default.temporaryDirectory }

    // MARK: - Entity query factory

    @Test func privateModeReturnsNothing() {
        let entries = [entry("a.emf"), entry("b.wmf")]
        let result = DrawingEntityFactory.entities(
            from: entries, isPrivate: true, privateIDs: [], thumbnailsDirectory: tmp)
        #expect(result.isEmpty)
    }

    @Test func suggestedLimitsToMostRecentTen() {
        // 15 entries newest-first, as the store hands them over.
        let entries = (0..<15).map {
            entry("file\($0).emf", opened: Date(timeIntervalSince1970: TimeInterval(10_000 - $0)))
        }
        let result = DrawingEntityFactory.entities(
            from: entries, isPrivate: false, privateIDs: [], thumbnailsDirectory: tmp, limit: 10)
        #expect(result.count == 10)
        #expect(result.first?.name == "file0.emf")
    }

    @Test func searchMatchesByNameCaseInsensitively() {
        let entries = [entry("Invoice.emf"), entry("House sketch.wmf")]
        let result = DrawingEntityFactory.entities(
            from: entries, isPrivate: false, privateIDs: [], thumbnailsDirectory: tmp, search: "HOUSE")
        #expect(result.count == 1)
        #expect(result.first?.name == "House sketch.wmf")
    }

    @Test func sessionPrivateEntriesAreNeverSurfaced() {
        let a = entry("a.emf")
        let b = entry("b.emf")
        let result = DrawingEntityFactory.entities(
            from: [a, b], isPrivate: false, privateIDs: [a.id], thumbnailsDirectory: tmp)
        #expect(result.map(\.id) == [b.id])
    }

    @Test func entityCarriesFormatSizeAndThumbnailPath() {
        var e = entry("plan.emf")
        e.thumbnailFileName = "thumb.png"
        let entity = DrawingEntityFactory.entity(from: e, thumbnailsDirectory: URL(fileURLWithPath: "/cache"))
        #expect(entity.name == "plan.emf")
        #expect(entity.formatLabel == "EMF")
        #expect(entity.thumbnailPath == "/cache/thumb.png")
    }

    // MARK: - Convert

    @Test(arguments: [DrawingExportFormat.png, .pdf, .svg])
    func convertProducesFileOfRightType(_ format: DrawingExportFormat) async throws {
        let intent = ConvertDrawingIntent()
        intent.file = try intentFile("gate-p2-star.emf")
        intent.format = format
        intent.scale = 2
        let result = try await intent.perform()
        let container = try #require(result as? IntentResultContainer<IntentFile, Never, Never, Never>)
        let output = try #require(container.value)
        #expect(!output.data.isEmpty)
        #expect(output.type == format.utType)
        #expect((output.filename as NSString).pathExtension == format.pathExtension)
    }

    // MARK: - Get Text

    @Test func getTextContainsKnownString() async throws {
        let intent = GetTextFromDrawingIntent()
        intent.file = try intentFile("gate-p4-text.emf")
        intent.includePictures = false
        let result = try await intent.perform()
        let container = try #require(result as? IntentResultContainer<String, Never, Never, IntentDialog>)
        let text = try #require(container.value)
        #expect(text.contains("Hello Emfy 123"))
    }

    // MARK: - Get Info

    @Test func infoReportsFormatRecordsTextAndPageSize() throws {
        let data = try Data(contentsOf: corpusURL("gate-p4-text.emf"))
        let info = try AppIntentDrawing.info(from: data, fileName: "gate-p4-text.emf")
        #expect(info.format == "Enhanced Metafile")
        #expect(info.recordCount > 0)
        #expect(info.hasText)
        #expect(info.pageSizeMM != nil)
        #expect(info.summary.contains("Enhanced Metafile"))
        #expect(info.summary.contains("Records:"))
    }

    @Test func getInfoPerformReturnsSummary() async throws {
        let intent = GetDrawingInfoIntent()
        intent.file = try intentFile("gate-p4-text.emf")
        let result = try await intent.perform()
        let container = try #require(result as? IntentResultContainer<String, Never, Never, Never>)
        let summary = try #require(container.value)
        #expect(summary.contains("Enhanced Metafile"))
        #expect(summary.contains("Contains text: yes"))
    }

    // MARK: - Hostile input

    @Test func hostileFileThrowsTypedError() async throws {
        let garbage = Data(repeating: 0xAB, count: 512)
        let intent = ConvertDrawingIntent()
        intent.file = IntentFile(data: garbage, filename: "junk.emf", type: nil)
        intent.format = .png
        await #expect(throws: AppIntentDrawingError.self) {
            _ = try await intent.perform()
        }
    }

    @Test func noInputAsksForADrawing() async throws {
        // SI-M: with no drawing, the intent asks for one (needsValueError) instead of throwing
        // its own typed error, so Shortcuts/Siri can prompt the user.
        let intent = GetTextFromDrawingIntent()
        await #expect(throws: (any Error).self) {
            _ = try await intent.perform()
        }
    }
}
