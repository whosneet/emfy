import Foundation
import Testing
@testable import EMFParse

// MARK: - Local EMF+ fixture builders

// These mirror the private helpers in EMFPlusStreamTests (kept file-private
// there, so duplicated here rather than shared). Each records the real on-wire
// length `12 + data.count`; the aggregation under test is meant to sum exactly
// that, so the fixtures are all well-formed and clean.

/// One EMF+ record's bytes ([MS-EMFPLUS] §2.3): Type (u16), Flags (u16),
/// Size (u32, incl. this 12-byte header), DataSize (u32), then `data`.
private func plusRecord(type: UInt16, flags: UInt16 = 0, data: [UInt8] = []) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(UInt32(12 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

/// A well-formed 28-byte EmfPlusHeader (Size 0x1C, DataSize 0x10): dual,
/// video-display, 96 dpi ([MS-EMFPLUS] §2.3.3.3).
private func plusHeaderRecord() -> [UInt8] {
    var body = FixtureBuilder()
    body.appendUInt32(0xDBC0_1002)   // Version
    body.appendUInt32(0x0000_0001)   // EmfPlusFlags (video display)
    body.appendUInt32(96)            // LogicalDpiX
    body.appendUInt32(96)            // LogicalDpiY
    return plusRecord(type: 0x4001, flags: 0x0001, data: body.bytes)
}

/// Wraps an EMF+ stream in one EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4):
/// Type (70), nSize, DataSize (from the identifier), CommentIdentifier "EMF+".
private func plusComment(stream: [UInt8]) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(0x2B46_4D45)   // "EMF+"
    payload.appendBytes(stream)
    let data = payload.bytes
    var b = FixtureBuilder()
    b.appendUInt32(70)                          // iType = EMR_COMMENT
    b.appendUInt32(UInt32(8 + 4 + data.count))  // nSize
    b.appendUInt32(UInt32(data.count))          // DataSize (from identifier)
    b.appendBytes(data)
    return b.bytes
}

/// Builds a clean file (108-byte header + one EMF+ comment + EOF), parses it,
/// and walks the EMF+ stream — a real walk, so `bytesConsumed` is genuine.
private func parsePlusStream(_ stream: [UInt8]) throws -> EMFPlusStream {
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    fixture.appendBytes(plusComment(stream: stream))
    fixture.appendBytes(FixtureBuilder.eof())
    return try EMFFile.parse(fixture.data).emfPlusStream()
}

/// Header + two FillRects of different data sizes + Object + EndOfFile — five
/// records, two sharing a type, all well-formed. On-wire: 28 + 20 + 28 + 16 + 12
/// = 104 bytes.
private func sampleStream() -> [UInt8] {
    plusHeaderRecord()                                                  // 0x4001, 28
        + plusRecord(type: 0x400A, data: [UInt8](repeating: 0, count: 8))    // FillRects, 20
        + plusRecord(type: 0x400A, data: [UInt8](repeating: 1, count: 16))   // FillRects, 28
        + plusRecord(type: 0x4008, data: [UInt8](repeating: 2, count: 4))    // Object, 16
        + plusRecord(type: 0x4002)                                     // EndOfFile, 12
}

// MARK: - Tests

@Suite("EMF+ record inventory")
struct EMFPlusInventoryTests {

    @Test("groups by type: ascending order, counts, 12+data.count byte sums")
    func aggregatesByType() throws {
        let inventory = try parsePlusStream(sampleStream()).recordInventory()

        #expect(inventory.map(\.type) == [0x4001, 0x4002, 0x4008, 0x400A])
        #expect(inventory.map(\.count) == [1, 1, 1, 2])
        // Header 28; EndOfFile 12; Object 16; the two FillRects 20 + 28 = 48.
        #expect(inventory.map(\.totalBytes) == [28, 12, 16, 48])
    }

    @Test("empty stream → empty inventory")
    func emptyStream() {
        let empty = EMFPlusStream(
            records: [], header: nil, diagnostics: [],
            assembledByteCount: 0, bytesConsumed: 0, leftoverByteCount: 0
        )
        #expect(empty.recordInventory().isEmpty)
    }

    @Test("inventory total bytes equals bytesConsumed on a clean fixture stream")
    func inventoryTotalEqualsConsumedFixture() throws {
        let stream = try parsePlusStream(sampleStream())
        #expect(stream.leftoverByteCount == 0)   // clean walk, nothing unwalked
        let total = stream.recordInventory().reduce(0) { $0 + $1.totalBytes }
        #expect(total == stream.bytesConsumed)
        #expect(total == 104)
    }

    /// The same gate property on a committed corpus file: gate-p2-star.emf's
    /// seven-record EMF+ shell reassembles to 100 bytes, all consumed.
    @Test("inventory total bytes equals bytesConsumed on gate-p2-star.emf")
    func inventoryTotalEqualsConsumedCorpus() throws {
        let stream = try EMFFile.parse(try requireCorpus("gate-p2-star.emf")).emfPlusStream()
        #expect(stream.leftoverByteCount == 0)
        let total = stream.recordInventory().reduce(0) { $0 + $1.totalBytes }
        #expect(total == stream.bytesConsumed)
        #expect(total == 100)
    }
}
