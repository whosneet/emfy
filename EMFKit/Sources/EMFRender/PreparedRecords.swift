import EMFParse
import Foundation
import WMFParse

// MARK: - Record inspector bridge (F5b)
//
// A purely additive, read-only bridge from a prepared metafile to the record
// inspector's engine (F5a): the per-record list, the one-line parameter
// summaries, the checkpointed step-through player, and the DC state after a
// record. Nothing here changes existing behaviour — a full render stays
// byte-identical, and these accessors only re-expose already-decoded values.
//
// EMF content (a standalone `.emf`, or a WMF's played-back embedded EMF, where
// `Prepared` holds an `EMFFile`) supports the whole feature. A WMF program
// (`.wmfProgram`) supports only the record LIST — META_* names, offsets and
// sizes — because the GDI step-through engine replays an `EMFFile`, which a
// translated WMF program is not; its summariser is a later carry-in.

/// One row of the record inspector's list: the record's position, its resolved
/// type name, and its byte span. `isEMFPlusCarrier` marks an EMR_COMMENT that
/// carries EMF+ records, with `emfPlusRecordCount` the number it carries, so the
/// inspector can show "EMF+ (n records)" when it does not nest them.
public struct RecordRef: Sendable, Equatable {
    /// The record's index in the file's record list (0 is EMR_HEADER for EMF).
    public let index: Int
    /// The resolved record-type name (EMR_* for EMF, META_* for WMF), or an
    /// "Unknown (…)" label when the type id is not defined.
    public let typeName: String
    /// Byte offset of the record's first byte from the start of the file.
    public let offset: Int
    /// The record's total size in bytes.
    public let size: Int
    /// True when this record is an EMR_COMMENT that carries EMF+ records
    /// ([MS-EMF] §2.3.3.4). Always false for WMF.
    public let isEMFPlusCarrier: Bool
    /// The number of EMF+ records this carrier contributes to the reassembled
    /// EMF+ stream (0 for a non-carrier).
    public let emfPlusRecordCount: Int

    public init(
        index: Int,
        typeName: String,
        offset: Int,
        size: Int,
        isEMFPlusCarrier: Bool,
        emfPlusRecordCount: Int
    ) {
        self.index = index
        self.typeName = typeName
        self.offset = offset
        self.size = size
        self.isEMFPlusCarrier = isEMFPlusCarrier
        self.emfPlusRecordCount = emfPlusRecordCount
    }
}

extension MetafileRenderer.Prepared {

    /// A step-through player for the record inspector, or `nil` when stepping is
    /// not available because this metafile is a translated WMF program rather
    /// than an `EMFFile` (the GDI step-through engine replays `EMFFile` records).
    /// A `MetafilePartialPlayer`'s own `supportsPartial` then says whether an
    /// EMF+ drawing file steps or renders in full.
    public func makePartialPlayer(
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default
    ) -> MetafilePartialPlayer? {
        guard case .emf(let file) = content else { return nil }
        return MetafilePartialPlayer(file: file, scale: scale, background: background, options: options)
    }

    /// The record inspector's list rows, in file order. EMF: every record from
    /// the decoded file, named with `EMFRecordType.name`, with EMF+ carriers
    /// flagged and counted. WMF program: every source WMF record, named with
    /// `WMFRecordType.name` (offsets and sizes retained). Bounded: the per-record
    /// arrays were already capped during the §8 walk.
    public func recordRefs() -> [RecordRef] {
        switch content {
        case .emf(let file):
            // Per-carrier EMF+ counts, so a carrier row can read "EMF+ (n records)".
            // `emfPlusStream()` is the bounded reassembly walk; it returns empty for
            // a pure-GDI file. Counting is O(records) with a small dictionary.
            var carrierCounts: [Int: Int] = [:]
            for record in file.emfPlusStream().records {
                carrierCounts[record.sourceRecordIndex, default: 0] += 1
            }
            return file.records.enumerated().map { index, record in
                let count = carrierCounts[index] ?? 0
                return RecordRef(
                    index: index,
                    typeName: EMFRecordType.name(for: record.type) ?? "Unknown (type \(record.type))",
                    offset: record.offset,
                    size: Int(record.size),
                    isEMFPlusCarrier: count > 0,
                    emfPlusRecordCount: count
                )
            }
        case .wmfProgram:
            return wmfRecordRefList
        }
    }

    /// The one-line parameter summary for the record at `index`, or `nil` for a
    /// WMF program (whose summariser is a later carry-in). Pure and non-trapping:
    /// it decodes the record on demand via the §8-bounded payload path. An
    /// out-of-range index returns `""`.
    public func recordSummary(at index: Int) -> String? {
        guard case .emf(let file) = content else { return nil }
        return file.recordSummary(at: index)
    }

    /// The DC state AFTER playing through `throughRecordIndex`, for the inspector's
    /// DC panel, or `nil` for a WMF program (no `EMFFile` to replay). The index is
    /// clamped to the record range.
    public func playbackState(
        throughRecordIndex limit: Int,
        options: RenderOptions = .default
    ) -> PlaybackState? {
        guard case .emf(let file) = content else { return nil }
        return EMFRenderer.playbackState(of: file, throughRecordIndex: limit, options: options)
    }

    /// Builds the record-list rows for a translated WMF program from its source
    /// `WMFFile` records ([MS-WMF] §2.3): META_* names, byte offsets, and sizes
    /// (`sizeWords` × 2 bytes). Called once at prepare time, where the `WMFFile`
    /// is in scope, since the program itself keeps only translated payloads.
    static func wmfRecordRefs(_ file: WMFFile) -> [RecordRef] {
        file.records.enumerated().map { index, record in
            RecordRef(
                index: index,
                typeName: WMFRecordType.name(for: record.function)
                    ?? String(format: "Unknown (function 0x%04X)", record.function),
                offset: record.offset,
                size: Int(record.sizeWords) * 2,
                isEMFPlusCarrier: false,
                emfPlusRecordCount: 0
            )
        }
    }
}
