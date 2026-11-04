import Foundation
import Testing
@testable import WMFParse

@Suite("WMF record walker and diagnostics")
struct WMFWalkerTests {

    /// Standard header + SAVEDC + SETWINDOWORG + POLYGON + EOF. Counts and
    /// offsets are asserted against the exact byte layout.
    @Test("multi-record walk: counts and offsets")
    func multiRecordWalk() throws {
        // After the 18-byte header: SAVEDC(3w/6B)@18, SETWINDOWORG(5w/10B)@24,
        // POLYGON(8w/16B)@34, EOF(3w/6B)@50. Total 56 bytes = 28 WORDs.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 28, maxRecord: 8),
            records: [
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),
                WMFFixtureBuilder.record(function: 0x020B, sizeWords: 5),
                WMFFixtureBuilder.record(function: 0x0324, sizeWords: 8),
                WMFFixtureBuilder.eof(),
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 4)
        #expect(file.bytesWalked == 56)
        #expect(file.headerByteCount == 18)

        #expect(file.records[0].function == 0x001E)
        #expect(file.records[0].offset == 18)
        #expect(file.records[0].byteSize == 6)
        #expect(file.records[1].function == 0x020B)
        #expect(file.records[1].offset == 24)
        #expect(file.records[2].function == 0x0324)
        #expect(file.records[2].offset == 34)
        #expect(file.records[2].byteSize == 16)
        #expect(file.records[3].function == 0x0000)
        #expect(file.records[3].offset == 50)
    }

    /// RecordSize below the 3-WORD minimum (0, 1, 2): recordSizeTooSmall, walk
    /// stops, the earlier good record is kept.
    @Test("RecordSize < 3 WORDs: recordSizeTooSmall, earlier record kept",
          arguments: [UInt32(0), 1, 2])
    func recordSizeTooSmall(_ sizeWords: UInt32) throws {
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002),
            records: [
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),            // good @18
                WMFFixtureBuilder.record(function: 0x0324, payload: [],              // bad  @24
                                         sizeWordsOverride: sizeWords),
                WMFFixtureBuilder.eof(),                                             // bytes beyond
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.records.count == 1)
        #expect(file.records[0].function == 0x001E)
        #expect(file.diagnostics.contains(.recordSizeTooSmall(offset: 24, sizeWords: sizeWords)))
        #expect(file.bytesWalked == 24)
    }

    /// A record whose RecordSize runs past the end of the buffer:
    /// recordSizeExceedsRemaining, walk stops, earlier records kept.
    @Test("lying RecordSize past end: recordSizeExceedsRemaining, earlier record kept")
    func recordSizeExceedsRemaining() throws {
        // good SAVEDC@18, then a 6-byte header claiming 4096 WORDs@24 (no backing).
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002),
            records: [
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),
                WMFFixtureBuilder.record(function: 0x0324, payload: [], sizeWordsOverride: 4096),
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.records.count == 1)
        #expect(file.records[0].function == 0x001E)
        let remaining = data.count - 24
        #expect(file.diagnostics.contains(
            .recordSizeExceedsRemaining(offset: 24, byteSize: 8192, remaining: remaining)
        ))
        #expect(file.bytesWalked == 24)
    }

    /// Overflow-sized RecordSize (0xFFFFFFFF). `RecordSize * 2` is
    /// overflow-checked and still rejected as exceeding the buffer; no trap.
    @Test("overflow-sized RecordSize: recordSizeExceedsRemaining, no trap")
    func overflowSizedRecord() throws {
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002),
            records: [
                WMFFixtureBuilder.record(function: 0x0324, payload: [], sizeWordsOverride: 0xFFFF_FFFF),
                WMFFixtureBuilder.eof(),
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.records.isEmpty)
        let remaining = data.count - 18
        #expect(file.diagnostics.contains(
            .recordSizeExceedsRemaining(offset: 18, byteSize: Int(UInt32.max) * 2, remaining: remaining)
        ))
        #expect(file.bytesWalked == 18)
    }

    /// Fewer than 6 bytes remain where a record header is expected:
    /// truncatedRecordHeader, walk stops.
    @Test("truncated record header: truncatedRecordHeader, walk stops")
    func truncatedRecordHeader() throws {
        var builder = WMFFixtureBuilder()
        builder.appendBytes(WMFFixtureBuilder.metaHeader(type: 0x0002))
        builder.appendBytes(WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3))  // good @18
        builder.appendZeros(3)                                                         // 3 stray @24
        let file = try WMFFile.parse(builder.data)

        #expect(file.records.count == 1)
        #expect(file.diagnostics.contains(.truncatedRecordHeader(offset: 24, remaining: 3)))
        #expect(file.bytesWalked == 24)
    }

    /// No META_EOF before the end of the buffer: missingEOF.
    @Test("missing META_EOF: missingEOF diagnostic")
    func missingEOF() throws {
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 12, maxRecord: 3),
            records: [WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3)]  // no EOF
        )
        let file = try WMFFile.parse(data)

        #expect(file.records.count == 1)
        #expect(file.records.last?.function != 0x0000)
        #expect(file.diagnostics.contains(.missingEOF))
        #expect(file.bytesWalked == 24)
    }

    /// Bytes after META_EOF: trailingBytesAfterEOF, walk stops at the EOF end.
    @Test("trailing bytes after META_EOF: trailingBytesAfterEOF(count)")
    func trailingBytesAfterEOF() throws {
        var builder = WMFFixtureBuilder()
        builder.appendBytes(WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 12, maxRecord: 3))
        builder.appendBytes(WMFFixtureBuilder.eof())
        builder.appendZeros(10)   // 10 stray trailing bytes
        let file = try WMFFile.parse(builder.data)

        #expect(file.records.count == 1)
        #expect(file.records.last?.function == 0x0000)
        #expect(file.diagnostics.contains(.trailingBytesAfterEOF(count: 10)))
        #expect(file.bytesWalked == 24)   // walk stops at the EOF end
    }

    /// An unknown RecordFunction is kept as an unknown record, never a failure.
    @Test("unknown RecordFunction is kept, not a failure")
    func unknownFunctionKept() throws {
        // Metafile = header 9w + record 4w + EOF 3w = 16 WORDs.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 16, maxRecord: 4),
            records: [
                WMFFixtureBuilder.record(function: 0xABCD, sizeWords: 4),  // undefined function
                WMFFixtureBuilder.eof(),
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 2)
        #expect(file.records[0].function == 0xABCD)
        #expect(WMFRecordType.name(for: 0xABCD) == nil)
    }

    /// §8 memory guard: a file of `cap + 1000` minimal 6-byte records is walked
    /// only up to the cap, then stopped with everything kept. `records.count`
    /// lands on the cap, `recordCountCapped` is present, and no `missingEOF`
    /// coexists (the walk was cut short deliberately).
    @Test("record-count cap: all-tiny-records file stops at the cap")
    func recordCountCap() throws {
        let cap = WMFFile.recordCountLimit
        // cap + 1000 minimal SAVEDC records (3 WORDs / 6 bytes), no EOF.
        let template: [UInt8] = [0x03, 0, 0, 0, 0x1E, 0x00]   // RecordSize 3, META_SAVEDC
        let nonHeaderRecords = cap + 1000

        var bytes = WMFFixtureBuilder.metaHeader(type: 0x0002)
        bytes.reserveCapacity(bytes.count + nonHeaderRecords * 6)
        for _ in 0 ..< nonHeaderRecords {
            bytes.append(contentsOf: template)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let file = try WMFFile.parse(Data(bytes))
        let elapsed = clock.now - start

        #expect(file.records.count == cap)
        #expect(file.diagnostics.contains(.recordCountCapped(limit: cap)))
        #expect(!file.diagnostics.contains(.missingEOF))
        // Header (18) + cap records of 6 bytes each.
        #expect(file.bytesWalked == 18 + cap * 6)
        #expect(elapsed < .seconds(5), "1M-record walk took \(elapsed)")
    }

    /// Advisory SizeLow/SizeHigh disagreeing with the walk → metafileSizeMismatch
    /// (never affects the record list).
    @Test("SizeLow/SizeHigh mismatch: metafileSizeMismatch")
    func metafileSizeMismatch() throws {
        // Clean walk of 24 metafile bytes, but the header claims 999 WORDs.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 999, maxRecord: 3),
            records: [WMFFixtureBuilder.eof()]
        )
        let file = try WMFFile.parse(data)

        #expect(file.records.count == 1)
        #expect(file.diagnostics.contains(.metafileSizeMismatch(headerSays: 999 * 2, walked: 24)))
    }

    /// Advisory MaxRecord disagreeing with the largest walked record →
    /// maxRecordMismatch.
    @Test("MaxRecord mismatch: maxRecordMismatch")
    func maxRecordMismatch() throws {
        // Largest record is the 5-WORD SETWINDOWORG; header claims 42 WORDs.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 17, maxRecord: 42),
            records: [
                WMFFixtureBuilder.record(function: 0x020B, sizeWords: 5),
                WMFFixtureBuilder.eof(),
            ]
        )
        let file = try WMFFile.parse(data)

        #expect(file.diagnostics.contains(.maxRecordMismatch(headerSays: 42, walked: 5)))
    }

    /// recordInventory aggregates per function (count + total bytes, 6-byte
    /// headers included) sorted by function value ascending, regardless of order.
    @Test("recordInventory: per-function aggregation sorted by value")
    func recordInventoryAggregation() throws {
        // Metafile = header 9w + (3+3+5+3)w records + EOF 3w = 26 WORDs.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(type: 0x0002, sizeLow: 26, maxRecord: 5),
            records: [
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),   // SAVEDC 6B
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),   // SAVEDC 6B
                WMFFixtureBuilder.record(function: 0x020B, sizeWords: 5),   // SETWINDOWORG 10B
                WMFFixtureBuilder.record(function: 0x001E, sizeWords: 3),   // SAVEDC 6B
                WMFFixtureBuilder.eof(),                                    // EOF 6B
            ]
        )
        let file = try WMFFile.parse(data)
        #expect(file.diagnostics.isEmpty)

        let inventory = file.recordInventory()
        #expect(inventory.count == 3)
        #expect(inventory[0] == (function: 0x0000, count: 1, totalBytes: 6))
        #expect(inventory[1] == (function: 0x001E, count: 3, totalBytes: 18))
        #expect(inventory[2] == (function: 0x020B, count: 1, totalBytes: 10))
    }

    @Test("record-name lookup: known, prefixed, and unknown values")
    func recordNameLookup() {
        #expect(WMFRecordType.name(for: 0x0000) == "META_EOF")
        #expect(WMFRecordType.name(for: 0x001E) == "META_SAVEDC")
        #expect(WMFRecordType.name(for: 0x0F43) == "META_STRETCHDIB")
        #expect(WMFRecordType.name(for: 0x06FF) == "META_CREATEREGION")
        #expect(WMFRecordType.name(for: 0xABCD) == nil)
        #expect(WMFRecordType.name(for: 0x0001) == nil)   // a Type value, not a RecordFunction
    }
}
