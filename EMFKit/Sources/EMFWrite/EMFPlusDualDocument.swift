import Foundation
import EMFParse

/// Builds an EMF+ **dual** metafile from scratch (owner decision, docs/v3-plan
/// §11.1: "EMF using EMF+ records with a GDI fallback"). The file carries, in one
/// EMF container:
///
/// - an EMR_HEADER ([MS-EMF] §2.3.4.2),
/// - EMR_COMMENT_EMFPLUS records holding an EmfPlusHeader with the Dual flag
///   ([MS-EMFPLUS] §2.3.3.3), then the EMF+ drawing/state records and the EMF+
///   objects they reference, closed by EmfPlusEndOfFile,
/// - the GDI fallback records (appended OUTSIDE any EmfPlusGetDC window, so an
///   EMF+-mode renderer ignores them and a GDI-mode renderer draws them —
///   [MS-EMFPLUS] §1.3.1), and
/// - EMR_EOF.
///
/// EMF+ object ids are allocated 0…63 ([MS-EMFPLUS] §2.3.5.1 ObjectID / §3.1.2
/// object table); an oversized object is split through the continuation mechanism
/// by `EMFPlusCommentWriter`. The GDI handle table and the header's
/// Bytes/Records/Handles are recomputed from what is actually written (never
/// trusted), mirroring `EMFDocumentWriter`.
public final class EMFPlusDualDocumentBuilder {

    private let bounds: RectL
    private let frame: RectL
    private let device: SizeL
    private let millimeters: SizeL
    private let description: String?
    private let logicalDpiX: UInt32
    private let logicalDpiY: UInt32
    private let maxCommentPayload: Int
    private let maxObjectDataSize: Int

    /// The next free EMF+ object-table index (0…63).
    private var nextObjectID: UInt8 = 0
    /// The current run of framed EMF+ record bytes awaiting a comment flush.
    private var plusRun: [UInt8] = []
    /// The EMF body records built so far (comments, GDI records), as raw bytes.
    private var bodyChunks: [[UInt8]] = []
    /// The GDI fallback payloads, kept for the handle-table recompute.
    private var gdiPayloads: [EMFRecordPayload] = []
    /// Running EMF record count (header + body records + EOF).
    private var recordCount = 1
    private var finished = false

    /// Starts a dual document. `bounds`/`frame`/`device`/`millimeters` are the EMF
    /// header geometry (as `EMFDocumentBuilder`); `logicalDpiX/Y` go in the
    /// EmfPlusHeader and drive EMF+ physical-unit scaling.
    public init(
        bounds: RectL,
        frame: RectL,
        device: SizeL,
        millimeters: SizeL,
        logicalDpiX: UInt32 = 96,
        logicalDpiY: UInt32 = 96,
        description: String? = nil,
        maxCommentPayload: Int = EMFPlusCommentWriter.defaultMaxCommentPayload,
        maxObjectDataSize: Int = EMFPlusCommentWriter.defaultMaxObjectDataSize
    ) {
        self.bounds = bounds
        self.frame = frame
        self.device = device
        self.millimeters = millimeters
        self.description = description
        self.logicalDpiX = logicalDpiX
        self.logicalDpiY = logicalDpiY
        self.maxCommentPayload = maxCommentPayload
        self.maxObjectDataSize = maxObjectDataSize
        // The EmfPlusHeader (Dual) is always the first EMF+ record (§2.3.3.3).
        plusRun = EMFPlusRecordPayload
            .header(dual: true, videoDisplay: true, logicalDpiX: logicalDpiX, logicalDpiY: logicalDpiY)
            .framed()
    }

    /// Allocates an EMF+ object id and appends its EmfPlusObject record(s)
    /// (continuation-split when oversized). The returned id goes in the drawing
    /// records that reference it.
    @discardableResult
    public func addObject(_ value: EMFPlusObjectValue) throws(EMFWriteError) -> UInt8 {
        guard nextObjectID < 64 else {
            throw .objectTableOverflow(index: UInt32(nextObjectID))
        }
        let id = nextObjectID
        nextObjectID += 1
        let objectType = Self.objectType(of: value)
        let payload = try EMFPlusObjectEncoder.encode(value)
        let records = EMFPlusCommentWriter.objectRecords(
            objectID: id, objectType: objectType, payload: payload, maxObjectDataSize: maxObjectDataSize)
        for record in records { plusRun.append(contentsOf: record) }
        return id
    }

    /// Appends one EMF+ drawing/state record to the current run.
    public func appendPlus(_ payload: EMFPlusRecordPayload) {
        plusRun.append(contentsOf: payload.framed())
    }

    /// Appends one GDI fallback record (outside any GetDC window). The current
    /// EMF+ run is flushed to comment(s) first, so the file-order grouping stays
    /// EMF+-records-then-their-fallback.
    public func appendGDIFallback(_ payload: EMFRecordPayload) throws(EMFWriteError) {
        flushPlusRun()
        let encoded = try EMFRecordEncoder.encode(payload)
        bodyChunks.append([UInt8](encoded))
        gdiPayloads.append(payload)
        recordCount += 1
    }

    /// Serialises the whole dual document.
    public func finish() throws(EMFWriteError) -> Data {
        precondition(!finished, "EMFPlusDualDocumentBuilder.finish() called twice")
        finished = true

        // EmfPlusEndOfFile closes the EMF+ stream (§2.3.3.1), then the final flush.
        plusRun.append(contentsOf: EMFPlusRecordPayload.endOfFile.framed())
        flushPlusRun()

        bodyChunks.append(EMFDocumentWriter.encodeEOF())
        recordCount += 1

        let handleCount = try EMFDocumentWriter.computeHandleCount(gdiPayloads)
        let bodyTotal = bodyChunks.reduce(0) { $0 + $1.count }

        let provisional = EMFDocumentWriter.encodeCanonicalHeader(
            bounds: bounds, frame: frame, device: device, millimeters: millimeters,
            description: description, bytes: 0,
            records: UInt32(clamping: recordCount), handles: handleCount)
        let totalBytes = provisional.count + bodyTotal
        guard totalBytes <= Int(UInt32.max) else {
            throw .fileTooLarge(byteLength: totalBytes)
        }
        let header = EMFDocumentWriter.encodeCanonicalHeader(
            bounds: bounds, frame: frame, device: device, millimeters: millimeters,
            description: description, bytes: UInt32(totalBytes),
            records: UInt32(clamping: recordCount), handles: handleCount)

        var out: [UInt8] = []
        out.reserveCapacity(totalBytes)
        out.append(contentsOf: header)
        for chunk in bodyChunks { out.append(contentsOf: chunk) }
        return Data(out)
    }

    // MARK: - Internals

    /// Packs the pending EMF+ run into EMR_COMMENT_EMFPLUS record(s) and appends
    /// them to the body, counting each comment toward the header Records field.
    private func flushPlusRun() {
        guard !plusRun.isEmpty else { return }
        let comments = EMFPlusCommentWriter.packComments(
            streamBytes: plusRun, maxCommentPayload: maxCommentPayload)
        bodyChunks.append(comments)
        recordCount += Self.commentCount(streamByteCount: plusRun.count, maxCommentPayload: maxCommentPayload)
        plusRun.removeAll(keepingCapacity: true)
    }

    /// The number of comment records `packComments` emits for a run — one per
    /// `maxCommentPayload`-sized (4-floored) slice.
    private static func commentCount(streamByteCount: Int, maxCommentPayload: Int) -> Int {
        guard streamByteCount > 0 else { return 0 }
        let limit = max(4, maxCommentPayload & ~3)
        return (streamByteCount + limit - 1) / limit
    }

    private static func objectType(of value: EMFPlusObjectValue) -> EMFPlusObjectType {
        switch value {
        case .brush: return .brush
        case .pen: return .pen
        case .path: return .path
        case .region: return .region
        case .font: return .font
        case .stringFormat: return .stringFormat
        case .image: return .image
        case .imageAttributes: return .imageAttributes
        case .undecoded(let type, _): return type
        case .malformed(let type, _): return type
        }
    }
}
