import Foundation
import EMFParse

/// Builds an EMF document from scratch by appending typed records — the
/// create-a-file entry point (v3 plan §11.2, E0a entry (b)), the surface the E1
/// scene exporter will drive (an editable scene → records → bytes). It owns the
/// EMR_HEADER (a canonical HeaderExtension2 header, §2.3.4.2) and the trailing
/// EMR_EOF (§2.3.4.1), so a caller only appends the drawing records between
/// them, and it recomputes Bytes/Records/Handles from what was written.
///
/// Object handles: `allocateObjectHandle` hands out table indices 1, 2, 3, …;
/// the caller puts the returned index into the creation record it then appends
/// (e.g. `CreatePenPayload.ihPen`). `finish` sizes the handle table from the
/// indices actually used, so manual indices work too.
public final class EMFDocumentBuilder {
    private let bounds: RectL
    private let frame: RectL
    private let device: SizeL
    private let millimeters: SizeL
    private let description: String?

    /// One appended body record: a typed payload the encoder serialises, or raw
    /// bytes re-emitted verbatim (the passthrough path for records the typed
    /// encoder does not round-trip).
    private enum Item {
        case payload(EMFRecordPayload)
        case raw([UInt8])
    }

    private var items: [Item] = []
    private var nextHandle: UInt32 = 1

    /// Starts a document. `bounds` is the drawing bounds in logical units,
    /// `frame` the physical frame in 0.01 mm (drives physical size and aspect),
    /// `device`/`millimeters` the reference-device size, `description` the
    /// optional UTF-16 description string.
    public init(
        bounds: RectL,
        frame: RectL,
        device: SizeL,
        millimeters: SizeL,
        description: String? = nil
    ) {
        self.bounds = bounds
        self.frame = frame
        self.device = device
        self.millimeters = millimeters
        self.description = description
    }

    /// The next free object-table index (1-based; index 0 is reserved). Throws
    /// if the table would exceed the header's UInt16 `Handles` field.
    @discardableResult
    public func allocateObjectHandle() throws(EMFWriteError) -> UInt32 {
        guard nextHandle < UInt32(UInt16.max) else {
            throw .objectTableOverflow(index: nextHandle)
        }
        let handle = nextHandle
        nextHandle += 1
        return handle
    }

    /// Appends one drawing record. Validates eagerly: a payload with no EMF
    /// record form here (`.unimplemented`/`.malformed`/`.patBlt`, or a count
    /// that overflows a size field) throws now rather than at `finish`.
    public func append(_ payload: EMFRecordPayload) throws(EMFWriteError) {
        _ = try EMFRecordEncoder.encode(payload)   // encodability check (result re-made at finish)
        items.append(.payload(payload))
    }

    /// Appends one record as raw bytes, written back verbatim — the passthrough
    /// path for a record the typed encoder does not faithfully round-trip (an
    /// unknown type, an `.unsupported` DIB, an extended font, a pattern-DIB pen),
    /// exactly as `EMFDocumentWriter.reEmit` re-emits such records. `bytes` must
    /// be one whole EMF record: the 8-byte Type/Size header then its body, with
    /// `nSize` a multiple of 4 ([MS-EMF] §2.3). The bytes are NOT re-validated —
    /// they are the caller's own previously parsed source bytes — but a
    /// handle-bearing creation/reference record ([MS-EMF] §2.3.7–2.3.8) still
    /// contributes its index to the recomputed handle-table size.
    public func appendRaw(_ bytes: [UInt8]) {
        items.append(.raw(bytes))
    }

    /// Serialises the whole document: header, the appended records in order,
    /// then EMR_EOF — with Bytes/Records/Handles computed from the bytes
    /// written.
    public func finish() throws(EMFWriteError) -> Data {
        var body: [UInt8] = []
        var payloads: [EMFRecordPayload] = []
        var rawMaxHandle: UInt32 = 0
        for item in items {
            switch item {
            case .payload(let payload):
                let encoded = try EMFRecordEncoder.encode(payload)
                body.append(contentsOf: [UInt8](encoded))
                payloads.append(payload)
            case .raw(let bytes):
                body.append(contentsOf: bytes)
                rawMaxHandle = max(rawMaxHandle, Self.rawTableIndex(bytes))
            }
        }
        body.append(contentsOf: EMFDocumentWriter.encodeEOF())

        let handleCount = try max(EMFDocumentWriter.computeHandleCount(payloads),
                                  rawHandleTableSize(rawMaxHandle))
        // Header (1) + appended records + EOF (1).
        let recordCount = UInt32(clamping: items.count + 2)

        // The header length depends only on the description, independent of the
        // body, so a two-pass size resolve is unnecessary: encode once with a
        // provisional Bytes, measure, then re-encode with the final Bytes.
        let provisional = EMFDocumentWriter.encodeCanonicalHeader(
            bounds: bounds, frame: frame, device: device, millimeters: millimeters,
            description: description, bytes: 0, records: recordCount, handles: handleCount
        )
        let totalBytes = provisional.count + body.count
        guard totalBytes <= Int(UInt32.max) else {
            throw .fileTooLarge(byteLength: totalBytes)
        }
        let header = EMFDocumentWriter.encodeCanonicalHeader(
            bounds: bounds, frame: frame, device: device, millimeters: millimeters,
            description: description, bytes: UInt32(totalBytes),
            records: recordCount, handles: handleCount
        )

        var out: [UInt8] = []
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: header)
        out.append(contentsOf: body)
        return Data(out)
    }

    // MARK: - Passthrough handle accounting

    /// The object-table index a raw (passthrough) record names, or 0 when the
    /// record carries none. Creation and select/delete records put their handle
    /// in the first body field (record offset 8, [MS-EMF] §2.3.7–2.3.8); a stock
    /// handle (high bit set) is not a table slot ([MS-EMF] §2.1.31); a record too
    /// short to hold the field contributes 0. Little-endian reads (§2.3).
    private static func rawTableIndex(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 12 else { return 0 }
        let type = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        guard EMFDocumentWriter.handleFieldTypes.contains(type) else { return 0 }
        let raw = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8)
            | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24)
        return raw & 0x8000_0000 == 0 ? raw : 0
    }

    /// The handle-table size a passthrough record's max index demands: one past
    /// that index, or 0 when no passthrough record carried a handle (so the
    /// payload recompute, which floors at 1, governs). `rawMaxHandle` has the
    /// stock bit clear (filtered in `rawTableIndex`), so it is ≤ 0x7FFF_FFFF and
    /// the +1 cannot overflow; a size past the UInt16 field is a typed error.
    private func rawHandleTableSize(_ rawMaxHandle: UInt32) throws(EMFWriteError) -> UInt16 {
        guard rawMaxHandle > 0 else { return 0 }
        let size = rawMaxHandle + 1
        guard size <= UInt32(UInt16.max) else {
            throw .objectTableOverflow(index: rawMaxHandle)
        }
        return UInt16(size)
    }
}
