import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for EMR_EXTTEXTOUTA (83) ([MS-EMF] §2.3.5.7): the ANSI
/// sibling of EMR_EXTTEXTOUTW. Same fixed layout, but the string is `Chars`
/// 8-bit code-page bytes decoded to Unicode (Windows-1252 → ISO-8859-1
/// fallback). Golden decode (incl. a high CP1252 byte and a Dx array), a
/// truncated variant, and a lying offString that overruns the record.
@Suite("EXTTEXTOUTA record decode")
struct PayloadExtTextOutATests {

    /// Builds an EMR_EXTTEXTOUTA record: EmrText fixed fields at offsets 36..76,
    /// the ANSI string (1 byte/char) at offset 76, then the optional 4-byte-
    /// aligned Dx. Overrides build malformed fixtures.
    private static func record(
        reference: PointL = PointL(x: 10, y: 20),
        chars: UInt32,
        options: UInt32 = 0,
        rectangle: RectL = RectL(left: 0, top: 0, right: 100, bottom: 40),
        ansiBytes: [UInt8],
        dx: [UInt32]? = nil,
        offStringOverride: UInt32? = nil
    ) -> [UInt8] {
        let offString = 76
        let dxStart = (offString + ansiBytes.count + 3) & ~3
        let hasDx = dx != nil

        var p = FixtureBuilder()                      // record offset 8
        p.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 0, bottom: 0))) // Bounds@8
        p.appendUInt32(1)                             // iGraphicsMode@24
        p.appendFloat(1); p.appendFloat(1)            // exScale@28, eyScale@32
        p.appendInt32(reference.x); p.appendInt32(reference.y) // Reference@36
        p.appendUInt32(chars)                         // Chars@44
        p.appendUInt32(offStringOverride ?? UInt32(offString)) // offString@48
        p.appendUInt32(options)                       // Options@52
        p.appendBytes(FixtureBuilder.rectBytes(rectangle)) // Rectangle@56
        p.appendUInt32(hasDx ? UInt32(dxStart) : 0)   // offDx@72
        p.appendBytes(ansiBytes)                       // ANSI string@76
        if hasDx {
            let pad = dxStart - (8 + p.count)
            if pad > 0 { p.appendZeros(pad) }
            for value in dx! { p.appendUInt32(value) }
        }
        let alignPad = (4 - (8 + p.count) % 4) % 4
        if alignPad > 0 { p.appendZeros(alignPad) }
        return FixtureBuilder.record(type: 83, payload: p.bytes)
    }

    @Test("golden: ASCII + a high CP1252 byte (0xE9 → é), with a Dx array")
    func golden() throws {
        // "café" in Windows-1252: c(0x63) a(0x61) f(0x66) é(0xE9).
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let payload = try decodeSingle(Self.record(chars: 4, ansiBytes: bytes, dx: [7, 7, 7, 7]))
        guard case .extTextOutA(let text) = payload else {
            Issue.record("expected .extTextOutA, got \(payload)")
            return
        }
        #expect(text.string == "café")
        #expect(text.reference == PointL(x: 10, y: 20))
        #expect(text.dx == [7, 7, 7, 7])
    }

    @Test("all 256 byte values decode without failing the payload")
    func totalMapping() throws {
        let bytes = (0 ..< 256).map { UInt8($0) }
        let payload = try decodeSingle(Self.record(chars: 256, ansiBytes: bytes))
        guard case .extTextOutA(let text) = payload else {
            Issue.record("expected .extTextOutA, got \(payload)")
            return
        }
        #expect(!text.string.isEmpty)   // never nil/empty: the fallback maps every byte
    }

    @Test("truncated record (short of the 76-byte fixed part) is malformed")
    func truncated() throws {
        // A 40-byte record: far short of the EmrText fixed fields.
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 83, size: 40))
        #expect(file.payload(of: record)
            == .malformed(type: 83, reason: .tooSmall(minimumSize: 76, actualSize: 40)))
    }

    @Test("an offString that overruns the record is malformed, not a crash")
    func offStringOutOfBounds() throws {
        let payload = try decodeSingle(Self.record(
            chars: 4, ansiBytes: [0x41, 0x42, 0x43, 0x44], offStringOverride: 9000
        ))
        if case .malformed(83, .rangeOutOfBounds) = payload {} else {
            Issue.record("expected .malformed rangeOutOfBounds, got \(payload)")
        }
    }
}
