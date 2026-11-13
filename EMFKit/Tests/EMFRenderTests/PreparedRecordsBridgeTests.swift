import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// The record-inspector bridge on `MetafileRenderer.Prepared` (F5b): the player
/// factory, the per-record list, the summaries and the DC state — and that a
/// translated WMF program exposes the list but not the EMF-only step-through.
@Suite("Prepared record-inspector bridge")
struct PreparedRecordsBridgeTests {

    /// A small EMF: a brush create/select then a rectangle. Record indices:
    /// 0 header, 1 brush, 2 select, 3 rectangle, 4 EOF.
    private static func rectangleFixture() -> RenderFixture {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 220, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.rectangle(10, 10, 40, 40)
        return fixture
    }

    private static func preparedEMF() throws -> MetafileRenderer.Prepared {
        try #require(MetafileRenderer.prepare(try OpenedMetafile.open(rectangleFixture().data())))
    }

    // MARK: - EMF content

    @Test("makePartialPlayer is non-nil for EMF content and matches the record count")
    func emfPlayerIsAvailable() throws {
        let prepared = try Self.preparedEMF()
        let file = try Self.rectangleFixture().parsed()
        let player = try #require(prepared.makePartialPlayer())
        #expect(player.recordCount == file.records.count)
        #expect(player.supportsPartial)
    }

    @Test("recordRefs names each EMF record with its EMR_* name and byte span")
    func emfRecordRefs() throws {
        let prepared = try Self.preparedEMF()
        let file = try Self.rectangleFixture().parsed()
        let refs = prepared.recordRefs()

        #expect(refs.count == file.records.count)
        #expect(refs.first?.index == 0)
        #expect(refs.first?.typeName == "EMR_HEADER")
        #expect(refs.first?.offset == 0)
        #expect(refs.last?.typeName == "EMR_EOF")
        #expect(refs.contains { $0.typeName == "EMR_RECTANGLE" })
        // Offsets strictly ascend and each size matches the raw record.
        for (ref, record) in zip(refs, file.records) {
            #expect(ref.offset == record.offset)
            #expect(ref.size == Int(record.size))
            #expect(ref.size >= 8)
        }
        // A pure-GDI EMF has no EMF+ carriers.
        #expect(refs.allSatisfy { !$0.isEMFPlusCarrier && $0.emfPlusRecordCount == 0 })
    }

    @Test("recordSummary matches the EMFFile summary for a drawing record")
    func emfRecordSummary() throws {
        let prepared = try Self.preparedEMF()
        let file = try Self.rectangleFixture().parsed()
        let rectIndex = try #require(file.records.firstIndex { $0.type == 43 })   // EMR_RECTANGLE
        let summary = try #require(prepared.recordSummary(at: rectIndex))
        #expect(summary == file.recordSummary(at: rectIndex))
        #expect(!summary.isEmpty)
    }

    @Test("playbackState matches the renderer's state through the same record")
    func emfPlaybackState() throws {
        let prepared = try Self.preparedEMF()
        let file = try Self.rectangleFixture().parsed()
        let last = file.records.count - 1
        let state = try #require(prepared.playbackState(throughRecordIndex: last))
        #expect(state == EMFRenderer.playbackState(of: file, throughRecordIndex: last))
    }

    // MARK: - EMF+ carriers

    @Test("EMF+ comment carriers are flagged and their records counted")
    func emfPlusCarriersCounted() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("handmade-emfplus-shapes.emf"))
        let prepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(data)))
        let file = try EMFFile.parse(data)
        let refs = prepared.recordRefs()

        let carriers = refs.filter(\.isEMFPlusCarrier)
        #expect(!carriers.isEmpty, "an EMF+ file should expose at least one EMF+ carrier")
        #expect(carriers.allSatisfy { $0.emfPlusRecordCount > 0 })
        // Every carrier row indexes an EMR_COMMENT (type 70) record.
        #expect(carriers.allSatisfy { file.records[$0.index].type == 70 })
        // The counts sum to the reassembled EMF+ stream length.
        let total = refs.reduce(0) { $0 + $1.emfPlusRecordCount }
        #expect(total == file.emfPlusStream().records.count)
    }

    // MARK: - WMF program

    @Test("a WMF program exposes the record list and summaries but not the EMF step-through")
    func wmfProgramListOnly() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("gate-wmf-gdi-p2-star.wmf"))
        let prepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(data)))
        #expect(prepared.kind == .wmfRecords)

        #expect(prepared.makePartialPlayer() == nil)
        #expect(prepared.playbackState(throughRecordIndex: 0) == nil)

        let refs = prepared.recordRefs()
        #expect(!refs.isEmpty)
        #expect(refs.contains { $0.typeName.hasPrefix("META_") })
        #expect(refs.allSatisfy { $0.offset >= 0 && $0.size >= 0 && !$0.isEMFPlusCarrier })

        // P3: WMF record summaries are now present (non-nil for every row, one per
        // record), and a real drawing file carries at least one non-empty summary.
        #expect(refs.indices.allSatisfy { prepared.recordSummary(at: $0) != nil })
        #expect(refs.indices.contains { !(prepared.recordSummary(at: $0) ?? "").isEmpty })
        // An out-of-range index is "" (not nil, not a trap).
        #expect(prepared.recordSummary(at: refs.count + 10) == "")
    }
}
