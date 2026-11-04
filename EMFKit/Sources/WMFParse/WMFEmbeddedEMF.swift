import Foundation

/// Reassembly of an EMF metafile embedded in a WMF via a run of
/// META_ESCAPE_ENHANCED_METAFILE records ([MS-WMF] §2.3.6.25).
///
/// An Office/LibreOffice WMF carries a complete EMF, split into ≤8 KiB chunks,
/// in consecutive META_ESCAPE records whose comment identifier is "WMFC"
/// (0x43464D57). When that embedded EMF reassembles consistently and parses,
/// the owner's decision is to play it instead of the WMF records (higher
/// fidelity). Any inconsistency — a bad field, a gap, an out-of-order chunk, a
/// count that does not add up, or an EMF that later fails `EMFFile.parse` — is a
/// fall back to playing the WMF records (§8).
///
/// The one's-complement WORD checksum ([MS-WMF] §2.3.6.25) is NOT gated on:
/// real emitters zero it or miscompute it (verified across the corpus), so
/// gating on it would wrongly reject every real embedded EMF. The structural
/// running totals here plus the caller's `EMFFile.parse` are the stronger
/// end-to-end gate.
public enum WMFEmbeddedEMF {

    /// Why an embedded-EMF escape sequence was not accepted for playback.
    public enum Rejection: Sendable, Equatable {
        /// A chunk's CommentIdentifier was not 0x43464D57 ("WMFC").
        case commentIdentifierMismatch
        /// A chunk's CommentType was not 0x00000001.
        case commentTypeMismatch
        /// A chunk was too short to hold the 34-byte comment header.
        case truncatedHeader
        /// A chunk's EnhancedMetafileData (CurrentRecordSize bytes) ran past the
        /// record.
        case dataTruncated
        /// A chunk's CurrentRecordSize exceeded the 8192-byte maximum.
        case currentRecordSizeTooLarge
        /// A chunk's EnhancedMetafileDataSize disagreed with the first chunk.
        case totalSizeMismatch
        /// The number of consecutive escape chunks disagreed with
        /// CommentRecordCount.
        case recordCountMismatch
        /// A chunk's RemainingBytes did not equal the bytes still to come.
        case remainingBytesInconsistent
        /// Accumulated bytes exceeded the declared total.
        case accumulatedExceedsTotal
        /// The sequence ended before the declared total was reached.
        case incompleteSequence
        /// The declared total was zero or exceeded the reassembly cap.
        case totalOutOfRange
    }

    /// The outcome of scanning a WMF for an embedded EMF.
    public enum Result: Sendable, Equatable {
        /// No META_ESCAPE_ENHANCED_METAFILE records are present.
        case none
        /// An embedded-EMF sequence was present but inconsistent; play the WMF.
        case rejected(Rejection)
        /// A complete, consistent EMF byte stream (still to be validated by
        /// `EMFFile.parse` before playback).
        case reassembled(Data)
    }

    /// META_ESCAPE_ENHANCED_METAFILE EscapeFunction ([MS-WMF] §2.1.1.17).
    static let escapeFunction: UInt16 = 0x000F
    /// META_ESCAPE RecordFunction ([MS-WMF] §2.1.1.1).
    static let escapeRecordFunction: UInt16 = 0x0626
    /// CommentIdentifier "WMFC" ([MS-WMF] §2.3.6.25).
    static let commentIdentifier: UInt32 = 0x4346_4D57
    /// CommentType ([MS-WMF] §2.3.6.25).
    static let commentType: UInt32 = 0x0000_0001
    /// Per-chunk CurrentRecordSize maximum ([MS-WMF] §2.3.6.25).
    static let maxChunkBytes = 8192
    /// Fixed comment header size inside the EscapeData: CommentIdentifier(4) …
    /// EnhancedMetafileDataSize(4), i.e. bytes 4..38 of the record payload.
    static let headerByteCount = 38
    /// Reassembly cap (§8): the census put real EMFs under ~15 MiB; 64 MiB is a
    /// wide ceiling well above any plausible embedded EMF.
    static let maxTotalBytes = 64 * 1024 * 1024

    /// Scans `file`'s records for an embedded-EMF escape sequence and, when a
    /// complete and consistent one is present, returns the reassembled bytes.
    public static func reassemble(_ file: WMFFile) -> Result {
        // Locate the first "WMFC" escape chunk.
        guard let start = file.records.firstIndex(where: { isEmbeddedEscape($0, in: file) }) else {
            return .none
        }

        var buffer = Data()
        var total: Int?
        var expectedCount: Int?
        var chunkCount = 0
        var index = start

        while index < file.records.count {
            let record = file.records[index]
            // The embedded chunks are consecutive; the first non-chunk record
            // ends the sequence.
            guard isEmbeddedEscape(record, in: file) else { break }

            let body = WMFByteReader(file.payload(of: record))
            guard body.count >= headerByteCount,
                  let identifier = body.readUInt32(at: 4),
                  let type = body.readUInt32(at: 8),
                  let currentRecordSize = body.readUInt32(at: 26),
                  let remainingBytes = body.readUInt32(at: 30),
                  let totalSize = body.readUInt32(at: 34)
            else {
                return .rejected(.truncatedHeader)
            }
            guard identifier == commentIdentifier else { return .rejected(.commentIdentifierMismatch) }
            guard type == commentType else { return .rejected(.commentTypeMismatch) }

            // Lock the declared totals from the first chunk; later chunks MUST
            // agree.
            if let total {
                guard Int(totalSize) == total else { return .rejected(.totalSizeMismatch) }
            } else {
                let declared = Int(totalSize)
                guard declared > 0, declared <= maxTotalBytes else { return .rejected(.totalOutOfRange) }
                total = declared
            }
            if let expectedCount {
                guard let count = body.readUInt32(at: 22), Int(count) == expectedCount else {
                    return .rejected(.recordCountMismatch)
                }
            } else if let count = body.readUInt32(at: 22) {
                expectedCount = Int(count)
            }

            let chunkSize = Int(currentRecordSize)
            guard chunkSize <= maxChunkBytes else { return .rejected(.currentRecordSizeTooLarge) }
            guard let chunk = body.data(at: headerByteCount, length: chunkSize) else {
                return .rejected(.dataTruncated)
            }

            buffer.append(chunk)
            chunkCount += 1
            guard let total, buffer.count <= total else { return .rejected(.accumulatedExceedsTotal) }
            // RemainingBytes = bytes still to follow AFTER this chunk.
            guard Int(remainingBytes) == total - buffer.count else {
                return .rejected(.remainingBytesInconsistent)
            }

            index += 1
        }

        guard let total, buffer.count == total else { return .rejected(.incompleteSequence) }
        if let expectedCount, chunkCount != expectedCount { return .rejected(.recordCountMismatch) }
        return .reassembled(buffer)
    }

    /// True when `record` is a META_ESCAPE whose EscapeFunction is the
    /// enhanced-metafile comment ([MS-WMF] §2.3.6.25).
    private static func isEmbeddedEscape(_ record: WMFRawRecord, in file: WMFFile) -> Bool {
        guard record.function == escapeRecordFunction else { return false }
        let body = WMFByteReader(file.payload(of: record))
        return body.readUInt16(at: 0) == escapeFunction
    }
}
