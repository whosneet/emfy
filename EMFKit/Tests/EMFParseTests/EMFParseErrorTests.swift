import Foundation
import Testing
@testable import EMFParse

@Suite("EMFFile.parse header validation errors")
struct EMFParseErrorTests {

    @Test("empty data throws tooShort")
    func emptyData() {
        #expect(throws: EMFParseError.self) {
            try EMFFile.parse(Data())
        }
    }

    @Test("short data (below 96 bytes) throws tooShort")
    func shortData() {
        // 95 bytes: below the 88 + 8 minimum.
        let data = Data(repeating: 0, count: 95)
        #expect {
            try EMFFile.parse(data)
        } throws: { error in
            error as? EMFParseError == .tooShort(count: 95)
        }
    }

    @Test("first record type != 1 throws notHeaderRecord")
    func wrongFirstRecordType() {
        // Build a valid-length buffer but set iType to 2 (POLYBEZIER).
        var header = FixtureBuilder.header(fixedSize: 108, recordsField: 2)
        // Overwrite the first 4 bytes (iType) with 2, little-endian.
        header[0] = 2
        header[1] = 0
        header[2] = 0
        header[3] = 0
        var fixture = FixtureBuilder()
        fixture.appendBytes(header)
        fixture.appendBytes(FixtureBuilder.eof())

        #expect {
            try EMFFile.parse(fixture.data)
        } throws: { error in
            error as? EMFParseError == .notHeaderRecord(type: 2)
        }
    }

    @Test("wrong RecordSignature throws badSignature")
    func wrongSignature() {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordsField: 2, signature: 0xDEAD_BEEF)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        #expect {
            try EMFFile.parse(fixture.data)
        } throws: { error in
            error as? EMFParseError == .badSignature(found: 0xDEAD_BEEF)
        }
    }

    @Test("header nSize below 88 throws invalidHeaderSize")
    func headerSizeTooSmall() {
        // Enough bytes overall, but nSize claims 80 (< 88).
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordSize: 80, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        #expect {
            try EMFFile.parse(fixture.data)
        } throws: { error in
            error as? EMFParseError == .invalidHeaderSize(size: 80)
        }
    }

    @Test("header nSize not a multiple of 4 throws invalidHeaderSize")
    func headerSizeNotAligned() {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordSize: 110, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        #expect {
            try EMFFile.parse(fixture.data)
        } throws: { error in
            error as? EMFParseError == .invalidHeaderSize(size: 110)
        }
    }

    @Test("header nSize beyond file throws invalidHeaderSize")
    func headerSizeBeyondFile() {
        // nSize claims 10000 but the file is far smaller.
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordSize: 10000, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof())

        #expect {
            try EMFFile.parse(fixture.data)
        } throws: { error in
            error as? EMFParseError == .invalidHeaderSize(size: 10000)
        }
    }
}
