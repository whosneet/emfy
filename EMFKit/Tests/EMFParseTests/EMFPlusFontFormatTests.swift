import Foundation
import Testing
@testable import EMFParse

// MARK: - Local fixture builders (mirror the sibling EMF+ object test helpers).

private func plusRecord(type: UInt16, flags: UInt16 = 0, data: [UInt8] = []) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(UInt32(12 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

private func plusComment(stream: [UInt8]) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(0x2B46_4D45)   // "EMF+"
    payload.appendBytes(stream)
    let data = payload.bytes
    var b = FixtureBuilder()
    b.appendUInt32(70)
    b.appendUInt32(UInt32(8 + 4 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

private func objectRecord(objectType: UInt8, objectBytes: [UInt8]) -> [UInt8] {
    let flags = (UInt16(objectType) & 0x7F) << 8   // objectID 0, C clear
    return plusRecord(type: 0x4008, flags: flags, data: objectBytes)
}

private func decodeObject(objectType: UInt8, objectBytes: [UInt8]) throws -> EMFPlusObjectValue {
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    fixture.appendBytes(plusComment(stream: objectRecord(objectType: objectType, objectBytes: objectBytes)))
    fixture.appendBytes(FixtureBuilder.eof())
    let (defs, _) = try EMFFile.parse(fixture.data).emfPlusStream().objectDefinitions()
    return try #require(defs.first).decodedValue()
}

private func argb(_ b: UInt8, _ g: UInt8, _ r: UInt8, _ a: UInt8) -> EMFPlusARGB {
    EMFPlusARGB(blue: b, green: g, red: r, alpha: a)
}

// EmfPlusFont payload (§2.2.1.3).
private func fontBytes(emSize: Float = 12, sizeUnit: UInt32 = 2, styleFlags: Int32 = 0,
                       nameUnits: [UInt16], lengthOverride: UInt32? = nil, trailing: [UInt8] = []) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(0xDBC0_1002)   // Version
    b.appendFloat(emSize)
    b.appendUInt32(sizeUnit)
    b.appendInt32(styleFlags)
    b.appendUInt32(0)             // Reserved
    b.appendUInt32(lengthOverride ?? UInt32(nameUnits.count))
    for unit in nameUnits { b.appendUInt16(unit) }
    b.appendBytes(trailing)
    return b.bytes
}

// EmfPlusStringFormat payload (§2.2.1.9 + §2.2.2.44).
private func stringFormatBytes(tabStops: [Float] = [], ranges: [(Int32, Int32)] = [],
                               tabStopCountOverride: Int32? = nil, rangeCountOverride: Int32? = nil) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(0xDBC0_1002)   // Version
    b.appendUInt32(0x0000_0001)   // StringFormatFlags
    b.appendUInt32(0x0000_0409)   // Language
    b.appendUInt32(1)             // StringAlignment
    b.appendUInt32(2)             // LineAlign
    b.appendUInt32(0)             // DigitSubstitution
    b.appendUInt32(0)             // DigitLanguage
    b.appendFloat(0.5)            // FirstTabOffset
    b.appendInt32(3)              // HotkeyPrefix
    b.appendFloat(1.0)            // LeadingMargin
    b.appendFloat(2.0)            // TrailingMargin
    b.appendFloat(1.25)           // Tracking
    b.appendUInt32(0)             // Trimming
    b.appendInt32(tabStopCountOverride ?? Int32(tabStops.count))
    b.appendInt32(rangeCountOverride ?? Int32(ranges.count))
    for tab in tabStops { b.appendFloat(tab) }
    for range in ranges { b.appendInt32(range.0); b.appendInt32(range.1) }
    return b.bytes
}

// MARK: - Font

@Suite("EMF+ font decode")
struct EMFPlusFontDecodeTests {

    @Test("font round-trip: CJK family name + style flags")
    func fontRoundTrip() throws {
        let name = "微软雅黑"
        let value = try decodeObject(objectType: 6, objectBytes: fontBytes(
            emSize: 14, sizeUnit: 2, styleFlags: 0x3, nameUnits: Array(name.utf16)))
        guard case .font(let font) = value else { Issue.record("expected .font, got \(value)"); return }
        #expect(font.version == 0xDBC0_1002)
        #expect(font.emSize == 14)
        #expect(font.sizeUnit == 2)
        #expect(font.styleFlags == 0x3)
        #expect(font.familyName == name)
        #expect(font.isBold == true)
        #expect(font.isItalic == true)
        #expect(font.isUnderline == false)
        #expect(font.isStrikeout == false)
    }

    @Test("font family name with a lone surrogate → U+FFFD, decode does not fail")
    func fontLoneSurrogate() throws {
        // 'A', a lone high surrogate, 'B' → the surrogate becomes U+FFFD. 3 units
        // = 6 name bytes; 2 trailing pad bytes keep the record 4-aligned.
        let value = try decodeObject(objectType: 6, objectBytes: fontBytes(
            nameUnits: [0x0041, 0xD800, 0x0042], trailing: [0, 0]))
        guard case .font(let font) = value else { Issue.record("expected .font, got \(value)"); return }
        #expect(font.familyName == "A\u{FFFD}B")
    }

    @Test("lying font Length → typed failure before allocation")
    func fontLyingLength() throws {
        // Claims 1000 characters but supplies only 4 name bytes.
        let value = try decodeObject(objectType: 6, objectBytes: fontBytes(
            nameUnits: [0x0041, 0x0042], lengthOverride: 1000))
        guard case .malformed(.font, .arrayCountExceedsBuffer(let field, let count, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusFont.FamilyName")
        #expect(count == 1000)
    }
}

// MARK: - StringFormat

@Suite("EMF+ string format decode")
struct EMFPlusStringFormatDecodeTests {

    @Test("string format round-trip: scalars + tab stops + character ranges")
    func stringFormatRoundTrip() throws {
        let value = try decodeObject(objectType: 7, objectBytes: stringFormatBytes(
            tabStops: [1.0, 2.5], ranges: [(0, 5), (10, 3)]))
        guard case .stringFormat(let format) = value else { Issue.record("expected .stringFormat, got \(value)"); return }
        #expect(format.version == 0xDBC0_1002)
        #expect(format.stringFormatFlags == 0x1)
        #expect(format.language == 0x0409)
        #expect(format.stringAlignment == 1)
        #expect(format.lineAlign == 2)
        #expect(format.hotkeyPrefix == 3)
        #expect(format.tracking == 1.25)
        #expect(format.tabStops == [1.0, 2.5])
        #expect(format.characterRanges == [
            EMFPlusCharacterRange(first: 0, length: 5),
            EMFPlusCharacterRange(first: 10, length: 3),
        ])
    }

    @Test("negative TabStopCount → typed failure")
    func negativeTabStopCount() throws {
        let value = try decodeObject(objectType: 7, objectBytes: stringFormatBytes(tabStopCountOverride: -1))
        guard case .malformed(.stringFormat, .arrayCountExceedsBuffer(let field, _, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusStringFormatData.TabStopCount")
    }

    @Test("negative RangeCount → typed failure")
    func negativeRangeCount() throws {
        let value = try decodeObject(objectType: 7, objectBytes: stringFormatBytes(rangeCountOverride: -2))
        guard case .malformed(.stringFormat, .arrayCountExceedsBuffer(let field, _, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusStringFormatData.CharRange")
    }

    @Test("lying TabStopCount → typed failure before allocation")
    func lyingTabStopCount() throws {
        let value = try decodeObject(objectType: 7, objectBytes: stringFormatBytes(tabStopCountOverride: 1000))
        guard case .malformed(.stringFormat, .arrayCountExceedsBuffer(let field, let count, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusStringFormatData.TabStops")
        #expect(count == 1000)
    }
}

// MARK: - Image shell + ImageAttributes

@Suite("EMF+ image shell decode")
struct EMFPlusImageDecodeTests {

    @Test("bitmap image shell → header fields + raw payload byte-exact")
    func bitmapShell() throws {
        let raw: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(1)               // Type = ImageDataTypeBitmap
        b.appendInt32(4)                // Width
        b.appendInt32(-4)               // Height (negative is legal on the wire)
        b.appendInt32(16)               // Stride
        b.appendUInt32(0x0026_200A)     // PixelFormat (32bppARGB)
        b.appendUInt32(0)               // Type = BitmapDataTypePixel
        b.appendBytes(raw)
        let value = try decodeObject(objectType: 5, objectBytes: b.bytes)
        guard case .image(let image) = value, case .bitmap(let header, let data) = image.content else {
            Issue.record("expected bitmap image, got \(value)"); return
        }
        #expect(image.version == 0xDBC0_1002)
        #expect(header == EMFPlusImageBitmapHeader(
            width: 4, height: -4, stride: 16, pixelFormat: 0x0026_200A, bitmapDataType: 0))
        #expect(Array(data) == raw)
    }

    @Test("metafile image shell → header fields + raw payload byte-exact")
    func metafileShell() throws {
        let raw: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(2)               // Type = ImageDataTypeMetafile
        b.appendUInt32(3)               // MetafileType
        b.appendUInt32(8)               // MetafileDataSize
        b.appendBytes(raw)
        let value = try decodeObject(objectType: 5, objectBytes: b.bytes)
        guard case .image(let image) = value, case .metafile(let header, let data) = image.content else {
            Issue.record("expected metafile image, got \(value)"); return
        }
        #expect(header == EMFPlusImageMetafileHeader(metafileType: 3, metafileDataSize: 8))
        #expect(Array(data) == raw)
    }

    @Test("unknown image type → typed failure")
    func unknownImageType() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(99)              // Type — not bitmap or metafile
        let value = try decodeObject(objectType: 5, objectBytes: b.bytes)
        #expect(value == .malformed(type: .image, reason: .unknownImageType(raw: 99)))
    }

    @Test("image attributes round-trip")
    func imageAttributes() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(0)               // Reserved1
        b.appendUInt32(3)               // WrapMode
        b.appendBytes([0x11, 0x22, 0x33, 0xFF])   // ClampColor B,G,R,A
        b.appendInt32(1)                // ObjectClamp
        b.appendUInt32(0)               // Reserved2
        let value = try decodeObject(objectType: 8, objectBytes: b.bytes)
        guard case .imageAttributes(let attributes) = value else {
            Issue.record("expected .imageAttributes, got \(value)"); return
        }
        #expect(attributes.version == 0xDBC0_1002)
        #expect(attributes.wrapMode == 3)
        #expect(attributes.clampColor == argb(0x11, 0x22, 0x33, 0xFF))
        #expect(attributes.objectClamp == 1)
    }
}

// MARK: - Corpus negative pin

@Suite("EMF+ object corpus pins")
struct EMFPlusObjectCorpusTests {

    /// gate-p2-star.emf is a non-drawing EMF+ shell: it carries no EmfPlusObject
    /// records, so the object layer yields zero definitions and zero diagnostics.
    @Test("gate-p2-star.emf yields zero object definitions")
    func gateStarHasNoObjects() throws {
        let objects = try EMFFile.parse(try requireCorpus("gate-p2-star.emf"))
            .emfPlusStream().objectDefinitions()
        #expect(objects.definitions.isEmpty)
        #expect(objects.diagnostics.isEmpty)
    }
}
