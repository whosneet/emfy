import Foundation
import Testing
@testable import WMFParse

@Suite("WMF header decode and header-level failures")
struct WMFHeaderTests {

    // A clean minimal standard WMF: META_HEADER + META_EOF. SizeLow 12 WORDs
    // (24 bytes) and MaxRecord 3 WORDs match the walk, so no advisory mismatch.
    private func cleanStandard() -> Data {
        WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(
                type: 0x0002, sizeLow: 12, maxRecord: 3
            ),
            records: [WMFFixtureBuilder.eof()]
        )
    }

    // A clean minimal placeable WMF: placeable + META_HEADER + META_EOF.
    private func cleanPlaceable() -> Data {
        WMFFixtureBuilder.file(
            placeable: WMFFixtureBuilder.placeable(
                boundingBox: (0, 0, 640, 480), inch: 1440
            ),
            header: WMFFixtureBuilder.metaHeader(
                type: 0x0001, sizeLow: 12, maxRecord: 3
            ),
            records: [WMFFixtureBuilder.eof()]
        )
    }

    @Test("standard META_HEADER decodes; no placeable; clean walk")
    func standardHeader() throws {
        let file = try WMFFile.parse(cleanStandard())

        #expect(file.placeable == nil)
        #expect(file.header.type == 0x0002)
        #expect(file.header.headerSizeWords == 0x0009)
        #expect(file.header.version == 0x0300)
        #expect(file.header.metafileSizeWords == 12)
        #expect(file.header.maxRecord == 3)
        #expect(file.header.numberOfObjects == 0)
        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 1)
        #expect(file.records[0].function == 0x0000)
        #expect(file.records[0].offset == 18)
        #expect(file.headerByteCount == 18)
        #expect(file.bytesWalked == 24)
    }

    @Test("placeable header decodes: bounding box, inch, checksum OK")
    func placeableHeader() throws {
        let file = try WMFFile.parse(cleanPlaceable())

        let placeable = try #require(file.placeable)
        #expect(placeable.boundingBox == WMFRect16(left: 0, top: 0, right: 640, bottom: 480))
        #expect(placeable.inch == 1440)
        #expect(placeable.checksumOK)
        #expect(placeable.checksumStored == placeable.checksumComputed)
        #expect(file.diagnostics.isEmpty)
        // META_EOF sits after the 22-byte placeable + 18-byte META_HEADER.
        #expect(file.records.count == 1)
        #expect(file.records[0].offset == 40)
        #expect(file.headerByteCount == 40)
        #expect(file.bytesWalked == 46)
    }

    @Test("placeable checksum mismatch is a diagnostic, never a failure")
    func placeableChecksumMismatch() throws {
        let data = WMFFixtureBuilder.file(
            placeable: WMFFixtureBuilder.placeable(checksumOverride: 0xDEAD),
            header: WMFFixtureBuilder.metaHeader(type: 0x0001, sizeLow: 12, maxRecord: 3),
            records: [WMFFixtureBuilder.eof()]
        )
        let file = try WMFFile.parse(data)

        let placeable = try #require(file.placeable)
        #expect(!placeable.checksumOK)
        #expect(placeable.checksumStored == 0xDEAD)
        #expect(file.diagnostics.contains(
            .placeableChecksumMismatch(stored: 0xDEAD, computed: placeable.checksumComputed)
        ))
        // The file still parses: the record walk is unaffected.
        #expect(file.records.count == 1)
        #expect(file.records[0].function == 0x0000)
    }

    @Test("fewer than 18 bytes throws tooShort")
    func tooShort() {
        let data = Data([0x01, 0x00, 0x09, 0x00, 0x00, 0x03, 0x00, 0x00])  // 8 bytes
        #expect(throws: WMFParseError.tooShort(count: 8)) {
            try WMFFile.parse(data)
        }
    }

    @Test("placeable key present but too short for key+header throws tooShort")
    func placeableKeyTooShort() {
        // 22-byte placeable header alone, no room for the META_HEADER after it.
        let data = Data(WMFFixtureBuilder.placeable())
        #expect(throws: WMFParseError.self) {
            try WMFFile.parse(data)
        }
        // Specifically tooShort (only 22 of the needed 40 bytes).
        do {
            _ = try WMFFile.parse(data)
            Issue.record("expected a throw")
        } catch {
            #expect(error == .tooShort(count: 22))
        }
    }

    @Test("implausible META_HEADER throws implausibleHeader", arguments: [
        // (type, headerSize, version)
        (UInt16(0x0003), UInt16(0x0009), UInt16(0x0300)),  // bad Type
        (UInt16(0x0001), UInt16(0x0008), UInt16(0x0300)),  // bad HeaderSize
        (UInt16(0x0001), UInt16(0x0009), UInt16(0x0200)),  // bad Version
    ])
    func implausibleHeader(_ fields: (type: UInt16, headerSize: UInt16, version: UInt16)) {
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(
                type: fields.type, headerSize: fields.headerSize, version: fields.version,
                sizeLow: 12, maxRecord: 3
            ),
            records: [WMFFixtureBuilder.eof()]
        )
        #expect(throws: WMFParseError.implausibleHeader(
            type: fields.type, headerSize: fields.headerSize, version: fields.version
        )) {
            try WMFFile.parse(data)
        }
    }

    @Test("placeable key with an implausible following header throws implausibleHeader")
    func placeableKeyImplausibleHeader() {
        let data = WMFFixtureBuilder.file(
            placeable: WMFFixtureBuilder.placeable(),
            header: WMFFixtureBuilder.metaHeader(
                type: 0x0099, sizeLow: 12, maxRecord: 3   // implausible Type
            ),
            records: [WMFFixtureBuilder.eof()]
        )
        #expect(throws: WMFParseError.self) {
            try WMFFile.parse(data)
        }
        do {
            _ = try WMFFile.parse(data)
            Issue.record("expected a throw")
        } catch {
            #expect(error == .implausibleHeader(type: 0x0099, headerSize: 0x0009, version: 0x0300))
        }
    }

    @Test("payload(of:) slices the rdParam bytes after the 6-byte record header")
    func payloadSlice() throws {
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 17, maxRecord: 5),
            records: [
                // 5 WORDs = 10 bytes: 6-byte header + 4-byte payload.
                WMFFixtureBuilder.record(function: 0x0213, payload: payload),  // META_LINETO
                WMFFixtureBuilder.eof(),
            ]
        )
        let file = try WMFFile.parse(data)
        #expect(file.diagnostics.isEmpty)
        let lineTo = file.records[0]
        #expect(lineTo.function == 0x0213)
        #expect(lineTo.byteSize == 10)
        #expect(lineTo.payloadByteCount == 4)
        #expect(Array(file.payload(of: lineTo)) == payload)
    }
}
