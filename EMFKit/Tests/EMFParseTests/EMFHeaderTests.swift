import Foundation
import Testing
@testable import EMFParse

@Suite("EMFHeader decode")
struct EMFHeaderTests {

    /// Golden file: a 108-byte extension2 header followed by one EMR_EOF.
    /// Every header field is asserted; the file has exactly 2 records and no
    /// diagnostics. `Bytes`/`Records` are set to match the walk so the
    /// advisory cross-checks stay silent.
    @Test("golden extension2 file: all fields, 2 records, no diagnostics")
    func goldenExtension2() throws {
        let headerBytes = FixtureBuilder.header(
            fixedSize: 108,
            bounds: (10, 20, 110, 220),
            frame: (0, 0, 21000, 29700),
            version: 0x0001_0000,
            bytesField: 128,          // 108 header + 20 EOF
            recordsField: 2,
            handles: 3,
            nPalEntries: 0,
            device: (1920, 1080),
            millimeters: (508, 285)
        )
        var fixture = FixtureBuilder()
        fixture.appendBytes(headerBytes)
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 2)
        #expect(file.bytesWalked == 128)

        let h = file.header
        #expect(h.variant == .extension2)
        #expect(h.bounds == RectL(left: 10, top: 20, right: 110, bottom: 220))
        #expect(h.frame == RectL(left: 0, top: 0, right: 21000, bottom: 29700))
        #expect(h.recordSignature == 0x464D_4520)
        #expect(h.version == 0x0001_0000)
        #expect(h.bytes == 128)
        #expect(h.records == 2)
        #expect(h.handles == 3)
        #expect(h.nDescription == 0)
        #expect(h.offDescription == 0)
        #expect(h.nPalEntries == 0)
        #expect(h.device == SizeL(cx: 1920, cy: 1080))
        #expect(h.millimeters == SizeL(cx: 508, cy: 285))
        #expect(h.extension1 != nil)
        #expect(h.extension2 != nil)
        #expect(h.description == nil)

        // Header record is records[0], EOF is records[1].
        #expect(file.records[0].type == 1)
        #expect(file.records[0].size == 108)
        #expect(file.records[0].offset == 0)
        #expect(file.records[1].type == 14)
        #expect(file.records[1].offset == 108)
    }

    @Test("base variant: 88-byte header, no extensions")
    func baseVariant() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 88, bytesField: 108, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.header.variant == .base)
        #expect(file.header.extension1 == nil)
        #expect(file.header.extension2 == nil)
        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 2)
    }

    @Test("extension1 variant: 100-byte header, ext1 only")
    func extension1Variant() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 100, bytesField: 120, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.header.variant == .extension1)
        #expect(file.header.extension1 != nil)
        #expect(file.header.extension2 == nil)
        #expect(file.diagnostics.isEmpty)
    }

    /// Description string (UTF-16LE) placed immediately after the 108-byte
    /// fixed part. nDescription counts UTF-16 code units, offDescription = 108.
    @Test("description decode: UTF-16LE after fixed part")
    func descriptionDecode() throws {
        let text = "Test App\u{0}Doc\u{0}"
        let charCount = text.utf16.count            // code units incl. NULs
        let descByteLen = charCount * 2             // 26 bytes here
        // Real header records are 4-aligned; round the record out past the
        // description and pad. The decoder reads exactly nDescription units
        // from offDescription, so the padding is invisible to decode.
        let rawEnd = 108 + descByteLen
        let padding = (4 - rawEnd % 4) % 4
        let recordSize = UInt32(rawEnd + padding)

        var header = FixtureBuilder()
        header.appendBytes(
            FixtureBuilder.header(
                fixedSize: 108,
                recordSize: recordSize,
                bytesField: recordSize + 20,
                recordsField: 2,
                nDescription: UInt32(charCount),
                offDescription: 108
            )
        )
        header.appendUTF16LE(text)                  // description payload at 108
        header.appendZeros(padding)                 // 4-align the record

        var fixture = FixtureBuilder()
        fixture.appendBytes(header.bytes)
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        // offDescription (108) == recordSize? No — description sits inside the
        // record, so the fixed part stays 108 → extension2.
        #expect(file.header.variant == .extension2)
        #expect(file.header.nDescription == UInt32(charCount))
        #expect(file.header.offDescription == 108)
        #expect(file.header.description == text)
        #expect(file.diagnostics.isEmpty)
    }

    /// HeaderSize capping: nSize is 108 but a description starts at offset 88
    /// (offDescription = 88, below 108). The algorithm caps the fixed part at
    /// 88 → base variant, no extensions. ([MS-EMF] §2.3.4.2.)
    @Test("HeaderSize capping: offDescription below 108 forces base variant")
    func headerSizeCapping() throws {
        let text = "D\u{0}"                          // 2 code units, 4 bytes
        let charCount = text.utf16.count
        // Record: 88 fixed + 4-byte description at offset 88; recordSize 108
        // would leave room, but offDescription=88 caps the fixed part.
        // Lay bytes out so the record is exactly 88 + 4 = 92, padded to 108
        // via recordSize so nSize=108 while offDescription=88.
        var header = FixtureBuilder()
        header.appendBytes(
            FixtureBuilder.header(
                fixedSize: 88,
                recordSize: 108,
                bytesField: 128,
                recordsField: 2,
                nDescription: UInt32(charCount),
                offDescription: 88
            )
        )
        header.appendUTF16LE(text)                  // 4 bytes at offset 88..92
        header.appendZeros(108 - 92)                // pad record out to nSize

        var fixture = FixtureBuilder()
        fixture.appendBytes(header.bytes)
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.header.variant == .base)
        #expect(file.header.extension1 == nil)
        #expect(file.header.extension2 == nil)
        #expect(file.header.description == text)
        #expect(file.diagnostics.isEmpty)
    }

    @Test("HeaderSize algorithm unit cases")
    func headerSizeAlgorithm() {
        // No optional fields: size stays at recordSize.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 0, offDescription: 0, cbPixelFormat: 0, offPixelFormat: 0) == 108)
        // Description present but at/after recordSize: no cap.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 4, offDescription: 108, cbPixelFormat: 0, offPixelFormat: 0) == 108)
        // Description starts below recordSize: cap at offDescription.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 4, offDescription: 88, cbPixelFormat: 0, offPixelFormat: 0) == 88)
        // offDescription set but nDescription 0: no cap (both required).
        #expect(EMFFile.headerSize(recordSize: 100, nDescription: 0, offDescription: 88, cbPixelFormat: 0, offPixelFormat: 0) == 100)
        // Pixel format starts below the running size: cap at offPixelFormat.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 0, offDescription: 0, cbPixelFormat: 8, offPixelFormat: 100) == 100)
        // Pixel format at/after the running size: no cap.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 0, offDescription: 0, cbPixelFormat: 8, offPixelFormat: 108) == 108)
        // cbPixelFormat 0: no cap (both required).
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 0, offDescription: 0, cbPixelFormat: 0, offPixelFormat: 100) == 108)
        // Description already capped below 100: the Extension1 fields are not
        // part of the fixed part, so pixel-format values are ignored.
        #expect(EMFFile.headerSize(recordSize: 108, nDescription: 4, offDescription: 88, cbPixelFormat: 8, offPixelFormat: 100) == 88)
    }

    /// Legacy-OpenGL shape: nSize 108 but a pixel-format field at offset 100.
    /// The HeaderSize algorithm caps the fixed part at offPixelFormat →
    /// extension1; the bytes at 100..108 are pixel-format payload, NOT
    /// micrometers ([MS-EMF] §2.3.4.2).
    @Test("pixel-format cap: offPixelFormat=100 forces extension1")
    func pixelFormatCapping() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(
                fixedSize: 108,
                bytesField: 128,
                recordsField: 2,
                cbPixelFormat: 8,
                offPixelFormat: 100,
                bOpenGL: 1,
                micrometers: (0x1111_1111, 0x2222_2222)  // pixel-format bytes
            )
        )
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.header.variant == .extension1)
        #expect(file.header.extension1 == EMFHeaderExtension1(
            cbPixelFormat: 8, offPixelFormat: 100, bOpenGL: 1
        ))
        #expect(file.header.extension2 == nil)
        #expect(file.diagnostics.isEmpty)
    }

    /// Control for the pixel-format cap: identical bytes but cbPixelFormat 0,
    /// so no cap applies and the same 100..108 bytes decode as micrometers.
    @Test("pixel-format control: cbPixelFormat=0 keeps extension2")
    func pixelFormatControl() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(
                fixedSize: 108,
                bytesField: 128,
                recordsField: 2,
                cbPixelFormat: 0,
                offPixelFormat: 100,
                bOpenGL: 0,
                micrometers: (0x1111_1111, 0x2222_2222)
            )
        )
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)

        #expect(file.header.variant == .extension2)
        #expect(file.header.extension1 == EMFHeaderExtension1(
            cbPixelFormat: 0, offPixelFormat: 100, bOpenGL: 0
        ))
        #expect(file.header.extension2 == EMFHeaderExtension2(
            micrometersX: 0x1111_1111, micrometersY: 0x2222_2222
        ))
        #expect(file.diagnostics.isEmpty)
    }
}
