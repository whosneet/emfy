import Foundation

/// A non-fatal issue found while walking records after a valid header.
///
/// Per the log-and-skip failure model (primer §8): once a header is accepted,
/// parsing never throws. A malformed record produces a diagnostic, the walk
/// stops, and everything parsed so far is kept. Structural observations that
/// do not stop the walk (a `Records` mismatch, trailing bytes) are also
/// reported here. Offsets are byte offsets from the start of the file.
public enum EMFDiagnostic: Sendable, Equatable {
    /// A record's `nSize` was less than the 8-byte minimum. The walk stops at
    /// this record. `offset` is the record's start; `size` is the bad value.
    case sizeTooSmall(offset: Int, size: UInt32)
    /// A record's `nSize` was not a multiple of 4. The walk stops.
    case sizeNotAligned(offset: Int, size: UInt32)
    /// A record's `nSize` ran past the remaining bytes in the buffer. The walk
    /// stops. `remaining` is how many bytes were actually left from `offset`.
    case sizeExceedsRemaining(offset: Int, size: UInt32, remaining: Int)
    /// A record header (8 bytes) could not be read because too few bytes
    /// remained. The walk stops. `remaining` is the byte count left.
    case truncatedRecordHeader(offset: Int, remaining: Int)
    /// The walk consumed the whole buffer without encountering EMR_EOF.
    case missingEOF
    /// Bytes remained after the EMR_EOF record. `count` is how many.
    case trailingBytesAfterEOF(count: Int)
    /// The header's advisory `Records` field disagreed with the number of
    /// records actually walked.
    case recordCountMismatch(headerSays: UInt32, walked: Int)
    /// The header's advisory `Bytes` field disagreed with the number of bytes
    /// actually walked.
    case byteCountMismatch(headerSays: UInt32, walked: Int)
    /// The walk hit its record-count cap and stopped, keeping every record
    /// parsed so far. `limit` is the cap that was reached.
    ///
    /// Rationale (§8, the hostile surface): the walk materialises a fixed-size
    /// `EMFRawRecord` per record, while the on-disk minimum record is 8 bytes,
    /// so a crafted file of nothing but 8-byte records would inflate to an
    /// unbounded record array and could jetsam a sandboxed Quick Look
    /// extension mid-parse. The cap bounds that array well above any
    /// real-world file (our largest real corpus file holds ~276k records).
    case recordCountCapped(limit: Int)
}
