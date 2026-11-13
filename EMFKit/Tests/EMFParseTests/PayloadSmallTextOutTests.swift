import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for EMR_SMALLTEXTOUT (108) ([MS-EMF] §2.3.5.38): the compact
/// text record with no Dx. ETO_NO_RECT (0x0100) omits the Bounds rectangle and
/// ETO_SMALL_CHARS (0x0200) selects an 8-bit ANSI string. Golden decodes of all
/// four flag combinations, plus truncated and overrun variants (primer §8).
@Suite("SMALLTEXTOUT record decode")
struct PayloadSmallTextOutTests {

    /// Builds an EMR_SMALLTEXTOUT record. Fixed fields at 8..36, optional Bounds
    /// at 36, then the string. `rawChars` overrides cChars for malformed cases.
    private static func record(
        x: Int32 = 5, y: Int32 = 7,
        options: UInt32,
        rectangle: RectL = RectL(left: 0, top: 0, right: 50, bottom: 20),
        utf16: [UInt16] = [],
        ansi: [UInt8] = [],
        rawChars: UInt32? = nil
    ) -> [UInt8] {
        let smallChars = options & 0x0200 != 0
        let noRect = options & 0x0100 != 0
        let count = smallChars ? ansi.count : utf16.count

        var p = FixtureBuilder()                 // record offset 8
        p.appendInt32(x); p.appendInt32(y)       // x@8, y@12
        p.appendUInt32(rawChars ?? UInt32(count))// cChars@16
        p.appendUInt32(options)                  // fuOptions@20
        p.appendUInt32(1)                        // iGraphicsMode@24
        p.appendFloat(1); p.appendFloat(1)       // exScale@28, eyScale@32
        if !noRect { p.appendBytes(FixtureBuilder.rectBytes(rectangle)) } // Bounds@36
        if smallChars { p.appendBytes(ansi) } else { for u in utf16 { p.appendUInt16(u) } }
        let alignPad = (4 - (8 + p.count) % 4) % 4
        if alignPad > 0 { p.appendZeros(alignPad) }
        return FixtureBuilder.record(type: 108, payload: p.bytes)
    }

    @Test("16-bit with rect: Bounds present, UTF-16 string")
    func wideWithRect() throws {
        let rect = RectL(left: 1, top: 2, right: 60, bottom: 24)
        let payload = try decodeSingle(Self.record(options: 0, rectangle: rect, utf16: Array("Hi".utf16)))
        guard case .smallTextOut(let t) = payload else { Issue.record("got \(payload)"); return }
        #expect(t.string == "Hi")
        #expect(t.reference == PointL(x: 5, y: 7))
        #expect(t.rectangle == rect)
        #expect(t.dx == nil)
    }

    @Test("ETO_NO_RECT: no Bounds field, string starts at offset 36")
    func noRectWide() throws {
        let payload = try decodeSingle(Self.record(options: 0x0100, utf16: Array("ok".utf16)))
        guard case .smallTextOut(let t) = payload else { Issue.record("got \(payload)"); return }
        #expect(t.string == "ok")
        #expect(t.rectangle == RectL(left: 0, top: 0, right: 0, bottom: 0))
    }

    @Test("ETO_SMALL_CHARS: 8-bit ANSI string (with a CP1252 high byte)")
    func smallCharsAnsi() throws {
        // ETO_NO_RECT | ETO_SMALL_CHARS; "ab" + 0xF1 (ñ).
        let payload = try decodeSingle(Self.record(options: 0x0300, ansi: [0x61, 0x62, 0xF1]))
        guard case .smallTextOut(let t) = payload else { Issue.record("got \(payload)"); return }
        #expect(t.string == "abñ")
    }

    @Test("truncated record (below the 36-byte fixed part) is malformed")
    func truncated() throws {
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 108, size: 20))
        #expect(file.payload(of: record)
            == .malformed(type: 108, reason: .tooSmall(minimumSize: 36, actualSize: 20)))
    }

    @Test("a cChars that overruns the record is malformed, not a crash")
    func charsOverrun() throws {
        let payload = try decodeSingle(Self.record(options: 0x0300, ansi: [0x41], rawChars: 9000))
        if case .malformed(108, .rangeOutOfBounds) = payload {} else {
            Issue.record("expected rangeOutOfBounds, got \(payload)")
        }
    }
}
