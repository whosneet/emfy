import Foundation

/// One record located during the walk, described by its header fields and its
/// position in the file. The body is not decoded at phase 1 — this is the
/// inventory-level view every record shares ([MS-EMF] §2.3: each record opens
/// with `Type` (u32) then `Size` (u32), little-endian).
public struct EMFRawRecord: Sendable, Equatable {
    /// `iType`: the record-type identifier. Any value is accepted; use
    /// `EMFRecordType.name(for:)` to resolve a name where one is defined.
    public var type: UInt32
    /// `nSize`: the total record size in bytes, including the 8-byte header.
    /// Validated (>= 8, multiple of 4, within the buffer) before the record
    /// is admitted.
    public var size: UInt32
    /// Byte offset of this record's first byte (its `Type` field) from the
    /// start of the file.
    public var offset: Int

    public init(type: UInt32, size: UInt32, offset: Int) {
        self.type = type
        self.size = size
        self.offset = offset
    }

    /// Byte offset of this record's payload — the bytes after the 8-byte
    /// `Type`/`Size` header. Equal to `offset + 8`. Payload length is
    /// `Int(size) - 8`. Body bytes are extracted lazily by later phases via
    /// the file's backing buffer; phase 1 records only their location.
    public var payloadOffset: Int { offset + 8 }
}
