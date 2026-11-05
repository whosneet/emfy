import Foundation

/// Why serialising a WMF failed. Like `EMFWriteError`, every writer failure is
/// typed — never a trap — and names the overflow that a 16-bit metafile makes
/// easy to hit: a logical coordinate that does not fit the record's Int16 field,
/// a point/polygon count that does not fit its 16-bit count field, a string or
/// escape blob longer than its length field can describe, an object slot past the
/// header's UInt16 `NumberOfObjects`, or a whole file past the header's 32-bit
/// WORD size (v3 plan §11.1; primer §8 applies to every value narrowed on the way
/// to the on-disk form).
public enum WMFWriteError: Error, Sendable, Equatable {
    /// A logical coordinate (point, size, or rectangle edge) did not fit the
    /// Int16 field a WMF record stores it in ([MS-WMF] §2.2.2.15/.16/.19 — WMF
    /// geometry is 16-bit). `value` is the offending Int32.
    case coordinateOutOfRange(value: Int32)
    /// An array count did not fit its on-disk field: a POLYLINE/POLYGON
    /// `NumberOfPoints` (Int16), a POLYPOLYGON `NumberOfPolygons`/per-polygon
    /// count (UInt16), or an EXTTEXTOUT `Dx` length. `field` names it.
    case countOutOfRange(field: String, count: Int)
    /// A TEXTOUT/EXTTEXTOUT string was longer than the Int16 `StringLength`
    /// field ([MS-WMF] §2.3.3.20/.5). `byteCount` is the 8-bit-encoded length.
    case stringTooLong(byteCount: Int)
    /// A META_ESCAPE `EscapeData` blob exceeded the UInt16 `ByteCount` field
    /// ([MS-WMF] §2.3.6.1). `byteCount` is the length attempted.
    case escapeDataTooLarge(byteCount: Int)
    /// A record's total size in 16-bit WORDs overflowed the UInt32 `RecordSize`
    /// field ([MS-WMF] §2.3). Only reachable from a pathological body; a
    /// from-scratch record never produces one. `function` is the RecordFunction.
    case recordTooLarge(function: UInt16, byteCount: Int)
    /// The object table grew past the header's UInt16 `NumberOfObjects` field
    /// ([MS-WMF] §2.3.2.2 / §3.1.4.1). `slot` is the 0-based index that
    /// overflowed.
    case objectTableOverflow(slot: Int)
    /// The whole metafile's size in 16-bit WORDs overflowed the header's 32-bit
    /// `SizeLow`/`SizeHigh` pair ([MS-WMF] §2.3.2.2). `byteCount` is the length.
    case fileTooLarge(byteCount: Int)
    /// During a re-emit, a record the `WMFFile` says is present fell outside the
    /// source bytes — the file and its source do not match, or the source was
    /// truncated. `recordOffset`/`recordSize` are what the walker recorded.
    case sourceRecordOutOfBounds(recordOffset: Int, recordSize: Int)
}
