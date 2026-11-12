import Foundation
import Testing
import EMFParse
import EMFWrite

/// The private EMR_COMMENT layer table ([MS-EMF] §2.3.3): encode → decode is a
/// fixed point, the record is a well-formed comment, and hostile bytes decode to
/// nil without trapping (§8).
@Suite("Layer table")
struct EMFLayerMarkerTests {

    typealias Info = EMFLayerMarker.LayerInfo

    @Test func tableRoundTrips() {
        let layers = [
            Info(name: "Background", hidden: false, locked: true, count: 3),
            Info(name: "Shapes", hidden: false, locked: false, count: 0),
            Info(name: "Notes", hidden: true, locked: false, count: 5),
        ]
        let bytes = EMFLayerMarker.table(layers)
        #expect(EMFLayerMarker.decodeTable(recordBytes: bytes) == layers)
    }

    @Test func emptyTableRoundTrips() {
        let bytes = EMFLayerMarker.table([])
        #expect(EMFLayerMarker.decodeTable(recordBytes: bytes) == [])
    }

    @Test func unicodeNameRoundTrips() {
        let layers = [Info(name: "レイヤー 1 — café 🎨", hidden: false, locked: false, count: 1)]
        #expect(EMFLayerMarker.decodeTable(recordBytes: EMFLayerMarker.table(layers)) == layers)
    }

    /// The record is a well-formed, 4-aligned EMR_COMMENT (Type 70, nSize >= 8).
    @Test func isAWellFormedComment() {
        let bytes = EMFLayerMarker.table([Info(name: "Shapes", hidden: false, locked: true, count: 2)])
        #expect(bytes.count % 4 == 0)
        #expect(bytes.count >= 8)
        #expect(bytes[0] == 70)   // EMR_COMMENT type id
        #expect(EMFLayerMarker.isLayerTable(recordBytes: bytes))
    }

    // MARK: - Hostile inputs (§8): never a trap, always nil

    @Test func rejectsShortRecord() {
        #expect(EMFLayerMarker.decodeTable(recordBytes: []) == nil)
        #expect(EMFLayerMarker.decodeTable(recordBytes: [70, 0, 0, 0]) == nil)
        #expect(EMFLayerMarker.decodeTable(recordBytes: [70, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func rejectsWrongType() {
        var bytes = EMFLayerMarker.table([Info(name: "X", hidden: false, locked: false, count: 1)])
        bytes[0] = 71   // not EMR_COMMENT
        #expect(EMFLayerMarker.decodeTable(recordBytes: bytes) == nil)
    }

    @Test func rejectsForeignSignature() {
        // An EMF+ comment: Type 70, DataSize 12, identifier "EMF+" then two words.
        var w = LE()
        w.u32(70); w.u32(24); w.u32(12)
        w.u32(0x2B46_4D45); w.u32(0x4001); w.u32(0)
        #expect(EMFLayerMarker.decodeTable(recordBytes: w.bytes) == nil)
    }

    @Test func rejectsLyingDataSize() {
        var bytes = EMFLayerMarker.table([Info(name: "Name", hidden: false, locked: false, count: 1)])
        bytes[8] = 0xFF; bytes[9] = 0xFF; bytes[10] = 0xFF; bytes[11] = 0x7F
        #expect(EMFLayerMarker.decodeTable(recordBytes: bytes) == nil)
    }

    @Test func rejectsLyingLayerCount() {
        var bytes = EMFLayerMarker.table([Info(name: "A", hidden: false, locked: false, count: 1)])
        // layerCount (u16) sits at CommentData offset 10 → record offset 12 + 10 = 22.
        bytes[22] = 0xFF; bytes[23] = 0xFF   // 65535 layers, way past the data
        #expect(EMFLayerMarker.decodeTable(recordBytes: bytes) == nil)
    }

    @Test func clampsOverlongNameOnEncode() {
        let huge = String(repeating: "A", count: EMFLayerMarker.maxNameBytes + 500)
        let bytes = EMFLayerMarker.table([Info(name: huge, hidden: false, locked: false, count: 0)])
        let decoded = EMFLayerMarker.decodeTable(recordBytes: bytes)
        #expect(decoded?.first?.name.utf8.count == EMFLayerMarker.maxNameBytes)
    }
}
