import Foundation
import Testing
@testable import EMFParse

@Suite("Record walker and diagnostics")
struct EMFWalkerTests {

    /// Header + several records of varied types/sizes + EOF. Counts and
    /// offsets are asserted against the exact byte layout.
    @Test("multi-record walk: counts and offsets")
    func multiRecordWalk() throws {
        // Records after header: SAVEDC(33, 8), SETMAPMODE(17, 12),
        // RECTANGLE(43, 24), then EOF(20).
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 172, recordsField: 5)
        )
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        fixture.appendBytes(FixtureBuilder.record(type: 17, size: 12))
        fixture.appendBytes(FixtureBuilder.record(type: 43, size: 24))
        fixture.appendBytes(FixtureBuilder.eof(size: 20))

        let file = try EMFFile.parse(fixture.data)

        #expect(file.diagnostics.isEmpty)
        #expect(file.records.count == 5)
        #expect(file.bytesWalked == 172)   // 108 + 8 + 12 + 24 + 20

        #expect(file.records[0].type == 1)
        #expect(file.records[0].offset == 0)
        #expect(file.records[1].type == 33)
        #expect(file.records[1].offset == 108)
        #expect(file.records[1].size == 8)
        #expect(file.records[2].type == 17)
        #expect(file.records[2].offset == 116)  // 108 + 8
        #expect(file.records[3].type == 43)
        #expect(file.records[3].offset == 128)  // 116 + 12
        #expect(file.records[4].type == 14)
        #expect(file.records[4].offset == 152)  // 128 + 24
        #expect(file.records[4].payloadOffset == 160)
    }

    /// Lying nSize: a record whose nSize runs past the end of data →
    /// sizeExceedsRemaining, walk stops, earlier records preserved.
    @Test("lying nSize past end: sizeExceedsRemaining, earlier records kept")
    func lyingSizeExceedsRemaining() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordsField: 4)
        )
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        // Append only an 8-byte record header claiming nSize = 4096, with no
        // payload bytes to back it — the walker must reject it on bounds.
        fixture.appendUInt32(43)
        fixture.appendUInt32(4096)

        let file = try EMFFile.parse(fixture.data)

        // Header + SAVEDC preserved; the lying record is not admitted.
        #expect(file.records.count == 2)
        #expect(file.records[0].type == 1)
        #expect(file.records[1].type == 33)

        let badRecordOffset = 116
        let remaining = fixture.count - badRecordOffset
        #expect(file.diagnostics.contains(
            .sizeExceedsRemaining(offset: badRecordOffset, size: 4096, remaining: remaining)
        ))
        #expect(file.bytesWalked == badRecordOffset)
    }

    @Test("nSize < 8: sizeTooSmall, walk stops")
    func sizeTooSmall() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordsField: 3)
        )
        // A record header claiming size 4 (below the 8-byte minimum).
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 4))
        // Give the buffer more bytes so "too small" is the reason, not "past end".
        fixture.appendBytes(FixtureBuilder.eof(size: 20))

        let file = try EMFFile.parse(fixture.data)

        #expect(file.records.count == 1)          // only the header
        #expect(file.diagnostics.contains(.sizeTooSmall(offset: 108, size: 4)))
        #expect(file.bytesWalked == 108)
    }

    @Test("nSize not a multiple of 4: sizeNotAligned, walk stops")
    func sizeNotAligned() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, recordsField: 3)
        )
        // Record header claiming size 10 (>= 8 but not 4-aligned). Add padding
        // bytes so the buffer is long enough that alignment is the failure.
        var rec = FixtureBuilder()
        rec.appendUInt32(33)
        rec.appendUInt32(10)
        rec.appendZeros(12)                        // extra bytes in the buffer
        fixture.appendBytes(rec.bytes)

        let file = try EMFFile.parse(fixture.data)

        #expect(file.records.count == 1)
        #expect(file.diagnostics.contains(.sizeNotAligned(offset: 108, size: 10)))
        #expect(file.bytesWalked == 108)
    }

    /// Missing EOF: header + a well-formed record, buffer ends with no EOF.
    @Test("missing EOF: missingEOF diagnostic")
    func missingEOF() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 116, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        // No EOF record.

        let file = try EMFFile.parse(fixture.data)

        #expect(file.records.count == 2)
        #expect(file.records.last?.type != 14)
        #expect(file.diagnostics.contains(.missingEOF))
        #expect(file.bytesWalked == 116)
    }

    /// Trailing bytes after EOF: extra bytes beyond the EMR_EOF record.
    @Test("trailing bytes after EOF: trailingBytesAfterEOF(count)")
    func trailingBytesAfterEOF() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 128, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof(size: 20))
        fixture.appendZeros(16)                    // 16 stray trailing bytes

        let file = try EMFFile.parse(fixture.data)

        #expect(file.records.count == 2)
        #expect(file.records.last?.type == 14)
        #expect(file.diagnostics.contains(.trailingBytesAfterEOF(count: 16)))
        #expect(file.bytesWalked == 128)           // walk stops at EOF end
    }

    /// Header `Records` disagreeing with the walk → recordCountMismatch, and
    /// nothing else wrong. Mirrors the real WS-B off-by-one (primer §8/D4).
    @Test("Records field off by one: recordCountMismatch only")
    func recordCountMismatch() throws {
        // Actual records = 2, but header claims 3.
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 128, recordsField: 3)
        )
        fixture.appendBytes(FixtureBuilder.eof(size: 20))

        let file = try EMFFile.parse(fixture.data)

        #expect(file.records.count == 2)
        #expect(file.diagnostics.contains(
            .recordCountMismatch(headerSays: 3, walked: 2)
        ))
        // The record list is unaffected by the advisory mismatch.
        #expect(file.records[0].type == 1)
        #expect(file.records[1].type == 14)
        // Bytes field matches, so no byteCountMismatch.
        #expect(!file.diagnostics.contains(where: {
            if case .byteCountMismatch = $0 { return true }
            return false
        }))
    }

    /// Advisory `Bytes` mismatch reported independently of the record count.
    @Test("Bytes field mismatch: byteCountMismatch")
    func byteCountMismatch() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 999, recordsField: 2)
        )
        fixture.appendBytes(FixtureBuilder.eof(size: 20))

        let file = try EMFFile.parse(fixture.data)

        #expect(file.bytesWalked == 128)
        #expect(file.diagnostics.contains(.byteCountMismatch(headerSays: 999, walked: 128)))
    }

    /// §8 memory guard: a file of `cap + 1000` minimal 8-byte records is
    /// walked only up to the 1,000,000-record cap, then stopped with everything
    /// parsed so far kept. `records.count` lands exactly on the cap, the
    /// `recordCountCapped` diagnostic is present, and — because the walk was cut
    /// short deliberately rather than running off the end — no `missingEOF` is
    /// raised alongside it (the two would be a misleading pair). The advisory
    /// `Records`/`Bytes` mismatches are legitimate here (the header describes
    /// the full untruncated file) and are allowed to coexist truthfully.
    @Test("record-count cap: all-tiny-records file stops at the cap")
    func recordCountCap() throws {
        let cap = EMFFile.recordCountLimit
        // cap + 1000 minimal SAVEDC (type 33, size 8) records, no EOF. Built as
        // one flat block for speed — a 1M-record walk stays well under a second
        // in debug.
        let nonHeaderRecords = cap + 1000
        let template: [UInt8] = [33, 0, 0, 0, 8, 0, 0, 0]   // SAVEDC, nSize 8

        var bytes = FixtureBuilder.header(fixedSize: 108, recordsField: UInt32(cap + 1001))
        bytes.reserveCapacity(bytes.count + nonHeaderRecords * 8)
        for _ in 0 ..< nonHeaderRecords {
            bytes.append(contentsOf: template)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let file = try EMFFile.parse(Data(bytes))
        let elapsed = clock.now - start

        // Walk stopped exactly at the cap, keeping everything parsed so far.
        #expect(file.records.count == cap)
        #expect(file.diagnostics.contains(.recordCountCapped(limit: cap)))
        // The deliberate cap-stop must NOT also report a missing EOF.
        #expect(!file.diagnostics.contains(.missingEOF))
        // bytesWalked accounts for exactly the walked records (header + the
        // cap-1 admitted 8-byte records).
        #expect(file.bytesWalked == 108 + (cap - 1) * 8)
        // Sanity on runtime; report rather than shrink the cap if it regresses.
        #expect(elapsed < .seconds(5), "1M-record walk took \(elapsed)")
    }

    @Test("record-name lookup: known, prefixed, and unknown values")
    func recordNameLookup() {
        #expect(EMFRecordType.name(for: 1) == "EMR_HEADER")
        #expect(EMFRecordType.name(for: 14) == "EMR_EOF")
        #expect(EMFRecordType.name(for: 122) == "EMR_CREATECOLORSPACEW")
        // Undefined values from the spec's gaps.
        #expect(EMFRecordType.name(for: 69) == nil)
        #expect(EMFRecordType.name(for: 107) == nil)
        #expect(EMFRecordType.name(for: 117) == nil)
        #expect(EMFRecordType.name(for: 9999) == nil)
    }

    /// recordInventory aggregates per type (count + total bytes, header
    /// included) sorted by type id ascending, regardless of file order.
    @Test("recordInventory: per-type aggregation sorted by type id")
    func recordInventoryAggregation() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(
            FixtureBuilder.header(fixedSize: 108, bytesField: 164, recordsField: 6)
        )
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        fixture.appendBytes(FixtureBuilder.record(type: 17, size: 12))
        fixture.appendBytes(FixtureBuilder.record(type: 33, size: 8))
        fixture.appendBytes(FixtureBuilder.eof(size: 20))
        // Total: 108 + 8 + 8 + 12 + 8 + 20 = 164 bytes, 6 records.

        let file = try EMFFile.parse(fixture.data)
        #expect(file.diagnostics.isEmpty)

        let inventory = file.recordInventory()
        #expect(inventory.count == 4)
        #expect(inventory[0] == (type: 1, count: 1, totalBytes: 108))
        #expect(inventory[1] == (type: 14, count: 1, totalBytes: 20))
        #expect(inventory[2] == (type: 17, count: 1, totalBytes: 12))
        #expect(inventory[3] == (type: 33, count: 3, totalBytes: 24))
    }
}
