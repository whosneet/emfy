import Foundation
import Testing
@testable import EMFParse

@Suite("Object record payload decode")
struct PayloadObjectTests {

    @Test("createPen golden: ihPen, LogPen fields")
    func createPenGolden() throws {
        var b = FixtureBuilder()
        b.appendUInt32(7)                       // ihPen
        b.appendUInt32(0)                       // PenStyle = PS_SOLID
        b.appendInt32(3)                        // Width.x
        b.appendInt32(0)                        // Width.y (ignored per spec)
        b.appendBytes([0xFF, 0x00, 0x00, 0x00]) // ColorRef: red
        #expect(try decodeSingle(FixtureBuilder.record(type: 38, payload: b.bytes))
            == .createPen(CreatePenPayload(
                ihPen: 7,
                style: 0,
                width: PointL(x: 3, y: 0),
                color: ColorRef(red: 255, green: 0, blue: 0, reserved: 0)
            )))
    }

    @Test("ColorRef byte order is Red, Green, Blue, Reserved")
    func colorRefByteOrder() throws {
        // [MS-WMF] §2.2.2.8: first byte on disk is Red.
        var b = FixtureBuilder()
        b.appendUInt32(2)                       // ihBrush
        b.appendUInt32(0)                       // BrushStyle = BS_SOLID
        b.appendBytes([0x11, 0x22, 0x33, 0x00]) // ColorRef bytes
        b.appendUInt32(0)                       // BrushHatch
        let payload = try decodeSingle(FixtureBuilder.record(type: 39, payload: b.bytes))
        #expect(payload == .createBrushIndirect(CreateBrushPayload(
            ihBrush: 2,
            style: 0,
            color: ColorRef(red: 0x11, green: 0x22, blue: 0x33, reserved: 0),
            hatch: 0
        )))
    }

    @Test("selectObject: stock, unknown stock, and table indices")
    func selectObjectHandles() throws {
        func ihPayload(_ raw: UInt32) -> [UInt8] {
            var b = FixtureBuilder()
            b.appendUInt32(raw)
            return b.bytes
        }

        // NULL_BRUSH = 0x80000005 ([MS-EMF] §2.1.31).
        #expect(try decodeSingle(FixtureBuilder.record(type: 37, payload: ihPayload(0x8000_0005)))
            == .selectObject(.stock(.nullBrush)))
        // 0x80000009 is undefined in the enumeration → unknownStock.
        #expect(try decodeSingle(FixtureBuilder.record(type: 37, payload: ihPayload(0x8000_0009)))
            == .selectObject(.stock(.unknownStock(0x8000_0009))))
        // High bit clear → explicit object-table index.
        #expect(try decodeSingle(FixtureBuilder.record(type: 37, payload: ihPayload(3)))
            == .selectObject(.table(index: 3)))
    }

    @Test("deleteObject decodes the same handle scheme")
    func deleteObjectHandle() throws {
        var b = FixtureBuilder()
        b.appendUInt32(5)
        #expect(try decodeSingle(FixtureBuilder.record(type: 40, payload: b.bytes))
            == .deleteObject(.table(index: 5)))
    }

    @Test("extCreatePen golden with a user-style array")
    func extCreatePenGolden() throws {
        var b = FixtureBuilder()
        b.appendUInt32(4)                       // ihPen
        b.appendUInt32(0)                       // offBmi
        b.appendUInt32(0)                       // cbBmi
        b.appendUInt32(0)                       // offBits
        b.appendUInt32(0)                       // cbBits
        b.appendUInt32(0x0001_0007)             // PenStyle = PS_GEOMETRIC | PS_USERSTYLE
        b.appendUInt32(20)                      // Width (u32 in LogPenEx)
        b.appendUInt32(0)                       // BrushStyle = BS_SOLID
        b.appendBytes([0x00, 0x00, 0xFF, 0x00]) // ColorRef: blue
        b.appendUInt32(0)                       // BrushHatch
        b.appendUInt32(2)                       // NumStyleEntries
        b.appendUInt32(5)                       // dash length
        b.appendUInt32(3)                       // gap length
        #expect(try decodeSingle(FixtureBuilder.record(type: 95, payload: b.bytes))
            == .extCreatePen(ExtCreatePenPayload(
                ihPen: 4,
                offBmi: 0,
                cbBmi: 0,
                offBits: 0,
                cbBits: 0,
                style: 0x0001_0007,
                width: 20,
                brushStyle: 0,
                color: ColorRef(red: 0, green: 0, blue: 255, reserved: 0),
                brushHatch: 0,
                styleEntries: [5, 3]
            )))
    }

    @Test("extCreatePen lying NumStyleEntries: countTooLarge, walk unaffected")
    func extCreatePenLyingCount() throws {
        var b = FixtureBuilder()
        b.appendUInt32(4)                       // ihPen
        b.appendUInt32(0)                       // offBmi
        b.appendUInt32(0)                       // cbBmi
        b.appendUInt32(0)                       // offBits
        b.appendUInt32(0)                       // cbBits
        b.appendUInt32(0x0001_0007)             // PenStyle
        b.appendUInt32(20)                      // Width
        b.appendUInt32(0)                       // BrushStyle
        b.appendBytes([0x00, 0x00, 0xFF, 0x00]) // ColorRef
        b.appendUInt32(0)                       // BrushHatch
        b.appendUInt32(100)                     // NumStyleEntries: LIES
        b.appendUInt32(5)                       // only 2 entries present
        b.appendUInt32(3)

        let (file, record) = try parseWithSingleRecord(
            FixtureBuilder.record(type: 95, payload: b.bytes)
        )
        #expect(file.diagnostics.isEmpty)       // walk is untouched
        #expect(file.records.count == 3)
        #expect(file.payload(of: record)
            == .malformed(type: 95, reason: .countTooLarge(declared: 100, maxFitting: 2)))
    }
}
