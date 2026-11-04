import Foundation

/// One generic WMF record located during the walk ([MS-WMF] §2.3): every
/// record except the control (header) records opens with `RecordSize` (u32,
/// a count of 16-bit WORDs INCLUDING the 6-byte record header) then
/// `RecordFunction` (u16).
public struct WMFRawRecord: Sendable, Equatable {
    /// `RecordFunction`: the record-type identifier. Any value is accepted;
    /// resolve a name via `WMFRecordType.name(for:)` where one is defined.
    public var function: UInt16
    /// `RecordSize`: the record size in 16-bit WORDs, header included.
    /// Validated (>= 3, and `size * 2` within the buffer) before admission.
    public var sizeWords: UInt32
    /// Byte offset of this record's first byte (its `RecordSize` field) from
    /// the start of the file.
    public var offset: Int

    public init(function: UInt16, sizeWords: UInt32, offset: Int) {
        self.function = function
        self.sizeWords = sizeWords
        self.offset = offset
    }

    /// The record's total size in bytes (`RecordSize` × 2). `sizeWords` is
    /// validated `>= 3` and bounded by the file before the record is admitted,
    /// so `Int(sizeWords) * 2` is in range and cannot overflow a 64-bit `Int`.
    public var byteSize: Int { Int(sizeWords) * 2 }

    /// Byte offset of this record's `rdParam` payload — the bytes after the
    /// 6-byte `RecordSize`/`RecordFunction` header. Equal to `offset + 6`.
    public var payloadOffset: Int { offset + 6 }

    /// Length in bytes of the `rdParam` payload (`byteSize - 6`, always >= 0
    /// for an admitted record).
    public var payloadByteCount: Int { byteSize - 6 }
}
