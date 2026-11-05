import Foundation
import EMFParse

/// Builds a complete EMF document from a parsed `EMFFile` — the re-emit entry
/// point (v3 plan §11.2, E0a entry (a)). Each body record is typed-encoded when
/// `EMFRecordEncoder.isFaithfullyEncodable` says the decoder round-trips it, and
/// otherwise re-emitted from its original source bytes (unknown records,
/// `.unsupported` DIBs, extended fonts, pattern-DIB pens). The EMR_HEADER's
/// Bytes and Records are recomputed from what was actually written and never
/// trusted from the input, and Handles is raised to the computed table size but
/// never lowered below the declared value (header advisory fields, primer §8 /
/// delta D4); every other header byte — bounds, frame, device, millimetres,
/// description, pixel-format fields — is preserved verbatim by patching only
/// those three fields in the original header record.
public enum EMFDocumentWriter {

    /// Re-emits `file` as a fresh EMF byte stream. `source` MUST be the bytes
    /// `file` was parsed from: records the writer does not typed-encode are
    /// sliced from it (every slice is bounds-checked, so a mismatched or
    /// truncated `source` yields a typed error, never a trap).
    ///
    /// The result re-parses to a record stream equal to `file`'s (same count and
    /// order; typed payloads equal; passthrough bytes identical) with a header
    /// whose Bytes/Records/Handles are now correct for the bytes written.
    ///
    /// With `repackageEMFPlus` set, the parsed EMF+ stream is rebuilt through the
    /// EMF+ encoder instead of passed through: each source EMR_COMMENT_EMFPLUS
    /// that ANCHORS EMF+ records (its `sourceRecordIndex`) is replaced in place by
    /// freshly framed comment(s) carrying those records, and the tail-only EMF+
    /// comments it spilled into are dropped (their bytes are now in the anchor
    /// comment). GDI records, non-EMF+ comments and the comment POSITIONS are
    /// preserved, so the GetDC interleaving a dual file relies on survives, the
    /// reassembled EMF+ record stream is equal (type/flags/data), and
    /// `emfPlusIsDual()` is unchanged. Default `false` keeps E0a behaviour and
    /// every existing re-emit test byte-for-byte identical.
    public static func reEmit(
        _ file: EMFFile,
        source: Data,
        repackageEMFPlus: Bool = false
    ) throws(EMFWriteError) -> Data {
        let src = [UInt8](source)

        // The header record is always records[0] after a successful parse.
        let headerRecord = file.records[0]
        var headerBytes = try rawRecordBytes(src, headerRecord)

        let body: (chunks: [[UInt8]], recordCount: Int)
        if repackageEMFPlus {
            body = try repackagedBody(file, src: src)
        } else {
            body = try passthroughBody(file, src: src)
        }
        let bodyChunks = body.chunks

        let bodyTotal = bodyChunks.reduce(0) { $0 + $1.count }
        let totalBytes = headerBytes.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else {
            throw .fileTooLarge(byteLength: totalBytes)
        }
        // Record count is bounded by the walker's 1,000,000 cap, so it always
        // fits a UInt32; computed defensively all the same.
        let recordCount = UInt32(clamping: body.recordCount)
        // Handles is recomputed from the raw record stream (not the decoded
        // payloads): object-creation records the EMF decoder does not decode —
        // EMR_CREATEPALETTE, EMR_CREATEMONOBRUSH, … — still consume table slots,
        // and all creation/reference records carry their handle index as the
        // first body field at offset 8 ([MS-EMF] §2.3.7/§2.3.8). Re-emit only
        // RAISES an under-declared table — it never lowers one: shrinking an
        // over-declaration gains nothing, and were the simulation ever to miss an
        // object-creating record it would under-declare and another reader could
        // fail on an out-of-range handle. The header `Handles` value is the table
        // SIZE (not an exact count), so taking the larger is always safe.
        let computedHandles = try computeHandleCountRaw(src, file.records)
        let handleCount = max(file.header.handles, computedHandles)

        patchUInt32(&headerBytes, at: 48, UInt32(totalBytes))  // Bytes
        patchUInt32(&headerBytes, at: 52, recordCount)         // Records
        patchUInt16(&headerBytes, at: 56, handleCount)         // Handles

        var out: [UInt8] = []
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: headerBytes)
        for chunk in bodyChunks {
            out.append(contentsOf: chunk)
        }
        return Data(out)
    }

    // MARK: - Body builders

    /// The E0a body: every record[1…] typed-encoded when faithful, else sliced
    /// from `src` verbatim. Record count is the walked count (header included).
    private static func passthroughBody(
        _ file: EMFFile,
        src: [UInt8]
    ) throws(EMFWriteError) -> (chunks: [[UInt8]], recordCount: Int) {
        var chunks: [[UInt8]] = []
        guard file.records.count > 1 else { return (chunks, file.records.count) }
        chunks.reserveCapacity(file.records.count - 1)
        for index in 1 ..< file.records.count {
            let record = file.records[index]
            let payload = file.payload(of: record)
            if EMFRecordEncoder.isFaithfullyEncodable(payload) {
                chunks.append([UInt8](try EMFRecordEncoder.encode(payload)))
            } else {
                chunks.append(try rawRecordBytes(src, record))
            }
        }
        return (chunks, file.records.count)
    }

    /// The repackage body: EMF+ comments rebuilt through the EMF+ encoder (see
    /// `reEmit(_:source:repackageEMFPlus:)`), everything else as passthrough.
    private static func repackagedBody(
        _ file: EMFFile,
        src: [UInt8]
    ) throws(EMFWriteError) -> (chunks: [[UInt8]], recordCount: Int) {
        let plus = file.emfPlusStream()
        // No EMF+ content: nothing to repackage — identical to passthrough.
        guard !plus.records.isEmpty else { return try passthroughBody(file, src: src) }

        // Group every reassembled EMF+ record by the comment its header started in.
        var grouped: [Int: [EMFPlusRecord]] = [:]
        for record in plus.records {
            grouped[record.sourceRecordIndex, default: []].append(record)
        }

        var chunks: [[UInt8]] = []
        var recordCount = 1   // header
        guard file.records.count > 1 else { return (chunks, recordCount) }
        for index in 1 ..< file.records.count {
            let record = file.records[index]
            if record.type == emrCommentType {
                if let group = grouped[index] {
                    // Anchor comment: re-frame its records and re-pack into comment(s).
                    var stream: [UInt8] = []
                    for plusRecord in group {
                        stream.append(contentsOf: EMFPlusCommentWriter.frame(plusRecord))
                    }
                    chunks.append(EMFPlusCommentWriter.packComments(streamBytes: stream))
                    recordCount += emfPlusCommentCount(streamByteCount: stream.count)
                } else if isEMFPlusComment(src, record) {
                    // Tail-only EMF+ comment: its bytes moved to the anchor — drop it.
                    continue
                } else {
                    // A non-EMF+ comment (public/GDIC): preserve verbatim.
                    chunks.append(try rawRecordBytes(src, record))
                    recordCount += 1
                }
            } else {
                let payload = file.payload(of: record)
                if EMFRecordEncoder.isFaithfullyEncodable(payload) {
                    chunks.append([UInt8](try EMFRecordEncoder.encode(payload)))
                } else {
                    chunks.append(try rawRecordBytes(src, record))
                }
                recordCount += 1
            }
        }
        return (chunks, recordCount)
    }

    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    private static let emrCommentType: UInt32 = 70

    /// Whether `record` is an EMR_COMMENT_EMFPLUS: DataSize (at offset 8) is at
    /// least 4 and the CommentIdentifier (at offset 12) is "EMF+" — the same test
    /// `EMFFile.emfPlusPresence` applies, read defensively from `src`.
    private static func isEMFPlusComment(_ src: [UInt8], _ record: EMFRawRecord) -> Bool {
        let base = record.offset
        guard record.size >= 16, base >= 0, base <= src.count - 16 else { return false }
        func u32(_ at: Int) -> UInt32 {
            UInt32(src[at]) | (UInt32(src[at + 1]) << 8) | (UInt32(src[at + 2]) << 16) | (UInt32(src[at + 3]) << 24)
        }
        return u32(base + 8) >= 4 && u32(base + 12) == EMFPlusCommentWriter.emfPlusIdentifier
    }

    /// The comment-record count `packComments` emits for a run (mirrors its
    /// per-`maxCommentPayload`-slice loop).
    private static func emfPlusCommentCount(streamByteCount: Int) -> Int {
        guard streamByteCount > 0 else { return 0 }
        let limit = max(4, EMFPlusCommentWriter.defaultMaxCommentPayload & ~3)
        return (streamByteCount + limit - 1) / limit
    }

    // MARK: - Shared internals (used by EMFDocumentBuilder too)

    /// The exact source bytes of one walked record (§8 bounds-checked). A record
    /// the `EMFFile` claims exists but whose range falls outside `src` is a
    /// mismatch between `file` and `source` — a typed error, never a trap.
    static func rawRecordBytes(
        _ src: [UInt8],
        _ record: EMFRawRecord
    ) throws(EMFWriteError) -> [UInt8] {
        let start = record.offset
        let size = Int(record.size)
        guard start >= 0, size >= 0, size <= src.count, start <= src.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: record.size)
        }
        return Array(src[start ..< start + size])
    }

    /// The handle-table size (header `Handles`): one past the largest object
    /// table index any record creates, selects, or deletes, with a floor of 1
    /// (index 0 is reserved). Stock objects (high bit set) are built-in and
    /// never table entries. Overflows the UInt16 field → typed error.
    static func computeHandleCount(
        _ payloads: [EMFRecordPayload]
    ) throws(EMFWriteError) -> UInt16 {
        var maxIndex: UInt32 = 0
        var sawAny = false
        for payload in payloads {
            for raw in tableIndices(of: payload) {
                sawAny = true
                if raw > maxIndex { maxIndex = raw }
            }
        }
        guard sawAny else { return 1 }
        // tableIndices only yields values with the stock bit clear, so
        // maxIndex <= 0x7FFF_FFFF and the increment cannot overflow.
        let count = maxIndex + 1
        guard count <= UInt32(UInt16.max) else {
            throw .objectTableOverflow(index: maxIndex)
        }
        return UInt16(count)
    }

    /// Record types that put an object-table handle in their first body field
    /// (record offset 8): the creation records ([MS-EMF] §2.3.7 — pen, brush,
    /// font, palette, mono/DIB-pattern brush, colour space) and the
    /// select/delete references (§2.3.8). The EMF decoder decodes only some of
    /// these, so the handle recompute reads the field straight from the bytes.
    /// Internal (not private) so `EMFDocumentBuilder.appendRaw` can fold a
    /// passthrough record's handle index into its table-size recompute.
    static let handleFieldTypes: Set<UInt32> = [
        37,  // EMR_SELECTOBJECT
        38,  // EMR_CREATEPEN
        39,  // EMR_CREATEBRUSHINDIRECT
        40,  // EMR_DELETEOBJECT
        49,  // EMR_CREATEPALETTE
        82,  // EMR_EXTCREATEFONTINDIRECTW
        93,  // EMR_CREATEMONOBRUSH
        94,  // EMR_CREATEDIBPATTERNBRUSHPT
        95,  // EMR_EXTCREATEPEN
        99,  // EMR_CREATECOLORSPACE
        122, // EMR_CREATECOLORSPACEW
    ]

    /// The handle-table size recomputed from the raw record stream: one past the
    /// largest object-table index any creation/reference record names, floor 1.
    /// Stock handles (high bit set) are filtered out. A record too short to hold
    /// the field is skipped. Overflows the UInt16 field → typed error.
    static func computeHandleCountRaw(
        _ src: [UInt8],
        _ records: [EMFRawRecord]
    ) throws(EMFWriteError) -> UInt16 {
        var maxIndex: UInt32 = 0
        var sawAny = false
        for record in records where handleFieldTypes.contains(record.type) {
            let fieldOffset = record.offset + 8
            guard record.size >= 12, fieldOffset >= 0, fieldOffset <= src.count - 4 else { continue }
            let raw = UInt32(src[fieldOffset])
                | (UInt32(src[fieldOffset + 1]) << 8)
                | (UInt32(src[fieldOffset + 2]) << 16)
                | (UInt32(src[fieldOffset + 3]) << 24)
            guard raw & 0x8000_0000 == 0 else { continue }   // stock object
            sawAny = true
            if raw > maxIndex { maxIndex = raw }
        }
        guard sawAny else { return 1 }
        let count = maxIndex + 1                              // maxIndex <= 0x7FFF_FFFF
        guard count <= UInt32(UInt16.max) else {
            throw .objectTableOverflow(index: maxIndex)
        }
        return UInt16(count)
    }

    /// The object-table indices a payload references (empty for non-object
    /// records). Stock-object references are filtered out — they are not table
    /// entries ([MS-EMF] §2.1.31).
    private static func tableIndices(of payload: EMFRecordPayload) -> [UInt32] {
        func tableOnly(_ raw: UInt32) -> [UInt32] {
            raw & 0x8000_0000 == 0 ? [raw] : []
        }
        switch payload {
        case .createPen(let p): return tableOnly(p.ihPen)
        case .extCreatePen(let p): return tableOnly(p.ihPen)
        case .createBrushIndirect(let p): return tableOnly(p.ihBrush)
        case .extCreateFontIndirectW(let p): return tableOnly(p.ihFonts)
        case .selectObject(let handle), .deleteObject(let handle):
            if case .table(let index) = handle { return tableOnly(index) }
            return []
        default:
            return []
        }
    }

    /// A canonical EMR_HEADER ([MS-EMF] §2.3.4.2) with the HeaderExtension2
    /// variant (108-byte fixed part, §2.2.9–2.2.11) and an optional UTF-16LE
    /// description right after it. Used by the from-scratch builder; re-emit
    /// preserves the original header instead. `bytes`/`records`/`handles` are
    /// the recomputed accounting fields.
    static func encodeCanonicalHeader(
        bounds: RectL,
        frame: RectL,
        device: SizeL,
        millimeters: SizeL,
        description: String?,
        bytes: UInt32,
        records: UInt32,
        handles: UInt16
    ) -> [UInt8] {
        let descUnits: [UInt16] = description.map { Array($0.utf16) } ?? []
        let nDescription = UInt32(clamping: descUnits.count)
        let fixedSize = 108
        let offDescription: UInt32 = descUnits.isEmpty ? 0 : UInt32(fixedSize)

        var b = ByteWriter()
        b.appendUInt32(1)                                  // @0  iType = EMR_HEADER
        // nSize patched below once the description padding is known.
        b.appendUInt32(0)                                  // @4  nSize placeholder
        b.appendRectL(bounds)                              // @8  rclBounds
        b.appendRectL(frame)                               // @24 rclFrame
        b.appendUInt32(0x464D_4520)                        // @40 RecordSignature " EMF"
        b.appendUInt32(0x0001_0000)                        // @44 Version
        b.appendUInt32(bytes)                              // @48 Bytes
        b.appendUInt32(records)                            // @52 Records
        b.appendUInt16(handles)                            // @56 Handles
        b.appendUInt16(0)                                  // @58 Reserved
        b.appendUInt32(nDescription)                       // @60 nDescription
        b.appendUInt32(offDescription)                     // @64 offDescription
        b.appendUInt32(0)                                  // @68 nPalEntries
        b.appendSizeL(device)                              // @72 Device
        b.appendSizeL(millimeters)                         // @80 Millimeters
        b.appendUInt32(0)                                  // @88 cbPixelFormat
        b.appendUInt32(0)                                  // @92 offPixelFormat
        b.appendUInt32(0)                                  // @96 bOpenGL
        b.appendUInt32(0)                                  // @100 MicrometersX
        b.appendUInt32(0)                                  // @104 MicrometersY
        for unit in descUnits {                            // @108 description
            b.appendUInt16(unit)
        }
        b.padTo4()

        var headerBytes = b.bytes
        patchUInt32(&headerBytes, at: 4, UInt32(clamping: headerBytes.count))  // nSize
        return headerBytes
    }

    /// A canonical EMR_EOF record ([MS-EMF] §2.3.4.1) with no palette: 20 bytes,
    /// nPalEntries 0, offPalEntries 0x10, SizeLast 20. Matches the form GDI
    /// writes (and every committed corpus file's trailer).
    static func encodeEOF() -> [UInt8] {
        var b = ByteWriter()
        b.appendUInt32(14)       // Type = EMR_EOF
        b.appendUInt32(20)       // Size
        b.appendUInt32(0)        // nPalEntries
        b.appendUInt32(0x10)     // offPalEntries
        b.appendUInt32(20)       // SizeLast
        return b.bytes
    }
}
