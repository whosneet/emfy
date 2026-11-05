import Foundation
import EMFParse
import WMFParse

/// Builds a placeable WMF from scratch by appending typed `WMFRecord`s — the
/// create-a-file entry point the E1 scene exporter will drive (v3 plan §11.1). It
/// owns the Aldus placeable header ([MS-WMF] §2.3.2.3), the META_HEADER
/// (§2.3.2.2) and the trailing META_EOF (§2.3.2.1), so a caller appends only the
/// drawing records between them, and it recomputes `SizeLow`/`SizeHigh`,
/// `NumberOfObjects`, `MaxRecord` and the placeable `Checksum` from what was
/// written.
///
/// Object slots: WMF create records carry no index — a created object takes the
/// lowest free slot and `deleteObject` frees it ([MS-WMF] §3.1.4.1). `append`
/// returns the allocated 0-based slot for a create record (and `nil` otherwise);
/// the caller puts that slot into the SELECTOBJECT/DELETEOBJECT it appends later.
/// `finish` declares `NumberOfObjects` as the peak table size used.
public final class WMFDocumentBuilder {
    private let boundingBox: WMFRect16
    private let inch: UInt16
    private let embeddedEMF: Data?

    private var records: [WMFRecord] = []
    private var table = WMFObjectTable()

    /// Starts a placeable document. `boundingBox` is the destination rectangle in
    /// logical units, `unitsPerInch` the placeable `Inch` (1440 twips by
    /// convention). When `embeddedEMF` is set, a complete copy of those EMF bytes
    /// is packaged into leading META_ESCAPE "WMFC" records so a richer reader
    /// recovers the full drawing (`WMFEmbeddedEMFWriter`).
    public init(boundingBox: WMFRect16, unitsPerInch: UInt16 = 1440, embeddedEMF: Data? = nil) {
        self.boundingBox = boundingBox
        self.inch = unitsPerInch
        self.embeddedEMF = embeddedEMF
    }

    /// Appends one record. Validates eagerly (an out-of-range coordinate, count,
    /// or string throws now, not at `finish`) and does the object-table
    /// bookkeeping: a create record allocates the lowest free slot and returns it;
    /// a `deleteObject` frees the slot it names; every other record returns `nil`.
    /// An appended `.eof` is accepted but ignored — `finish` emits the single
    /// trailing META_EOF itself.
    @discardableResult
    public func append(_ record: WMFRecord) throws(WMFWriteError) -> UInt16? {
        // Encodability check (the encoded result is re-made in `finish`).
        _ = try WMFRecordEncoder.encode(record)

        switch record {
        case .createPenIndirect, .createBrushIndirect, .createFontIndirect:
            let slot = try table.allocate()
            records.append(record)
            return UInt16(slot)   // slot < NumberOfObjects cap, so it fits
        case .deleteObject(let index):
            if index & 0x8000 == 0 { table.free(Int(index)) }
            records.append(record)
            return nil
        case .eof:
            return nil            // the builder owns the trailing EOF
        default:
            records.append(record)
            return nil
        }
    }

    /// Serialises the whole document: placeable header, META_HEADER, any
    /// embedded-EMF escape records, the appended drawing records, then one
    /// META_EOF — with the accounting fields and checksum recomputed.
    public func finish() throws(WMFWriteError) -> Data {
        var recordChunks: [[UInt8]] = []

        // Embedded-EMF escapes lead (the reader scans from the first "WMFC" chunk).
        if let embeddedEMF {
            recordChunks.append(contentsOf: try WMFEmbeddedEMFWriter.escapeRecords(for: embeddedEMF))
        }
        for record in records {
            recordChunks.append(try WMFRecordEncoder.encode(record))
        }
        recordChunks.append(try WMFRecordEncoder.encode(.eof))

        var recordBytesTotal = 0
        var maxRecordWords: UInt32 = 0
        for chunk in recordChunks {
            recordBytesTotal += chunk.count
            let words = UInt32(chunk.count / 2)
            if words > maxRecordWords { maxRecordWords = words }
        }

        // Metafile size in WORDs = (18-byte header + records) / 2 (placeable
        // excluded). Record chunks are WORD-aligned, so the byte total is even.
        let metafileBytes = 18 + recordBytesTotal
        guard metafileBytes / 2 <= Int(UInt32.max) else {
            throw .fileTooLarge(byteCount: metafileBytes)
        }
        let metafileWords = metafileBytes / 2

        var header = ByteWriter()
        header.appendUInt16(1)                                       // Type = MEMORYMETAFILE
        header.appendUInt16(9)                                       // HeaderSize (WORDs)
        header.appendUInt16(0x0300)                                  // Version = METAVERSION300
        header.appendUInt16(UInt16(metafileWords & 0xFFFF))          // SizeLow
        header.appendUInt16(UInt16((metafileWords >> 16) & 0xFFFF))  // SizeHigh
        header.appendUInt16(table.numberOfObjects)                  // NumberOfObjects
        header.appendUInt32(maxRecordWords)                          // MaxRecord
        header.appendUInt16(0)                                       // NumberOfMembers

        var out = ByteWriter()
        out.appendBytes(placeableHeaderBytes())
        out.appendBytes(header.bytes)
        for chunk in recordChunks { out.appendBytes(chunk) }
        return out.data
    }

    /// Serialises the document and gzip-wraps it as .wmz bytes (`GzipWriter`).
    public func finishCompressed() throws(WMFWriteError) -> Data {
        GzipWriter.compress(try finish())
    }

    /// The 22-byte Aldus placeable header ([MS-WMF] §2.3.2.3) with the Checksum
    /// recomputed over the first ten WORDs.
    private func placeableHeaderBytes() -> [UInt8] {
        var b = ByteWriter()
        b.appendUInt32(0x9AC6_CDD7)               // Key
        b.appendUInt16(0)                         // HWmf
        b.appendInt16(boundingBox.left)           // BoundingBox: Left, Top, Right, Bottom
        b.appendInt16(boundingBox.top)
        b.appendInt16(boundingBox.right)
        b.appendInt16(boundingBox.bottom)
        b.appendUInt16(inch)                      // Inch
        b.appendUInt32(0)                         // Reserved
        var bytes = b.bytes                       // 20 bytes = ten WORDs
        let checksum = WMFDocumentWriter.placeableChecksum(bytes)
        bytes.append(UInt8(checksum & 0xFF))
        bytes.append(UInt8((checksum >> 8) & 0xFF))
        return bytes
    }
}
