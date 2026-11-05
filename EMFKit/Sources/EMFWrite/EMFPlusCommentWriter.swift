import Foundation
import EMFParse

/// Packs EMF+ records into the EMR_COMMENT_EMFPLUS carrier records of an EMF file
/// ([MS-EMF] §2.3.3.4; [MS-EMFPLUS] §2.3). Three layers:
///
/// 1. `frame` lays one EMF+ record out on the wire — Type, Flags, Size, DataSize,
///    data, 4-byte AlignmentPadding ([MS-EMFPLUS] §2.3) — the inverse of the
///    `EMFPlusStream` walk.
/// 2. `objectRecords` splits one logical EmfPlusObject (id, type, payload) into
///    one or more EmfPlusObject records, applying the continuation mechanism
///    (Continuable flag + TotalObjectSize prefix, [MS-EMFPLUS] §2.3.5.1) when the
///    payload is too large for a single record.
/// 3. `packComments` wraps a run of framed EMF+ bytes into one or more
///    EMR_COMMENT_EMFPLUS records, fragmenting across comments at the payload
///    limit — the inverse of the cross-comment reassembly in `assembleEMFPlusStream`.
public enum EMFPlusCommentWriter {

    // MARK: - Constants

    /// "EMF+" little-endian ([MS-EMF] §2.3.3.4 CommentIdentifier).
    static let emfPlusIdentifier: UInt32 = 0x2B46_4D45
    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    static let commentType: UInt32 = 70
    /// EmfPlusObject record type ([MS-EMFPLUS] §2.1.1.1 / §2.3.5.1).
    static let objectRecordType: UInt16 = 0x4008
    /// EmfPlusObject Flags Continuable (C) bit ([MS-EMFPLUS] §2.3.5.1).
    static let objectContinueFlag: UInt16 = 0x8000

    /// Default cap on one EMR_COMMENT_EMFPLUS's EMF+-stream payload. A multiple of
    /// 4 (so every comment's `nSize` stays 4-aligned); large enough that the
    /// handmade files fit one comment, small enough to exercise fragmentation on
    /// big ones.
    public static let defaultMaxCommentPayload = 0x4000
    /// Default cap on one EmfPlusObject record's DataSize before continuation
    /// splitting kicks in ([MS-EMFPLUS] §2.3.5.1). A multiple of 4.
    public static let defaultMaxObjectDataSize = 0x4000

    // MARK: - Record framing

    /// One EMF+ record's wire bytes: Type (u16), Flags (u16), Size (u32),
    /// DataSize (u32), then `data`, then 0–3 AlignmentPadding bytes so Size is a
    /// multiple of 4 ([MS-EMFPLUS] §2.3). `Size` is the padded total; `DataSize`
    /// is `data.count`. Reversed exactly by `EMFPlusStream.walkAssembledStream`.
    public static func frame(type: UInt16, flags: UInt16, data: [UInt8]) -> [UInt8] {
        let dataSize = data.count
        let unpadded = 12 + dataSize
        let size = (unpadded + 3) & ~3
        var w = ByteWriter(capacity: size)
        w.appendUInt16(type)
        w.appendUInt16(flags)
        w.appendUInt32(UInt32(clamping: size))
        w.appendUInt32(UInt32(clamping: dataSize))
        w.appendBytes(data)
        w.appendZeros(size - unpadded)
        return w.bytes
    }

    /// Frames a parsed `EMFPlusRecord` from its Type, Flags and reassembled data,
    /// recomputing Size/DataSize canonically. Used by the re-emit repackage path —
    /// a record that spanned comments in the source is re-laid as one framed record.
    public static func frame(_ record: EMFPlusRecord) -> [UInt8] {
        frame(type: record.type, flags: record.flags, data: [UInt8](record.data))
    }

    // MARK: - Object records + continuation ([MS-EMFPLUS] §2.3.5.1)

    /// One logical EmfPlusObject as one or more framed EmfPlusObject records.
    ///
    /// The Flags word packs the Continuable bit (15), ObjectType (bits 8–14, a
    /// 7-bit field) and ObjectID (bits 0–7) exactly as `objectDefinitions()` reads
    /// them. A payload that fits one record (`<= maxObjectDataSize`) is emitted
    /// with C clear and no TotalObjectSize prefix. A larger payload is split into
    /// chunks: every chunk sets C and carries a 4-byte TotalObjectSize prefix
    /// (the whole payload length), and contributes `DataSize − 4` object bytes;
    /// the reassembly completes once the accumulated object bytes reach
    /// TotalObjectSize (C is advisory, so it stays set on the final chunk too).
    public static func objectRecords(
        objectID: UInt8,
        objectType: EMFPlusObjectType,
        payload: [UInt8],
        maxObjectDataSize: Int = defaultMaxObjectDataSize
    ) -> [[UInt8]] {
        let baseFlags = UInt16(objectType.rawValue & 0x7F) << 8 | UInt16(objectID)
        let maxData = max(8, maxObjectDataSize)   // room for the 4-byte prefix + at least 4 data bytes

        if payload.count <= maxData {
            return [frame(type: objectRecordType, flags: baseFlags, data: payload)]
        }

        // Continuation: each chunk's DataSize is 4 (TotalObjectSize prefix) plus up
        // to `maxData − 4` object bytes.
        let total = UInt32(clamping: payload.count)
        let chunkBytes = maxData - 4
        var records: [[UInt8]] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkBytes, payload.count)
            var data = ByteWriter(capacity: 4 + (end - offset))
            data.appendUInt32(total)
            data.appendBytes(Array(payload[offset ..< end]))
            records.append(frame(type: objectRecordType, flags: baseFlags | objectContinueFlag, data: data.bytes))
            offset = end
        }
        return records
    }

    // MARK: - Comment packing

    /// Wraps a run of already-framed EMF+ record bytes into one or more
    /// EMR_COMMENT_EMFPLUS records, fragmenting at `maxCommentPayload`
    /// ([MS-EMF] §2.3.3.4). Each comment: Type 70, Size, DataSize (= 4 + its
    /// stream-byte slice), the "EMF+" identifier, then the slice. `streamBytes`
    /// (a concatenation of `frame` outputs) is a multiple of 4, so every slice —
    /// hence every comment's Size — stays 4-aligned. Reverses
    /// `assembleEMFPlusStream`: concatenating the comments' payloads rebuilds the
    /// original stream regardless of where it was cut.
    public static func packComments(
        streamBytes: [UInt8],
        maxCommentPayload: Int = defaultMaxCommentPayload
    ) -> [UInt8] {
        guard !streamBytes.isEmpty else { return [] }
        // A positive multiple of 4, so comment nSize and record alignment hold.
        let limit = max(4, maxCommentPayload & ~3)
        var out: [UInt8] = []
        var offset = 0
        while offset < streamBytes.count {
            let end = min(offset + limit, streamBytes.count)
            let chunk = streamBytes[offset ..< end]
            var w = ByteWriter(capacity: 16 + chunk.count)
            w.appendUInt32(commentType)                           // @0  Type = EMR_COMMENT
            w.appendUInt32(UInt32(clamping: 16 + chunk.count))    // @4  Size = 12 header + 4 id + chunk
            w.appendUInt32(UInt32(clamping: 4 + chunk.count))     // @8  DataSize = id + chunk
            w.appendUInt32(emfPlusIdentifier)                     // @12 CommentIdentifier "EMF+"
            w.appendBytes(Array(chunk))                           // @16 EMF+ stream bytes
            out.append(contentsOf: w.bytes)
            offset = end
        }
        return out
    }
}
