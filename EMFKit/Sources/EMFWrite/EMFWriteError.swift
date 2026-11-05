import Foundation
import EMFParse

/// Why serialising an EMF failed. Writer failures are always typed — never a
/// trap — mirroring the parse side's discipline: a count that overflows a
/// UInt32 size field, an object index that overflows the UInt16 handle table,
/// or a payload that has no EMF record form in this slice all return one of
/// these rather than aborting the process (v3 plan §11.2; primer §8 applies to
/// every byte read back from a parsed file during re-emit).
public enum EMFWriteError: Error, Sendable, Equatable {
    /// A record's total byte length would not fit a UInt32 `nSize` field. Only
    /// reachable from a pathological (hostile) input whose declared counts the
    /// parser accepted; a from-scratch builder never produces one.
    /// `recordType` is the EMF record type, `byteLength` the length attempted.
    case recordTooLarge(recordType: UInt32, byteLength: Int)
    /// The whole file's byte length would not fit the header's UInt32 `Bytes`
    /// field. `byteLength` is the length attempted.
    case fileTooLarge(byteLength: Int)
    /// An object-table index would not fit the header's UInt16 `Handles` field
    /// (the handle table is indexed 1…65534; index 0 is reserved). `index` is
    /// the offending object index found while recomputing the table size.
    case objectTableOverflow(index: UInt32)
    /// The `source` bytes handed to a re-emit did not contain a record the
    /// `EMFFile` says is there — the file and its source bytes do not match, or
    /// the source was truncated. `recordOffset` and `recordSize` are the record
    /// the walker recorded.
    case sourceRecordOutOfBounds(recordOffset: Int, recordSize: UInt32)
    /// A string field exceeded the record's own count field during a
    /// from-scratch build (an EmrText or LogFont whose UTF-16 length overflows
    /// the UInt32/fixed field). `recordType` and `codeUnits` describe it.
    case stringTooLong(recordType: UInt32, codeUnits: Int)
    /// A payload case has no EMF record form in this slice — e.g. a WMF-sourced
    /// primitive (`.patBlt`) routed to the EMF writer rather than the WMF writer
    /// (E0c). Carries a short label for diagnosis.
    case unsupportedPayload(label: String)
}
