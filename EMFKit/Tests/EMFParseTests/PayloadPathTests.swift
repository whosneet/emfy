import Foundation
import Testing
@testable import EMFParse

@Suite("Path record payload decode")
struct PayloadPathTests {

    // MARK: - Parameterless path records

    @Test("beginPath, endPath, closeFigure decode from an 8-byte record")
    func parameterlessPathRecords() throws {
        // EMR_BEGINPATH (59) / EMR_ENDPATH (60) / EMR_CLOSEFIGURE (61) carry
        // no body ([MS-EMF] §2.3.5 drawing-record catalog): Type + Size only.
        #expect(try decodeSingle(FixtureBuilder.record(type: 59, payload: [])) == .beginPath)
        #expect(try decodeSingle(FixtureBuilder.record(type: 60, payload: [])) == .endPath)
        #expect(try decodeSingle(FixtureBuilder.record(type: 61, payload: [])) == .closeFigure)
    }

    // MARK: - Bounds-carrying path closers

    /// The three closers share the same 24-byte layout: Bounds RectL at
    /// offset 8 ([MS-EMF] §2.3.5.9/.38/.39).
    private static func closerRecord(type: UInt32, bounds: RectL) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendInt32(bounds.left)
        b.appendInt32(bounds.top)
        b.appendInt32(bounds.right)
        b.appendInt32(bounds.bottom)
        return FixtureBuilder.record(type: type, payload: b.bytes)
    }

    @Test("fillPath, strokeAndFillPath, strokePath golden: Bounds asserted")
    func pathClosersGolden() throws {
        let bounds = RectL(left: 10, top: 20, right: 310, bottom: 220)

        let fill = Self.closerRecord(type: 62, bounds: bounds)
        // 8-byte Type/Size header + 16-byte Bounds = 24 bytes total.
        #expect(fill.count == 24)
        #expect(try decodeSingle(fill) == .fillPath(bounds: bounds))

        #expect(try decodeSingle(Self.closerRecord(type: 63, bounds: bounds))
            == .strokeAndFillPath(bounds: bounds))
        #expect(try decodeSingle(Self.closerRecord(type: 64, bounds: bounds))
            == .strokePath(bounds: bounds))
    }

    @Test(
        "path closer shorter than 24 bytes is malformed (spec-literal Bounds)",
        arguments: [UInt32(62), 63, 64]
    )
    func pathCloserTooSmall(type: UInt32) throws {
        // A 20-byte record has room for only three of the four Bounds ints;
        // real emitters always write all 24 bytes, so this is .malformed
        // (never a lenient zero-bounds fallback).
        let (file, record) = try parseWithSingleRecord(
            FixtureBuilder.record(type: type, payload: [UInt8](repeating: 0, count: 12))
        )
        #expect(file.diagnostics.isEmpty)   // 20-byte record is walk-valid
        #expect(file.payload(of: record)
            == .malformed(type: type, reason: .tooSmall(minimumSize: 24, actualSize: 20)))
    }
}
