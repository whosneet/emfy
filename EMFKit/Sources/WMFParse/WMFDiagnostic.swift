import Foundation

/// A non-fatal issue found while reading a WMF, after a valid header.
///
/// Per the log-and-skip failure model (primer §8): once a header is accepted,
/// parsing never throws. A malformed record produces a diagnostic, the walk
/// stops, and everything parsed so far is kept — the renderer must still get
/// the partial file. Structural observations that do not stop the walk (a
/// trailing-bytes note, an advisory-field disagreement, a placeable checksum
/// mismatch) are also reported here. Offsets are byte offsets from the start of
/// the file.
public enum WMFDiagnostic: Sendable, Equatable {
    /// A record's `RecordSize` was below the 3-WORD (6-byte) minimum — a record
    /// cannot be smaller than its own header ([MS-WMF] §2.3). The walk stops at
    /// this record. `offset` is the record's start; `sizeWords` is the value.
    case recordSizeTooSmall(offset: Int, sizeWords: UInt32)
    /// A record's `RecordSize` × 2 ran past the remaining bytes in the buffer
    /// (or overflowed). The walk stops. `byteSize` is the computed byte span;
    /// `remaining` is how many bytes were actually left from `offset`.
    case recordSizeExceedsRemaining(offset: Int, byteSize: Int, remaining: Int)
    /// Fewer than the 6 bytes needed for a record's `RecordSize`/`RecordFunction`
    /// header remained. The walk stops. `remaining` is the byte count left.
    case truncatedRecordHeader(offset: Int, remaining: Int)
    /// The walk consumed the whole buffer without encountering META_EOF.
    case missingEOF
    /// Bytes remained after the META_EOF record. `count` is how many.
    case trailingBytesAfterEOF(count: Int)
    /// The walk hit its record-count cap and stopped, keeping every record
    /// parsed so far. `limit` is the cap that was reached. Rationale mirrors the
    /// EMF walker's cap: a crafted file of nothing but 6-byte records would
    /// otherwise inflate an unbounded record array and could jetsam a sandboxed
    /// Quick Look extension mid-parse (§8).
    case recordCountCapped(limit: Int)
    /// The header's advisory whole-metafile size (`SizeLow`/`SizeHigh`, in
    /// bytes) disagreed with the bytes the walk covered from the META_HEADER
    /// onward (the placeable wrapper is excluded, as it is not part of the
    /// metafile proper). Both in bytes.
    case metafileSizeMismatch(headerSays: Int, walked: Int)
    /// The header's advisory `MaxRecord` (in WORDs) disagreed with the largest
    /// record the walk actually saw (in WORDs).
    case maxRecordMismatch(headerSays: UInt32, walked: Int)
    /// The placeable header's stored checksum disagreed with the XOR of the
    /// first ten header WORDs ([MS-WMF] §2.3.2.3). Advisory only — real files
    /// miscompute it — so the file is still parsed as a placeable WMF.
    case placeableChecksumMismatch(stored: UInt16, computed: UInt16)
}
