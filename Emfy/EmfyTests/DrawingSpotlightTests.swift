import CoreGraphics
import Foundation
import Testing

// F3 unit tests for the pure Spotlight core (`DrawingSpotlightBuilder`,
// `DrawingSpotlightPolicy`, `DrawingSpotlightCoordinator`): item construction and
// the 100k text cap, the index/wipe policy, and the de-index/clear/private-mode
// triggers driven through a recording fake of the index seam.

@Suite struct DrawingSpotlightTests {

    // A recording fake standing in for the Core Spotlight implementation.
    private actor FakeIndex: DrawingSpotlightIndex {
        var indexed: [[DrawingSpotlightItem]] = []
        var removed: [[String]] = []
        var removedAllCount = 0
        func index(_ items: [DrawingSpotlightItem]) async { indexed.append(items) }
        func removeItems(ids: [String]) async { removed.append(ids) }
        func removeAll() async { removedAllCount += 1 }
    }

    private func run(_ text: String, _ y: CGFloat, _ source: DrawingTextRun.Source = .drawing) -> DrawingTextRun {
        DrawingTextRun(text: text, boundsDevice: CGRect(x: 0, y: y, width: 40, height: 10), fontFamily: nil, fontSize: nil, source: source)
    }

    // MARK: Item construction

    @Test func itemUsesEntryIdAndFileNameAndJoinsText() {
        let item = DrawingSpotlightBuilder.item(
            id: "entry-7",
            fileName: "diagram.emf",
            contentTypeIdentifier: "com.microsoft.emf",
            drawingText: [run("Top", 0), run("Bottom", 50)],
            pictureText: [run("OCR", 0, .picture)]
        )
        #expect(item.id == "entry-7")
        #expect(item.title == "diagram.emf")
        #expect(item.contentTypeIdentifier == "com.microsoft.emf")
        #expect(item.textContent.contains("Top"))
        #expect(item.textContent.contains("Bottom"))
        #expect(item.textContent.contains("OCR"))
        #expect(item.contentDescription.contains("in pictures"))
    }

    @Test func textContentIsCappedAt100k() {
        let big = String(repeating: "z", count: 120_000)
        let capped = DrawingSpotlightBuilder.cap(big, to: DrawingSpotlightBuilder.maxTextCharacters)
        #expect(capped.utf16.count == DrawingSpotlightBuilder.maxTextCharacters)
    }

    // MARK: Policy

    @Test func policyIndexesOnlyWhenEnabledAndNotPrivate() {
        #expect(DrawingSpotlightPolicy.shouldIndex(enabled: true, privateMode: false))
        #expect(!DrawingSpotlightPolicy.shouldIndex(enabled: true, privateMode: true))
        #expect(!DrawingSpotlightPolicy.shouldIndex(enabled: false, privateMode: false))
    }

    @Test func policyWipesWhenDisabledOrPrivate() {
        #expect(!DrawingSpotlightPolicy.shouldWipeAll(enabled: true, privateMode: false))
        #expect(DrawingSpotlightPolicy.shouldWipeAll(enabled: true, privateMode: true))
        #expect(DrawingSpotlightPolicy.shouldWipeAll(enabled: false, privateMode: false))
    }

    // MARK: Coordinator triggers

    @Test func reindexRespectsTheSettingsGate() async {
        let fake = FakeIndex()
        let coord = DrawingSpotlightCoordinator(index: fake)
        let item = DrawingSpotlightBuilder.item(id: "a", fileName: "a.emf", contentTypeIdentifier: "t", drawingText: [run("x", 0)], pictureText: [])

        await coord.reindex([item], enabled: false, privateMode: false)   // gated off
        await coord.reindex([item], enabled: true, privateMode: true)     // private
        var indexedCount = await fake.indexed.count
        #expect(indexedCount == 0)

        await coord.reindex([item], enabled: true, privateMode: false)    // allowed
        indexedCount = await fake.indexed.count
        #expect(indexedCount == 1)
    }

    @Test func removeAndClearAndPrivateDriveTheSeam() async {
        let fake = FakeIndex()
        let coord = DrawingSpotlightCoordinator(index: fake)

        await coord.entriesRemoved(ids: ["a", "b"])
        await coord.recentsCleared()
        await coord.indexingDisabledOrPrivate()

        let removed = await fake.removed
        let removedAll = await fake.removedAllCount
        #expect(removed == [["a", "b"]])
        #expect(removedAll == 2)   // clear + private wipe
    }
}
