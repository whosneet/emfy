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

    private var payloads: [EMFRecordPayload] = []
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
        payloads.append(payload)
    }

    /// Serialises the whole document: header, the appended records in order,
    /// then EMR_EOF — with Bytes/Records/Handles computed from the bytes
    /// written.
    public func finish() throws(EMFWriteError) -> Data {
        var body: [UInt8] = []
        for payload in payloads {
            let encoded = try EMFRecordEncoder.encode(payload)
            body.append(contentsOf: [UInt8](encoded))
        }
        body.append(contentsOf: EMFDocumentWriter.encodeEOF())

        let handleCount = try EMFDocumentWriter.computeHandleCount(payloads)
        // Header (1) + appended records + EOF (1).
        let recordCount = UInt32(clamping: payloads.count + 2)

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
}
