import CoreSpotlight
import Foundation
import Testing
import UniformTypeIdentifiers

// F4b unit tests for the Apple Intelligence surface: the ungated attribute-set
// builder and the F3-item → entity reconstruction seam that `CoreSpotlightIndex`
// uses to associate a drawing with its App Entity. No live index, no Siri. The
// `IndexedEntity` conformance itself (macOS 15+) is checked through one gated test.

@Suite struct IndexedEntityTests {

    // MARK: - Attribute-set construction

    @Test func attributeSetCarriesNameTypeAndDescription() {
        let set = DrawingEntityAttributes.attributeSet(
            name: "plan.emf",
            contentTypeIdentifier: "com.microsoft.emf",
            formatLabel: "EMF",
            sizeLabel: "20 KB",
            textSummary: "Invoice 2026"
        )
        #expect(set.title == "plan.emf")
        #expect(set.displayName == "plan.emf")
        #expect(set.contentDescription == "EMF · 20 KB")
        #expect(set.textContent == "Invoice 2026")
    }

    @Test func attributeSetDropsSizeWhenBlank() {
        let set = DrawingEntityAttributes.attributeSet(
            name: "a.wmf", contentTypeIdentifier: "com.microsoft.wmf",
            formatLabel: "WMF", sizeLabel: "", textSummary: nil)
        #expect(set.contentDescription == "WMF")
    }

    @Test func attributeSetOmitsEmptyText() {
        let fromNil = DrawingEntityAttributes.attributeSet(
            name: "a.emf", contentTypeIdentifier: "com.microsoft.emf",
            formatLabel: "EMF", sizeLabel: "1 KB", textSummary: nil)
        let fromEmpty = DrawingEntityAttributes.attributeSet(
            name: "a.emf", contentTypeIdentifier: "com.microsoft.emf",
            formatLabel: "EMF", sizeLabel: "1 KB", textSummary: "")
        #expect(fromNil.textContent == nil)
        #expect(fromEmpty.textContent == nil)
    }

    @Test func attributeSetCapsSummaryToTwoThousand() {
        let long = String(repeating: "a", count: 5_000)
        let set = DrawingEntityAttributes.attributeSet(
            name: "big.emf", contentTypeIdentifier: "com.microsoft.emf",
            formatLabel: "EMF", sizeLabel: "9 MB", textSummary: long)
        #expect(set.textContent?.utf16.count == DrawingEntityAttributes.maxSummaryCharacters)
    }

    @Test(arguments: [
        ("x.emf", "com.microsoft.emf"), ("x.wmf", "com.microsoft.wmf"),
        ("x.emz", "com.microsoft.emz"), ("x.wmz", "com.microsoft.wmz"),
        ("x.txt", "public.data"),
    ])
    func contentTypeMappedFromExtension(_ name: String, _ uti: String) {
        #expect(DrawingEntityAttributes.contentTypeIdentifier(forFileNamed: name) == uti)
    }

    // MARK: - Entity reconstruction seam

    @Test func entityFromSpotlightItemCarriesIDNameFormatAndSummary() {
        let id = UUID()
        let item = DrawingSpotlightItem(
            id: id.uuidString, title: "House sketch.wmf",
            contentDescription: "Metafile drawing", textContent: "Front elevation",
            contentTypeIdentifier: "com.microsoft.wmf")
        let entity = DrawingEntityIndexing.entity(forSpotlight: item)
        #expect(entity?.id == id)
        #expect(entity?.name == "House sketch.wmf")
        #expect(entity?.formatLabel == "WMF")
        #expect(entity?.textSummary == "Front elevation")
    }

    @Test func entityFromSpotlightItemCapsSummary() {
        let item = DrawingSpotlightItem(
            id: UUID().uuidString, title: "big.emf",
            contentDescription: "", textContent: String(repeating: "z", count: 9_000),
            contentTypeIdentifier: "com.microsoft.emf")
        let entity = DrawingEntityIndexing.entity(forSpotlight: item)
        #expect(entity?.textSummary?.utf16.count == DrawingEntityAttributes.maxSummaryCharacters)
    }

    @Test func entityFromSpotlightItemHasNoSummaryForEmptyText() {
        let item = DrawingSpotlightItem(
            id: UUID().uuidString, title: "a.emf", contentDescription: "",
            textContent: "", contentTypeIdentifier: "com.microsoft.emf")
        #expect(DrawingEntityIndexing.entity(forSpotlight: item)?.textSummary == nil)
    }

    @Test func entityFromSpotlightItemRejectsNonUUIDID() {
        let item = DrawingSpotlightItem(
            id: "not-a-uuid", title: "a.emf", contentDescription: "",
            textContent: "x", contentTypeIdentifier: "com.microsoft.emf")
        #expect(DrawingEntityIndexing.entity(forSpotlight: item) == nil)
    }

    // MARK: - IndexedEntity conformance (gated)

    @available(macOS 15, iOS 18, *)
    @Test func indexedEntityAttributeSetMatchesBuilder() {
        let entity = DrawingEntity(
            id: UUID(), name: "plan.emf", formatLabel: "EMF",
            sizeLabel: "20 KB", thumbnailPath: nil, textSummary: "Hello")
        let set = entity.attributeSet
        #expect(set.title == "plan.emf")
        #expect(set.contentDescription == "EMF · 20 KB")
        #expect(set.textContent == "Hello")
    }
}
