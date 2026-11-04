import EMFParse
import Foundation
import Testing
@testable import WMFParse

/// Tests for embedded-EMF reassembly ([MS-WMF] §2.3.6.25): a consistent
/// consecutive run of META_ESCAPE_ENHANCED_METAFILE chunks reassembles; any
/// field/count/running-total inconsistency is rejected (the renderer then plays
/// the WMF records instead).
@Suite("WMF embedded-EMF reassembly")
struct WMFEmbeddedEMFTests {

    /// Builds one META_ESCAPE_ENHANCED_METAFILE record around `chunk`.
    private static func escapeRecord(
        chunk: [UInt8],
        recordCount: UInt32,
        remainingBytes: UInt32,
        totalSize: UInt32,
        commentId: UInt32 = 0x4346_4D57,
        commentType: UInt32 = 0x0000_0001,
        escapeFunction: UInt16 = 0x000F,
        currentRecordSizeOverride: UInt32? = nil
    ) -> [UInt8] {
        let currentRecordSize = currentRecordSizeOverride ?? UInt32(chunk.count)
        var b = WMFFixtureBuilder()
        b.appendUInt16(escapeFunction)                    // EscapeFunction
        b.appendUInt16(UInt16(34 + chunk.count))          // ByteCount
        b.appendUInt32(commentId)                         // CommentIdentifier
        b.appendUInt32(commentType)                       // CommentType
        b.appendUInt32(0x0001_0000)                       // Version
        b.appendUInt16(0)                                 // Checksum (ignored)
        b.appendUInt32(0)                                 // Flags
        b.appendUInt32(recordCount)                       // CommentRecordCount
        b.appendUInt32(currentRecordSize)                 // CurrentRecordSize
        b.appendUInt32(remainingBytes)                    // RemainingBytes
        b.appendUInt32(totalSize)                         // EnhancedMetafileDataSize
        b.appendBytes(chunk)                              // EnhancedMetafileData
        return WMFFixtureBuilder.record(function: 0x0626, payload: b.bytes)
    }

    private static func parse(_ records: [[UInt8]]) throws -> WMFFile {
        var all = records
        all.append(WMFFixtureBuilder.eof())
        let data = WMFFixtureBuilder.file(header: WMFFixtureBuilder.metaHeader(), records: all)
        return try WMFFile.parse(data)
    }

    /// Splits `data` into `count` even-length chunks of consecutive escape
    /// records that reassemble to `data`.
    private static func chunkedRecords(_ data: [UInt8], count: Int) -> [[UInt8]] {
        let total = UInt32(data.count)
        var records: [[UInt8]] = []
        var accumulated = 0
        let base = ((data.count / count) + 1) & ~1   // even chunk size
        var offset = 0
        for i in 0 ..< count {
            let isLast = i == count - 1
            let end = isLast ? data.count : min(data.count, offset + base)
            let chunk = Array(data[offset ..< end])
            accumulated += chunk.count
            records.append(escapeRecord(
                chunk: chunk,
                recordCount: UInt32(count),
                remainingBytes: total - UInt32(accumulated),
                totalSize: total
            ))
            offset = end
        }
        return records
    }

    @Test("no escape records → none")
    func noEscape() throws {
        let file = try Self.parse([
            WMFFixtureBuilder.record(function: 0x0214, sizeWords: 5),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .none)
    }

    @Test("a non-enhanced-metafile escape is not treated as embedded")
    func otherEscapeIsNone() throws {
        let file = try Self.parse([
            Self.escapeRecord(chunk: [1, 2, 3, 4], recordCount: 1, remainingBytes: 0, totalSize: 4, escapeFunction: 0x0002),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .none)
    }

    @Test("a single consistent chunk reassembles")
    func singleChunk() throws {
        let emf: [UInt8] = Array(0 ..< 40)
        let file = try Self.parse([
            Self.escapeRecord(chunk: emf, recordCount: 1, remainingBytes: 0, totalSize: 40),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .reassembled(Data(emf)))
    }

    @Test("three consecutive chunks reassemble to the whole stream")
    func multiChunk() throws {
        let emf: [UInt8] = (0 ..< 90).map { UInt8($0 % 251) }
        let file = try Self.parse(Self.chunkedRecords(emf, count: 3))
        #expect(WMFEmbeddedEMF.reassemble(file) == .reassembled(Data(emf)))
    }

    @Test("a mismatched EnhancedMetafileDataSize is rejected")
    func totalSizeMismatch() throws {
        let emf: [UInt8] = (0 ..< 60).map { UInt8($0) }
        var records = Self.chunkedRecords(emf, count: 2)
        // Corrupt the second chunk's total size by rebuilding it with a wrong total.
        records[1] = Self.escapeRecord(chunk: Array(emf[30 ..< 60]), recordCount: 2, remainingBytes: 0, totalSize: 999)
        let file = try Self.parse(records)
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.totalSizeMismatch))
    }

    @Test("an inconsistent RemainingBytes field is rejected")
    func remainingBytesInconsistent() throws {
        let emf: [UInt8] = (0 ..< 60).map { UInt8($0) }
        var records = Self.chunkedRecords(emf, count: 2)
        records[0] = Self.escapeRecord(chunk: Array(emf[0 ..< 30]), recordCount: 2, remainingBytes: 12345, totalSize: 60)
        let file = try Self.parse(records)
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.remainingBytesInconsistent))
    }

    @Test("too few chunks for the declared CommentRecordCount is rejected")
    func recordCountMismatch() throws {
        let emf: [UInt8] = Array(0 ..< 40)
        // One chunk that completes the total but claims a record count of 3.
        let file = try Self.parse([
            Self.escapeRecord(chunk: emf, recordCount: 3, remainingBytes: 0, totalSize: 40),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.recordCountMismatch))
    }

    @Test("a wrong CommentIdentifier is rejected")
    func commentIdentifierMismatch() throws {
        let emf: [UInt8] = Array(0 ..< 40)
        let file = try Self.parse([
            Self.escapeRecord(chunk: emf, recordCount: 1, remainingBytes: 0, totalSize: 40, commentId: 0xDEAD_BEEF),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.commentIdentifierMismatch))
    }

    @Test("a chunk larger than 8192 bytes is rejected")
    func chunkTooLarge() throws {
        let emf = [UInt8](repeating: 7, count: 40)
        let file = try Self.parse([
            Self.escapeRecord(chunk: emf, recordCount: 1, remainingBytes: 0, totalSize: 40, currentRecordSizeOverride: 9000),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.currentRecordSizeTooLarge))
    }

    @Test("an EnhancedMetafileDataSize past the 64 MiB cap is rejected without allocating toward it")
    func totalOutOfRange() throws {
        let overCap = UInt32(64 * 1024 * 1024 + 1)
        let file = try Self.parse([
            Self.escapeRecord(chunk: [1, 2, 3, 4], recordCount: 1, remainingBytes: overCap - 4, totalSize: overCap),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.totalOutOfRange))
    }

    @Test("a non-escape record interleaved mid-sequence ends the run early and is rejected")
    func interleavedNonEscape() throws {
        let emf: [UInt8] = (0 ..< 60).map { UInt8($0) }
        let c0 = Self.escapeRecord(chunk: Array(emf[0 ..< 30]), recordCount: 2, remainingBytes: 30, totalSize: 60)
        let c1 = Self.escapeRecord(chunk: Array(emf[30 ..< 60]), recordCount: 2, remainingBytes: 0, totalSize: 60)
        let interloper = WMFFixtureBuilder.record(function: 0x0214, sizeWords: 5)   // META_MOVETO
        let file = try Self.parse([c0, interloper, c1])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.incompleteSequence))
    }

    @Test("a sequence that never reaches its declared total is rejected as incomplete")
    func incompleteSequence() throws {
        // One chunk declares a 1000-byte total but supplies 10 bytes and ends.
        let file = try Self.parse([
            Self.escapeRecord(chunk: Array(0 ..< 10), recordCount: 1, remainingBytes: 990, totalSize: 1000),
        ])
        #expect(WMFEmbeddedEMF.reassemble(file) == .rejected(.incompleteSequence))
    }

    @Test("every committed gate WMF carries a reassembling embedded EMF that parses")
    func corpusEmbeddedEMFsReassemble() throws {
        // The p2/p3 LibreOffice exports each embed a complete EMF; it must
        // reassemble AND parse (so the renderer plays it over the WMF records).
        for name in ["gate-wmf-p2-house", "gate-wmf-p2-star", "gate-wmf-p3-shapes", "gate-wmf-p3-curves"] {
            let file = try WMFFile.parse(try WMFCorpus.data("\(name).wmf"))
            guard case .reassembled(let bytes) = WMFEmbeddedEMF.reassemble(file) else {
                Issue.record("\(name): expected a reassembled embedded EMF")
                continue
            }
            _ = try EMFParse.EMFFile.parse(bytes)   // throws if the embedded EMF is not a valid EMF
        }
    }
}
