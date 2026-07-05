import Foundation
import Testing
@testable import EMFParse

@Suite("Text record payload decode")
struct PayloadTextTests {

    // MARK: - SETTEXTALIGN

    @Test("SETTEXTALIGN flag decode: horizontal, vertical, update-CP")
    func setTextAlignFlags() throws {
        func decodeAlign(_ raw: UInt32) throws -> TextAlign {
            var b = FixtureBuilder()
            b.appendUInt32(raw)
            let payload = try decodeSingle(FixtureBuilder.record(type: 22, payload: b.bytes))
            guard case .setTextAlign(let align) = payload else {
                Issue.record("expected .setTextAlign, got \(payload)")
                return TextAlign(rawValue: 0)
            }
            return align
        }

        // TA_NOUPDATECP=0, TA_LEFT=0, TA_TOP=0 ([MS-WMF] §2.1.2.3): all zero bits.
        let none = try decodeAlign(0)
        #expect(none.updatesCurrentPosition == false)
        #expect(none.horizontal == .left)
        #expect(none.vertical == .top)

        // TA_UPDATECP=1.
        #expect(try decodeAlign(1).updatesCurrentPosition == true)

        // TA_RIGHT=2, TA_CENTER=6 (center shares the right bit).
        #expect(try decodeAlign(2).horizontal == .right)
        #expect(try decodeAlign(6).horizontal == .center)

        // TA_BOTTOM=8, TA_BASELINE=24 (baseline shares the bottom bit).
        #expect(try decodeAlign(8).vertical == .bottom)
        #expect(try decodeAlign(24).vertical == .baseline)

        // A realistic combination: TA_UPDATECP | TA_RIGHT | TA_BASELINE = 1|2|24 = 27.
        let combined = try decodeAlign(27)
        #expect(combined.updatesCurrentPosition == true)
        #expect(combined.horizontal == .right)
        #expect(combined.vertical == .baseline)
        #expect(combined.rawValue == 27)
    }

    // MARK: - Color records

    @Test("SETTEXTCOLOR and SETBKCOLOR: ColorRef at offset 8")
    func colorRecords() throws {
        // ColorRef byte order Red, Green, Blue, Reserved ([MS-WMF] §2.2.2.8).
        var b = FixtureBuilder()
        b.appendBytes([0x0A, 0x0B, 0x0C, 0x00])
        #expect(try decodeSingle(FixtureBuilder.record(type: 24, payload: b.bytes))
            == .setTextColor(ColorRef(red: 0x0A, green: 0x0B, blue: 0x0C, reserved: 0)))
        #expect(try decodeSingle(FixtureBuilder.record(type: 25, payload: b.bytes))
            == .setBkColor(ColorRef(red: 0x0A, green: 0x0B, blue: 0x0C, reserved: 0)))
    }

    // MARK: - EXTCREATEFONTINDIRECTW

    /// A 92-byte LogFont ([MS-EMF] §2.2.13) with the given signed height,
    /// weight, italic flag, and face name (≤ 32 UTF-16 units). `faceUnits`
    /// overrides the code-unit count written (used to test the exactly-32-units
    /// no-NUL case).
    private static func logFontBytes(
        height: Int32 = -32,
        width: Int32 = 0,
        escapement: Int32 = 0,
        orientation: Int32 = 0,
        weight: Int32 = 400,
        italic: UInt8 = 0,
        underline: UInt8 = 0,
        strikeOut: UInt8 = 0,
        charSet: UInt8 = 0,
        outPrecision: UInt8 = 0,
        clipPrecision: UInt8 = 0,
        quality: UInt8 = 0,
        pitchAndFamily: UInt8 = 0,
        faceName: String
    ) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendInt32(height)         // +0
        b.appendInt32(width)          // +4
        b.appendInt32(escapement)     // +8
        b.appendInt32(orientation)    // +12
        b.appendInt32(weight)         // +16
        b.appendBytes([italic, underline, strikeOut, charSet])          // +20
        b.appendBytes([outPrecision, clipPrecision, quality, pitchAndFamily]) // +24
        // FaceName: 64 bytes = 32 UTF-16LE code units, NUL-padded (+28).
        var units = Array(faceName.utf16)
        if units.count > 32 { units = Array(units.prefix(32)) }
        for unit in units { b.appendUInt16(unit) }
        let pad = 32 - units.count
        if pad > 0 { b.appendZeros(pad * 2) }
        return b.bytes
    }

    @Test("EXTCREATEFONTINDIRECTW golden: LogFont all fields + facename")
    func extCreateFontGolden() throws {
        var b = FixtureBuilder()
        b.appendUInt32(3)             // ihFonts
        b.appendBytes(Self.logFontBytes(
            height: -481,             // negative → character height (sign carried)
            width: 7,
            escapement: 900,
            orientation: 450,
            weight: 700,
            italic: 1,
            underline: 1,
            strikeOut: 0,
            charSet: 0,
            outPrecision: 3,
            clipPrecision: 2,
            quality: 1,
            pitchAndFamily: 0x22,
            faceName: "Arial"
        ))
        // Record = 8 (Type/Size) + 4 (ihFonts) + 92 (LogFont) = 104 bytes.
        let payload = try decodeSingle(FixtureBuilder.record(type: 82, payload: b.bytes))
        guard case .extCreateFontIndirectW(let font) = payload else {
            Issue.record("expected .extCreateFontIndirectW, got \(payload)")
            return
        }
        #expect(font.ihFonts == 3)
        #expect(font.hasExtendedData == false)     // elw == 92 → plain LogFont
        #expect(font.logFont.height == -481)       // sign preserved
        #expect(font.logFont.width == 7)
        #expect(font.logFont.escapement == 900)
        #expect(font.logFont.orientation == 450)
        #expect(font.logFont.weight == 700)
        #expect(font.logFont.italic == 1)
        #expect(font.logFont.underline == 1)
        #expect(font.logFont.strikeOut == 0)
        #expect(font.logFont.charSet == 0)
        #expect(font.logFont.outPrecision == 3)
        #expect(font.logFont.clipPrecision == 2)
        #expect(font.logFont.quality == 1)
        #expect(font.logFont.pitchAndFamily == 0x22)
        #expect(font.logFont.faceName == "Arial")
    }

    @Test("EXTCREATEFONTINDIRECTW facename using all 32 units, no NUL")
    func extCreateFontFacenameFull32() throws {
        // A 32-character name fills FaceName with no terminating NUL (§2.2.13:
        // "If less than 32 characters, a terminating NULL MUST be present").
        let name = String(repeating: "A", count: 32)
        #expect(name.utf16.count == 32)
        var b = FixtureBuilder()
        b.appendUInt32(1)
        b.appendBytes(Self.logFontBytes(faceName: name))
        let payload = try decodeSingle(FixtureBuilder.record(type: 82, payload: b.bytes))
        guard case .extCreateFontIndirectW(let font) = payload else {
            Issue.record("expected .extCreateFontIndirectW, got \(payload)")
            return
        }
        #expect(font.logFont.faceName == name)     // all 32 units decoded
        #expect(font.logFont.faceName.count == 32)
    }

    @Test("EXTCREATEFONTINDIRECTW LogFontExDv-sized record decodes the LogFont prefix")
    func extCreateFontLogFontExDv() throws {
        // A 332-byte record (elw = 320 = LogFontPanose) or larger carries the
        // same 92-byte LogFont prefix (§2.2.14/.15/.16); the prefix decodes and
        // hasExtendedData is set. Match the real corpus font records exactly.
        var b = FixtureBuilder()
        b.appendUInt32(1)                                  // ihFonts
        b.appendBytes(Self.logFontBytes(
            height: -741, weight: 400, faceName: "Times New Roman"
        ))                                                 // 92-byte LogFont
        b.appendZeros(320 - 92)                            // remainder of a 320-byte elw
        // Record = 8 + 4 + 320 = 332 bytes.
        let payload = try decodeSingle(FixtureBuilder.record(type: 82, payload: b.bytes))
        guard case .extCreateFontIndirectW(let font) = payload else {
            Issue.record("expected .extCreateFontIndirectW, got \(payload)")
            return
        }
        #expect(font.ihFonts == 1)
        #expect(font.hasExtendedData == true)              // elw (320) > 92
        #expect(font.logFont.height == -741)
        #expect(font.logFont.weight == 400)
        #expect(font.logFont.faceName == "Times New Roman")
    }

    @Test("EXTCREATEFONTINDIRECTW too small (record < 104) → malformed")
    func extCreateFontTooSmall() throws {
        var b = FixtureBuilder()
        b.appendUInt32(1)
        b.appendZeros(40)      // far short of a 92-byte LogFont
        // Record = 8 + 4 (ihFonts) + 40 = 52 bytes; the 92-byte LogFont at
        // record offset 12 needs the record to reach 104.
        let payload = try decodeSingle(FixtureBuilder.record(type: 82, payload: b.bytes))
        #expect(payload == .malformed(type: 82, reason: .tooSmall(minimumSize: 104, actualSize: 52)))
    }

    // MARK: - EXTTEXTOUTW

    /// Builds an EMR_EXTTEXTOUTW record's payload (record offsets ≥ 8) around a
    /// string and optional Dx array. The EmrText fixed fields occupy record
    /// offsets 36..76; the string is placed at `offString` and the Dx at
    /// `offDx` (both record-start-relative, §2.2.5), each after the fixed part.
    /// Returns the full record bytes with a correct nSize.
    private static func extTextOutRecord(
        graphicsMode: UInt32 = 1,
        exScale: Float = 1.0,
        eyScale: Float = 1.0,
        reference: PointL = PointL(x: 10, y: 20),
        chars: UInt32,
        options: UInt32 = 0,
        rectangle: RectL = RectL(left: 0, top: 0, right: 100, bottom: 40),
        string: [UInt16],
        dx: [UInt32]? = nil,
        // Overrides to build malformed fixtures without a valid layout.
        offStringOverride: UInt32? = nil,
        offDxOverride: UInt32? = nil,
        charsOverride: UInt32? = nil
    ) -> [UInt8] {
        // Fixed EmrText part ends at record offset 76. Place the string there,
        // then the Dx (32-bit aligned) immediately after.
        let offString = 76
        let stringBytes = string.count * 2
        // Dx follows the string, padded to a 4-byte boundary.
        let dxStart = (offString + stringBytes + 3) & ~3
        let hasDx = dx != nil

        var payload = FixtureBuilder()            // starts at record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 0, bottom: 0))) // Bounds@8 (ignored)
        payload.appendUInt32(graphicsMode)        // iGraphicsMode@24
        payload.appendFloat(exScale)              // exScale@28
        payload.appendFloat(eyScale)              // eyScale@32
        payload.appendInt32(reference.x)          // Reference@36
        payload.appendInt32(reference.y)          // @40
        payload.appendUInt32(charsOverride ?? chars)      // Chars@44
        payload.appendUInt32(offStringOverride ?? UInt32(offString)) // offString@48
        payload.appendUInt32(options)             // Options@52
        payload.appendBytes(FixtureBuilder.rectBytes(rectangle)) // Rectangle@56 (16)
        payload.appendUInt32(offDxOverride ?? (hasDx ? UInt32(dxStart) : 0)) // offDx@72
        // Now payload length == 68 (record offset 8..76). String at offset 76.
        for unit in string { payload.appendUInt16(unit) }
        if hasDx {
            // Pad to the 4-byte-aligned dxStart.
            let currentRecordOffset = 8 + payload.count
            let pad = dxStart - currentRecordOffset
            if pad > 0 { payload.appendZeros(pad) }
            for value in dx! { payload.appendUInt32(value) }
        }
        // Records MUST be 4-aligned ([MS-EMF] §2.1) or the walker rejects them;
        // pad the trailing string bytes up to a 4-byte record boundary.
        let recordSize = 8 + payload.count
        let alignPad = (4 - recordSize % 4) % 4
        if alignPad > 0 { payload.appendZeros(alignPad) }
        return FixtureBuilder.record(type: 84, payload: payload.bytes)
    }

    @Test("EXTTEXTOUTW golden without Dx: string, reference, options")
    func extTextOutGoldenNoDx() throws {
        let str = Array("Hi".utf16)
        let record = Self.extTextOutRecord(
            reference: PointL(x: 5, y: 7),
            chars: UInt32(str.count),
            options: 0x0002,     // ETO_OPAQUE
            string: str
        )
        let payload = try decodeSingle(record)
        guard case .extTextOutW(let text) = payload else {
            Issue.record("expected .extTextOutW, got \(payload)")
            return
        }
        #expect(text.string == "Hi")
        #expect(text.reference == PointL(x: 5, y: 7))
        #expect(text.graphicsMode == 1)
        #expect(text.exScale == 1.0)
        #expect(text.eyScale == 1.0)
        #expect(text.options.opaque == true)
        #expect(text.options.glyphIndex == false)
        #expect(text.dx == nil)
    }

    @Test("EXTTEXTOUTW golden with Dx: advances asserted")
    func extTextOutGoldenWithDx() throws {
        let str = Array("abc".utf16)
        let advances: [UInt32] = [11, 22, 33]
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            string: str,
            dx: advances
        )
        let payload = try decodeSingle(record)
        guard case .extTextOutW(let text) = payload else {
            Issue.record("expected .extTextOutW, got \(payload)")
            return
        }
        #expect(text.string == "abc")
        #expect(text.dx == advances)          // exactly Chars entries
    }

    @Test("EXTTEXTOUTW with ETO_PDY: Dx array is 2×Chars long")
    func extTextOutPDY() throws {
        let str = Array("xy".utf16)            // 2 chars
        // ETO_PDY → 2 values per char = 4 values.
        let advances: [UInt32] = [1, 2, 3, 4]
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            options: 0x2000,                   // ETO_PDY
            string: str,
            dx: advances
        )
        let payload = try decodeSingle(record)
        guard case .extTextOutW(let text) = payload else {
            Issue.record("expected .extTextOutW, got \(payload)")
            return
        }
        #expect(text.options.pdy == true)
        #expect(text.dx?.count == 4)           // 2 × Chars
        #expect(text.dx == advances)
    }

    @Test("EXTTEXTOUTW GLYPH_INDEX flag surfaced")
    func extTextOutGlyphIndex() throws {
        let str = Array("g".utf16)
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            options: 0x0010,                   // ETO_GLYPH_INDEX
            string: str
        )
        let payload = try decodeSingle(record)
        guard case .extTextOutW(let text) = payload else {
            Issue.record("expected .extTextOutW, got \(payload)")
            return
        }
        #expect(text.options.glyphIndex == true)
    }

    @Test("EXTTEXTOUTW offString beyond record → malformed")
    func extTextOutOffStringBeyondRecord() throws {
        let str = Array("Hi".utf16)
        // Point offString far past nSize.
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            string: str,
            offStringOverride: 100_000
        )
        // "Hi" → 2 chars → 4 string bytes; record is 80 bytes. The overlarge
        // offString fails the string byte-range check against nSize (§8).
        let payload = try decodeSingle(record)
        #expect(payload == .malformed(type: 84, reason: .rangeOutOfBounds(offset: 100_000, length: 4, recordSize: 80)))
    }

    @Test("EXTTEXTOUTW Chars lying vs nSize → malformed")
    func extTextOutCharsLie() throws {
        let str = Array("Hi".utf16)            // 2 real chars at offset 76
        // Claim a huge Chars so 2×Chars overruns the record.
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            string: str,
            charsOverride: 100_000
        )
        // Chars lies (100_000 → 200_000 string bytes) while offString stays at
        // the real 76; the string range overruns the 80-byte record (§8).
        let payload = try decodeSingle(record)
        #expect(payload == .malformed(type: 84, reason: .rangeOutOfBounds(offset: 76, length: 200_000, recordSize: 80)))
    }

    @Test("EXTTEXTOUTW offDx pointing outside record → malformed")
    func extTextOutOffDxOutside() throws {
        let str = Array("Hi".utf16)
        let record = Self.extTextOutRecord(
            chars: UInt32(str.count),
            string: str,
            dx: [1, 2],
            offDxOverride: 100_000             // far past nSize
        )
        // The string decodes; then offDx (100_000) fails the Dx byte-range
        // check — 2 chars, no ETO_PDY → 2 advances → 8 bytes — against the
        // 88-byte record (§8).
        let payload = try decodeSingle(record)
        #expect(payload == .malformed(type: 84, reason: .rangeOutOfBounds(offset: 100_000, length: 8, recordSize: 88)))
    }

    @Test("EXTTEXTOUTW non-finite exScale → malformed")
    func extTextOutNonFiniteScale() throws {
        let str = Array("Hi".utf16)
        let record = Self.extTextOutRecord(
            exScale: .infinity,
            chars: UInt32(str.count),
            string: str
        )
        let payload = try decodeSingle(record)
        #expect(payload == .malformed(type: 84, reason: .nonFiniteTransform))
    }
}
