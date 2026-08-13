import Foundation

/// One EMF+ record walked out of the reassembled EMR_COMMENT_EMFPLUS stream
/// ([MS-EMFPLUS] §2.3). Every EMF+ record opens with a 12-byte header —
/// `Type` (u16), `Flags` (u16), `Size` (u32), `DataSize` (u32), little-endian —
/// followed by `DataSize` bytes of record-specific `RecordData`.
///
/// This is the inventory-level view every EMF+ record shares; phase 1 does not
/// decode record bodies. A single logical EMF+ record routinely spans
/// consecutive EMR_COMMENT_EMFPLUS records, so `data` is taken from the one
/// reassembled, contiguous stream buffer (see `EMFFile.emfPlusStream()`).
public struct EMFPlusRecord: Sendable, Equatable {
    /// `Type`: the 16-bit record-type identifier ([MS-EMFPLUS] §2.1.1.1). Any
    /// value is accepted; resolve a name with `typeName` / `displayName`.
    public var type: UInt16
    /// `Flags`: the raw 16-bit flags word. Meaning is record-specific (for
    /// example the EmfPlusHeader dual bit, §2.3.3.3); phase 1 keeps it verbatim.
    public var flags: UInt16
    /// `Size`: the record's declared total size in bytes, including the 12-byte
    /// header. Validated (>= 12, a multiple of 4) before the record is admitted.
    public var declaredSize: UInt32
    /// `DataSize`: the declared length of `data`, excluding the 12-byte header.
    /// Validated (<= `declaredSize` - 12, and fully present) before admission.
    public var declaredDataSize: UInt32
    /// The `RecordData` bytes: exactly `declaredDataSize` bytes, reassembled to
    /// be contiguous even when the source stream was fragmented across
    /// consecutive comments.
    ///
    /// This is a slice over the one assembled stream buffer, not a fresh copy,
    /// so it may carry a non-zero `startIndex`. Read it with a start-index-safe
    /// reader (e.g. `ByteReader(record.data)`) rather than integer-subscripting
    /// from 0 — the same hazard `ByteReader` exists to neutralise.
    public var data: Data

    /// The `EMFFile.records` index of the EMR_COMMENT_EMFPLUS record in which
    /// this record's 12-byte header begins. When the header itself straddles
    /// consecutive comments, this is the comment that contributed the header's
    /// FIRST byte.
    ///
    /// EMF+ playback walks `EMFFile.records` in file order so a GDI window
    /// opened by EmfPlusGetDC can play the interleaved GDI records until the
    /// next EMF+ record of any type ([MS-EMFPLUS] §1.3.1); reassembly across
    /// comment boundaries would otherwise discard where each EMF+ record sits
    /// relative to that GDI sequence. Always indexes a `type == 70` record.
    public let sourceRecordIndex: Int

    public init(
        type: UInt16,
        flags: UInt16,
        declaredSize: UInt32,
        declaredDataSize: UInt32,
        data: Data,
        sourceRecordIndex: Int
    ) {
        self.type = type
        self.flags = flags
        self.declaredSize = declaredSize
        self.declaredDataSize = declaredDataSize
        self.data = data
        self.sourceRecordIndex = sourceRecordIndex
    }

    /// Verified [MS-EMFPLUS] §2.1.1.1 name (e.g. `"EmfPlusHeader"`), or `nil`
    /// when `type` is not a defined record type.
    public var typeName: String? { EMFPlusRecordType.name(for: type) }

    /// The verified name, or the raw type as four-digit hex when undefined —
    /// the label tooling prints for every record.
    public var displayName: String { EMFPlusRecordType.displayName(for: type) }

    /// True when this is an EMF+ drawing record ([MS-EMFPLUS] §2.3.4). See
    /// `EMFPlusRecordType.isDrawing(_:)` for the exact membership and its
    /// deliberate divergence from `EMFPlusPresence` over 0x4037.
    public var isDrawing: Bool { EMFPlusRecordType.isDrawing(type) }
}
