import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for EMR_SETSTRETCHBLTMODE (21), the single-u32 StretchMode
/// state record ([MS-EMF] §2.3.11.24, [MS-WMF] §2.1.1.20). A golden decode of
/// every defined mode plus an unknown value, and a truncated variant.
@Suite("SETSTRETCHBLTMODE record decode")
struct PayloadStretchBltModeTests {

    private static func record(_ raw: UInt32) -> [UInt8] {
        var b = FixtureBuilder(); b.appendUInt32(raw)
        return FixtureBuilder.record(type: 21, payload: b.bytes)
    }

    @Test("every defined StretchMode and an unknown value decode")
    func golden() throws {
        #expect(try decodeSingle(Self.record(1)) == .setStretchBltMode(.blackOnWhite))
        #expect(try decodeSingle(Self.record(2)) == .setStretchBltMode(.whiteOnBlack))
        #expect(try decodeSingle(Self.record(3)) == .setStretchBltMode(.colorOnColor))
        #expect(try decodeSingle(Self.record(4)) == .setStretchBltMode(.halftone))
        #expect(try decodeSingle(Self.record(42)) == .setStretchBltMode(.unknown(42)))
    }

    @Test("truncated SETSTRETCHBLTMODE (no mode field) is malformed, not a crash")
    func truncated() throws {
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 21, payload: []))
        #expect(file.diagnostics.isEmpty)
        #expect(file.payload(of: record)
            == .malformed(type: 21, reason: .tooSmall(minimumSize: 12, actualSize: 8)))
    }
}
