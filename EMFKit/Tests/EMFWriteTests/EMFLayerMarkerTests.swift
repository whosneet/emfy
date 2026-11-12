import Foundation
import Testing
import EMFParse
import EMFWrite

/// The private EMR_COMMENT layer markers ([MS-EMF] §2.3.3): encode → decode is a
/// fixed point, the records parse as ordinary comments, and hostile bytes decode
/// to nil without trapping (§8).
@Suite("Layer markers")
struct EMFLayerMarkerTests {

    @Test func beginRoundTrips() {
        let bytes = EMFLayerMarker.begin(name: "Background", hidden: true, locked: false)
        let marker = EMFLayerMarker.decode(recordBytes: bytes)
        #expect(marker == EMFLayerMarker.Marker(kind: .begin, name: "Background", hidden: true, locked: false))
    }

    @Test func endRoundTrips() {
        let bytes = EMFLayerMarker.end()
        #expect(EMFLayerMarker.decode(recordBytes: bytes)
            == EMFLayerMarker.Marker(kind: .end, name: "", hidden: false, locked: false))
    }

    @Test(arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func flagsRoundTrip(hidden: Bool, locked: Bool) {
        let bytes = EMFLayerMarker.begin(name: "L", hidden: hidden, locked: locked)
        let marker = EMFLayerMarker.decode(recordBytes: bytes)
        #expect(marker?.hidden == hidden)
        #expect(marker?.locked == locked)
    }

    @Test func unicodeNameRoundTrips() {
        let name = "レイヤー 1 — café 🎨"
        let bytes = EMFLayerMarker.begin(name: name, hidden: false, locked: false)
        #expect(EMFLayerMarker.decode(recordBytes: bytes)?.name == name)
    }

    /// The record is a well-formed, 4-aligned EMR_COMMENT (Type 70, nSize >= 8).
    @Test func isAWellFormedComment() {
        let marker = EMFLayerMarker.begin(name: "Shapes", hidden: false, locked: true)
        #expect(marker.count % 4 == 0)
        #expect(marker.count >= 8)
        #expect(marker[0] == 70)   // EMR_COMMENT type id
    }

    // MARK: - Hostile inputs (§8): never a trap, always nil

    @Test func rejectsShortRecord() {
        #expect(EMFLayerMarker.decode(recordBytes: []) == nil)
        #expect(EMFLayerMarker.decode(recordBytes: [70, 0, 0, 0]) == nil)
        #expect(EMFLayerMarker.decode(recordBytes: [70, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func rejectsWrongType() {
        var bytes = EMFLayerMarker.begin(name: "X", hidden: false, locked: false)
        bytes[0] = 71   // not EMR_COMMENT
        #expect(EMFLayerMarker.decode(recordBytes: bytes) == nil)
    }

    @Test func rejectsForeignSignature() {
        // An EMF+ comment: Type 70, DataSize 8, identifier "EMF+" then four bytes.
        var w = LE()
        w.u32(70); w.u32(24); w.u32(12)
        w.u32(0x2B46_4D45); w.u32(0x4001); w.u32(0)
        #expect(EMFLayerMarker.decode(recordBytes: w.bytes) == nil)
    }

    @Test func rejectsLyingDataSize() {
        var bytes = EMFLayerMarker.begin(name: "Name", hidden: false, locked: false)
        // Overstate DataSize far past the record — bounds-checked, no trap.
        bytes[8] = 0xFF; bytes[9] = 0xFF; bytes[10] = 0xFF; bytes[11] = 0x7F
        #expect(EMFLayerMarker.decode(recordBytes: bytes) == nil)
    }

    @Test func rejectsLyingNameLength() {
        var bytes = EMFLayerMarker.begin(name: "AB", hidden: false, locked: false)
        // nameLen field sits at CommentData offset 12 (signature 8 + kind/flags/reserved 4),
        // i.e. record offset 12 + 12 = 24. Set it to a huge value.
        bytes[24] = 0xFF; bytes[25] = 0xFF; bytes[26] = 0xFF; bytes[27] = 0x7F
        #expect(EMFLayerMarker.decode(recordBytes: bytes) == nil)
    }

    @Test func clampsOverlongNameOnEncode() {
        let huge = String(repeating: "A", count: EMFLayerMarker.maxNameBytes + 500)
        let bytes = EMFLayerMarker.begin(name: huge, hidden: false, locked: false)
        let marker = EMFLayerMarker.decode(recordBytes: bytes)
        #expect(marker?.name.utf8.count == EMFLayerMarker.maxNameBytes)
    }
}
