import Foundation
import Testing
@testable import EMFParse

// MARK: - EMF+ fixture builders

/// Builds one EMF+ record's bytes ([MS-EMFPLUS] §2.3): Type (u16), Flags (u16),
/// Size (u32, total incl. this 12-byte header), DataSize (u32), then `data`.
/// `sizeOverride`/`dataSizeOverride` write lying header fields while keeping the
/// real body, for the hostile cases; the actual on-wire length is always
/// `12 + data.count`.
private func emfPlusRecord(
    type: UInt16,
    flags: UInt16 = 0,
    data: [UInt8] = [],
    sizeOverride: UInt32? = nil,
    dataSizeOverride: UInt32? = nil
) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(sizeOverride ?? UInt32(12 + data.count))
    b.appendUInt32(dataSizeOverride ?? UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

/// The 16-byte EmfPlusHeader RecordData ([MS-EMFPLUS] §2.3.3.3): Version,
/// EmfPlusFlags, LogicalDpiX, LogicalDpiY (each u32, little-endian).
private func emfPlusHeaderData(
    version: UInt32 = 0xDBC0_1002,
    emfPlusFlags: UInt32 = 0,
    dpiX: UInt32 = 96,
    dpiY: UInt32 = 96
) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(version)
    b.appendUInt32(emfPlusFlags)
    b.appendUInt32(dpiX)
    b.appendUInt32(dpiY)
    return b.bytes
}

/// A well-formed 28-byte EmfPlusHeader record (Size 0x1C, DataSize 0x10).
private func emfPlusHeaderRecord(
    dualFlag: Bool = true,
    version: UInt32 = 0xDBC0_1002,
    emfPlusFlags: UInt32 = 0,
    dpiX: UInt32 = 96,
    dpiY: UInt32 = 96
) -> [UInt8] {
    emfPlusRecord(
        type: 0x4001,
        flags: dualFlag ? 0x0001 : 0x0000,
        data: emfPlusHeaderData(version: version, emfPlusFlags: emfPlusFlags, dpiX: dpiX, dpiY: dpiY)
    )
}

/// Wraps an EMF+ record stream in an EMR_COMMENT_EMFPLUS record
/// ([MS-EMF] §2.3.3.4): Type (70), nSize, DataSize (u32), CommentIdentifier
/// (u32), then the stream. DataSize counts from the identifier, so honestly it
/// is `4 + stream.count`; `dataSizeOverride` forges a lying value while nSize
/// stays truthful. `identifier` forges a non-EMF+ comment.
private func emfPlusComment(
    stream: [UInt8],
    identifier: UInt32 = 0x2B46_4D45,   // "EMF+"
    dataSizeOverride: UInt32? = nil
) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(identifier)
    payload.appendBytes(stream)
    let data = payload.bytes                              // identifier + stream

    var b = FixtureBuilder()
    b.appendUInt32(70)                                    // 0  iType = EMR_COMMENT
    b.appendUInt32(UInt32(8 + 4 + data.count))            // 4  nSize (truthful)
    b.appendUInt32(dataSizeOverride ?? UInt32(data.count)) // 8  DataSize (from identifier)
    b.appendBytes(data)                                   // 12 identifier + stream
    return b.bytes
}

/// Builds a clean file (108-byte header + the given record blobs + EOF) and
/// parses it, returning the file for `emfPlusStream()` queries.
private func parseFile(records: [[UInt8]]) throws -> EMFFile {
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    for record in records {
        fixture.appendBytes(record)
    }
    fixture.appendBytes(FixtureBuilder.eof())
    return try EMFFile.parse(fixture.data)
}

@Suite("EMF+ stream walker")
struct EMFPlusStreamTests {

    // MARK: - 1. Single-comment header + end-of-file

    @Test("single comment: Header + EndOfFile → 2 records, decoded header, exact accounting")
    func singleCommentHeaderAndEOF() throws {
        let stream = emfPlusHeaderRecord(dualFlag: true, version: 0xDBC0_1002,
                                         emfPlusFlags: 0x0000_0001, dpiX: 96, dpiY: 120)
            + emfPlusRecord(type: 0x4002)
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        let s = file.emfPlusStream()

        #expect(s.records.count == 2)
        #expect(s.records.map(\.type) == [0x4001, 0x4002])

        let header = try #require(s.header)
        #expect(header.version == 0xDBC0_1002)
        #expect(header.isDual == true)
        #expect(header.isVideoDisplay == true)
        #expect(header.logicalDpiX == 96)
        #expect(header.logicalDpiY == 120)

        // Accounting: 28-byte header + 12-byte EndOfFile = 40, fully consumed.
        #expect(s.assembledByteCount == 40)
        #expect(s.bytesConsumed == 40)
        #expect(s.leftoverByteCount == 0)
        #expect(s.diagnostics.isEmpty)
    }

    /// The dual and video-display bits are read from independent words — the
    /// record-header Flags bit 0x0001 and the EmfPlusFlags bit 0x00000001.
    @Test("header flag/EmfPlusFlags bits", arguments: [
        (false, UInt32(0x0000_0000), false, false),
        (true, UInt32(0x0000_0000), true, false),
        (false, UInt32(0x0000_0001), false, true),
        (true, UInt32(0x0000_0001), true, true),
    ])
    func headerFlagBits(dual: Bool, emfPlusFlags: UInt32, expectDual: Bool, expectVideo: Bool) throws {
        let stream = emfPlusHeaderRecord(dualFlag: dual, emfPlusFlags: emfPlusFlags)
            + emfPlusRecord(type: 0x4002)
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()
        let header = try #require(s.header)
        #expect(header.isDual == expectDual)
        #expect(header.isVideoDisplay == expectVideo)
    }

    // MARK: - 2 & 3. Fragmentation across comments

    @Test("one 40-byte record split 20/20 across two comments → one record, byte-exact payload")
    func recordSplitAcrossTwoComments() throws {
        let payload = (0 ..< 28).map { UInt8($0) }                  // 28 distinctive bytes
        let full = emfPlusRecord(type: 0x4008, data: payload)       // 40 bytes total
        #expect(full.count == 40)
        let fragA = Array(full[0 ..< 20])
        let fragB = Array(full[20 ..< 40])

        let file = try parseFile(records: [
            emfPlusComment(stream: fragA),
            emfPlusComment(stream: fragB),
        ])
        let s = file.emfPlusStream()

        #expect(s.records.count == 1)
        let record = try #require(s.records.first)
        #expect(record.type == 0x4008)
        #expect(record.declaredSize == 40)
        #expect(record.declaredDataSize == 28)
        #expect(Array(record.data) == payload)                      // byte-exact, reassembled
        #expect(s.assembledByteCount == 40)
        #expect(s.bytesConsumed == 40)
        #expect(s.leftoverByteCount == 0)
        // First record is not a header, so the missing-header note is expected.
        #expect(s.header == nil)
        #expect(s.diagnostics == [.headerRecordMissing])
    }

    @Test("12-byte record header split across two comments → still walked, header decoded")
    func recordHeaderSplitAcrossComments() throws {
        // A 28-byte EmfPlusHeader split at offset 8: the first fragment carries
        // only 8 of the 12 header bytes, so the record header itself straddles
        // the comment boundary. Both fragments stay 4-aligned (8 and 20).
        let full = emfPlusHeaderRecord(dualFlag: true, version: 0xDBC0_1001, dpiX: 300, dpiY: 300)
        #expect(full.count == 28)
        let fragA = Array(full[0 ..< 8])
        let fragB = Array(full[8 ..< 28])

        let s = try parseFile(records: [
            emfPlusComment(stream: fragA),
            emfPlusComment(stream: fragB),
        ]).emfPlusStream()

        #expect(s.records.count == 1)
        #expect(s.records.first?.type == 0x4001)
        let header = try #require(s.header)
        #expect(header.version == 0xDBC0_1001)
        #expect(header.isDual == true)
        #expect(header.logicalDpiX == 300)
        #expect(header.logicalDpiY == 300)
        #expect(s.bytesConsumed == 28)
        #expect(s.leftoverByteCount == 0)
        #expect(s.diagnostics.isEmpty)
    }

    // MARK: - 4. DataSize overruns the assembled stream

    @Test("final record DataSize overruns stream → diagnostic, no phantom record, prior kept")
    func finalRecordDataOverrun() throws {
        // Header, then a record whose header is structurally valid (Size 112,
        // 4-aligned, DataSize 100 <= 112-12) but which supplies only 4 body
        // bytes — the declared data runs far past the assembled buffer.
        let overrun = emfPlusRecord(
            type: 0x400A, data: [0xDE, 0xAD, 0xBE, 0xEF],
            sizeOverride: 112, dataSizeOverride: 100
        )
        let stream = emfPlusHeaderRecord() + overrun               // 28 + 16 on-wire = 44
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()

        #expect(s.records.count == 1)                              // only the header
        #expect(s.records.first?.type == 0x4001)
        #expect(s.header != nil)                                   // header still decoded
        #expect(s.assembledByteCount == 44)
        #expect(s.bytesConsumed == 28)
        #expect(s.leftoverByteCount == 16)
        #expect(s.diagnostics.contains(
            .recordDataTruncated(streamOffset: 28, declaredDataSize: 100, availableBytes: 16)
        ))
    }

    // MARK: - 5. Structurally invalid Size / DataSize (safe stop, no hang)

    @Test("Size == 0 → recordSizeTooSmall, walk stops, no hang")
    func zeroSize() throws {
        let stream = emfPlusHeaderRecord()
            + emfPlusRecord(type: 0x400A, data: [0, 0, 0, 0], sizeOverride: 0)
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()
        #expect(s.records.count == 1)                              // header only
        #expect(s.diagnostics.contains(.recordSizeTooSmall(streamOffset: 28, size: 0)))
        #expect(s.bytesConsumed == 28)
    }

    @Test("Size not 4-aligned → recordSizeNotAligned, walk stops")
    func sizeNotAligned() throws {
        let stream = emfPlusHeaderRecord()
            + emfPlusRecord(type: 0x400A, sizeOverride: 14)         // >= 12 but not aligned
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()
        #expect(s.records.count == 1)
        #expect(s.diagnostics.contains(.recordSizeNotAligned(streamOffset: 28, size: 14)))
    }

    @Test("DataSize > Size - 12 → recordDataSizeExceedsSize, walk stops")
    func dataSizeExceedsSize() throws {
        // Size 12 (no room for data), yet DataSize claims 8.
        let stream = emfPlusHeaderRecord()
            + emfPlusRecord(type: 0x400A, sizeOverride: 12, dataSizeOverride: 8)
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()
        #expect(s.records.count == 1)
        #expect(s.diagnostics.contains(
            .recordDataSizeExceedsSize(streamOffset: 28, size: 12, dataSize: 8)
        ))
    }

    // MARK: - 6. Interleaved non-EMF+ comments and GDI records

    @Test("GDI records and a non-EMF+ comment interleaved are ignored; order preserved")
    func interleavedNonEMFPlusIgnored() throws {
        // A GDIC comment whose bytes even mimic a drawing record, plus plain GDI
        // records, surround the two real EMF+ comments. Only the EMF+ comments —
        // in order — may contribute to the assembled stream.
        let decoy = emfPlusRecord(type: 0x400A, data: [1, 2, 3, 4, 5, 6, 7, 8])
        let file = try parseFile(records: [
            FixtureBuilder.record(type: 17, size: 12),                       // GDI SETMAPMODE
            emfPlusComment(stream: decoy, identifier: 0x4349_4447),          // "GDIC" — ignored
            emfPlusComment(stream: emfPlusHeaderRecord()),                   // EMF+ #1: Header
            FixtureBuilder.record(type: 27, size: 12),                       // GDI MOVETOEX
            emfPlusComment(stream: emfPlusRecord(type: 0x4002)),             // EMF+ #2: EndOfFile
        ])
        let s = file.emfPlusStream()

        #expect(s.records.map(\.type) == [0x4001, 0x4002])
        #expect(s.assembledByteCount == 40)                                  // 28 + 12 only
        #expect(s.bytesConsumed == 40)
        #expect(s.leftoverByteCount == 0)
        #expect(s.header != nil)
        #expect(s.diagnostics.isEmpty)
    }

    // MARK: - 7. No EMF+ comments at all

    @Test("file with no EMF+ comments → empty records, nil header, empty diagnostics")
    func noEMFPlusComments() throws {
        let s = try parseFile(records: [FixtureBuilder.record(type: 17, size: 12)]).emfPlusStream()
        #expect(s.records.isEmpty)
        #expect(s.header == nil)
        #expect(s.diagnostics.isEmpty)                                       // deliberately silent
        #expect(s.assembledByteCount == 0)
        #expect(s.bytesConsumed == 0)
        #expect(s.leftoverByteCount == 0)
    }

    // MARK: - Header MUSTs, missing header, clamp, trailing bytes

    @Test("first record not EmfPlusHeader (comments present) → headerRecordMissing, header nil")
    func firstRecordNotHeader() throws {
        // Stream opens with EndOfFile — an EMF+ comment is present, so the
        // missing required header is a diagnostic, not silence.
        let s = try parseFile(records: [emfPlusComment(stream: emfPlusRecord(type: 0x4002))])
            .emfPlusStream()
        #expect(s.records.map(\.type) == [0x4002])
        #expect(s.header == nil)
        #expect(s.diagnostics == [.headerRecordMissing])
    }

    @Test("EmfPlusHeader with wrong Size/DataSize → diagnostics + best-effort decode")
    func headerSizeMustViolation() throws {
        // A header-typed record padded to 20 bytes of data (Size 32, DataSize 20)
        // — both violate the §2.3.3.3 MUSTs, yet the fields are still decoded
        // from the first 16 body bytes. On-wire length equals Size, so the walk
        // stays valid.
        let body = emfPlusHeaderData(version: 0xDBC0_1002, emfPlusFlags: 0, dpiX: 72, dpiY: 72)
            + [0, 0, 0, 0]
        let stream = emfPlusRecord(type: 0x4001, flags: 0x0001, data: body)   // Size 32, DataSize 20
            + emfPlusRecord(type: 0x4002)
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()

        #expect(s.diagnostics.contains(.headerUnexpectedSize(size: 32)))
        #expect(s.diagnostics.contains(.headerUnexpectedDataSize(dataSize: 20)))
        let header = try #require(s.header)                                  // best-effort decode
        #expect(header.version == 0xDBC0_1002)
        #expect(header.logicalDpiX == 72)
        #expect(header.isDual == true)
    }

    @Test("comment DataSize lying past record extent → clamped with diagnostic, records kept")
    func lyingCommentDataSizeClamped() throws {
        let stream = emfPlusHeaderRecord() + emfPlusRecord(type: 0x4002)     // 40 stream bytes
        // Honest DataSize would be 44 (4 + 40); claim 200. nSize stays truthful.
        let file = try parseFile(records: [emfPlusComment(stream: stream, dataSizeOverride: 200)])
        let s = file.emfPlusStream()

        // Comment sits right after the 108-byte header.
        #expect(s.diagnostics.contains(
            .commentDataSizeClamped(recordOffset: 108, declaredDataSize: 200, keptStreamBytes: 40)
        ))
        #expect(s.records.map(\.type) == [0x4001, 0x4002])                   // still walked
        #expect(s.assembledByteCount == 40)
        #expect(s.leftoverByteCount == 0)
    }

    @Test("sub-header tail after a valid record → trailingBytes diagnostic, leftover counted")
    func trailingSubHeaderBytes() throws {
        // Header (28) then 4 stray bytes that cannot hold a 12-byte header.
        let stream = emfPlusHeaderRecord() + [0xAA, 0xBB, 0xCC, 0xDD]
        let s = try parseFile(records: [emfPlusComment(stream: stream)]).emfPlusStream()
        #expect(s.records.count == 1)
        #expect(s.records.first?.type == 0x4001)
        #expect(s.diagnostics.contains(.trailingBytes(count: 4)))
        #expect(s.bytesConsumed == 28)
        #expect(s.leftoverByteCount == 4)
        #expect(s.assembledByteCount == 32)
    }

    // MARK: - 8. Corpus: gate-p2-star.emf (committed)

    /// gate-p2-star.emf is a LibreOffice dual-mode export whose EMF+ stream is a
    /// non-drawing shell reassembled from three EMR_COMMENT_EMFPLUS records
    /// (28 + 60 + 12 = 100 bytes). The seven-record sequence is pinned exactly.
    @Test("gate-p2-star.emf → 7 records, pinned sequence, dual header v0xDBC01002")
    func corpusStar() throws {
        let file = try EMFFile.parse(try requireCorpus("gate-p2-star.emf"))
        let s = file.emfPlusStream()

        #expect(s.records.count == 7)
        #expect(s.records.map(\.type) == [
            0x4001, 0x4022, 0x401E, 0x4024, 0x4021, 0x4004, 0x4002,
        ])
        #expect(s.records.map(\.displayName) == [
            "EmfPlusHeader", "EmfPlusSetPixelOffsetMode", "EmfPlusSetAntiAliasMode",
            "EmfPlusSetCompositingQuality", "EmfPlusSetInterpolationMode",
            "EmfPlusGetDC", "EmfPlusEndOfFile",
        ])
        // No drawing records — this is a shell (consistent with emfPlusPresence).
        #expect(s.records.allSatisfy { !$0.isDrawing })

        let header = try #require(s.header)
        #expect(header.version == 0xDBC0_1002)
        #expect(header.isDual == true)
        #expect(header.isVideoDisplay == true)
        #expect(header.logicalDpiX == 96)
        #expect(header.logicalDpiY == 96)

        #expect(s.assembledByteCount == 100)
        #expect(s.bytesConsumed == 100)
        #expect(s.leftoverByteCount == 0)
        #expect(s.diagnostics.isEmpty)
    }
}

// MARK: - Record-type table

@Suite("EMF+ record type table")
struct EMFPlusRecordTypeTests {

    @Test("verified names for representative and boundary types")
    func names() {
        #expect(EMFPlusRecordType.name(for: 0x4001) == "EmfPlusHeader")
        #expect(EMFPlusRecordType.name(for: 0x4002) == "EmfPlusEndOfFile")
        #expect(EMFPlusRecordType.name(for: 0x4008) == "EmfPlusObject")
        #expect(EMFPlusRecordType.name(for: 0x4036) == "EmfPlusDrawDriverString")
        #expect(EMFPlusRecordType.name(for: 0x4037) == "EmfPlusStrokeFillPath")
        #expect(EMFPlusRecordType.name(for: 0x403A) == "EmfPlusSetTSClip")
        // Outside the 0x4001…0x403A table.
        #expect(EMFPlusRecordType.name(for: 0x4000) == nil)
        #expect(EMFPlusRecordType.name(for: 0x403B) == nil)
        #expect(EMFPlusRecordType.name(for: 0x8888) == nil)
    }

    @Test("displayName resolves a name or a 4-digit hex fallback")
    func displayNames() {
        #expect(EMFPlusRecordType.displayName(for: 0x4001) == "EmfPlusHeader")
        #expect(EMFPlusRecordType.displayName(for: 0x403B) == "0x403B")
        #expect(EMFPlusRecordType.displayName(for: 0x8888) == "0x8888")
        #expect(EMFPlusRecordType.displayName(for: 0x0000) == "0x0000")
    }

    @Test("every id in 0x4001…0x403A resolves to a name (58 types)")
    func fullTableCoverage() {
        var named = 0
        for value in UInt16(0x4001) ... UInt16(0x403A) where EMFPlusRecordType.name(for: value) != nil {
            named += 1
        }
        #expect(named == 0x403A - 0x4001 + 1)   // 58
    }

    /// The drawing group is the formal [MS-EMFPLUS] §2.3.4 membership:
    /// 0x4009…0x401C plus 0x4036. 0x4037 EmfPlusStrokeFillPath is deliberately
    /// NOT drawing here — a documented divergence from EMFPlusPresence, which
    /// treats it as drawing on semantic grounds (see EMFPlusRecordType.isDrawing).
    @Test("isDrawing boundaries and the 0x4037 divergence", arguments: [
        (UInt16(0x4008), false),   // Object — just below the block
        (0x4009, true),            // Clear — block start
        (0x4013, true),            // FillRegion — interior
        (0x401C, true),            // DrawString — block end
        (0x401D, false),           // SetRenderingOrigin — just above
        (0x4035, false),           // OffsetClip
        (0x4036, true),            // DrawDriverString — the singleton
        (0x4037, false),           // StrokeFillPath — DIVERGES from EMFPlusPresence
        (0x4038, false),           // SerializableObject
    ])
    func isDrawingBoundaries(type: UInt16, expected: Bool) {
        #expect(EMFPlusRecordType.isDrawing(type) == expected)
    }

    @Test("EMFPlusRecord surfaces its own resolved type, display name, and drawing flag")
    func recordConvenience() {
        let drawing = EMFPlusRecord(type: 0x400A, flags: 0, declaredSize: 12, declaredDataSize: 0, data: Data())
        #expect(drawing.typeName == "EmfPlusFillRects")
        #expect(drawing.displayName == "EmfPlusFillRects")
        #expect(drawing.isDrawing == true)

        let unknown = EMFPlusRecord(type: 0x4099, flags: 0, declaredSize: 12, declaredDataSize: 0, data: Data())
        #expect(unknown.typeName == nil)
        #expect(unknown.displayName == "0x4099")
        #expect(unknown.isDrawing == false)
    }
}
