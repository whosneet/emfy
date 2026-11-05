import Foundation
import EMFParse
import WMFParse

/// Re-emits a parsed `WMFFile` as a fresh WMF byte stream (the WMF analogue of
/// `EMFDocumentWriter.reEmit`): placeable vs standard preserved; every generic
/// record passed through byte for byte from the source; and the META_HEADER's
/// advisory accounting fields — `SizeLow`/`SizeHigh`, `MaxRecord` — plus the
/// placeable `Checksum` recomputed from what was actually written, never trusted
/// from the input. `NumberOfObjects` is raised to the computed table size but
/// never lowered below the declared value (primer §8; v3 plan §11.1).
public enum WMFDocumentWriter {

    /// Object-creation RecordFunctions ([MS-WMF] §3.1.4.1): each consumes the
    /// lowest free object-table slot. The set the `NumberOfObjects` recompute
    /// simulates.
    static let objectCreateFunctions: Set<UInt16> = [
        0x02FA,   // META_CREATEPENINDIRECT
        0x02FB,   // META_CREATEFONTINDIRECT
        0x02FC,   // META_CREATEBRUSHINDIRECT
        0x00F7,   // META_CREATEPALETTE
        0x01F9,   // META_CREATEPATTERNBRUSH
        0x0142,   // META_DIBCREATEPATTERNBRUSH
        0x06FF,   // META_CREATEREGION
    ]
    /// META_DELETEOBJECT ([MS-WMF] §2.3.4.7): frees the slot in its parameter.
    static let deleteObjectFunction: UInt16 = 0x01F0

    /// Re-emits `file` as fresh WMF bytes. `source` MUST be the bytes `file` was
    /// parsed from (the inflated bytes for a .wmz): records are sliced from it,
    /// every slice bounds-checked, so a mismatched or truncated `source` yields a
    /// typed error, never a trap.
    ///
    /// The result re-parses to a record stream equal to `file`'s (same functions,
    /// sizes and order), with a header whose recomputed fields are now correct and
    /// every preserved field (Type, Version, HeaderSize, NumberOfMembers, and the
    /// placeable BoundingBox/Inch) unchanged.
    public static func reEmit(_ file: WMFFile, source: Data) throws(WMFWriteError) -> Data {
        let src = [UInt8](source)
        var out: [UInt8] = []

        let hasPlaceable = file.placeable != nil
        let metaOffset = hasPlaceable ? 22 : 0

        // Placeable header: preserve all 22 bytes, recompute the Checksum WORD.
        if hasPlaceable {
            guard src.count >= 22 else {
                throw .sourceRecordOutOfBounds(recordOffset: 0, recordSize: 22)
            }
            var placeable = Array(src[0 ..< 22])
            patchUInt16(&placeable, at: 20, placeableChecksum(placeable))
            out.append(contentsOf: placeable)
        }

        // META_HEADER (18 bytes): preserve, then patch the recomputed fields.
        guard src.count >= metaOffset + 18 else {
            throw .sourceRecordOutOfBounds(recordOffset: metaOffset, recordSize: 18)
        }
        var header = Array(src[metaOffset ..< metaOffset + 18])

        // Passthrough every walked record (the list already ends at META_EOF).
        var recordBytesTotal = 0
        var maxRecordWords: UInt32 = 0
        var recordChunks: [[UInt8]] = []
        recordChunks.reserveCapacity(file.records.count)
        for record in file.records {
            let bytes = try rawRecordBytes(src, record)
            recordBytesTotal += bytes.count
            if record.sizeWords > maxRecordWords { maxRecordWords = record.sizeWords }
            recordChunks.append(bytes)
        }

        // Whole-metafile size in WORDs = (18-byte header + records) / 2. The
        // placeable wrapper is excluded ([MS-WMF] §2.3.2.2 counts the metafile
        // proper only). Records are WORD-aligned, so the byte total is even.
        let metafileBytes = 18 + recordBytesTotal
        guard metafileBytes / 2 <= Int(UInt32.max) else {
            throw .fileTooLarge(byteCount: metafileBytes)
        }
        let metafileWords = metafileBytes / 2
        // Re-emit only RAISES an under-declared object table — it never lowers an
        // over-declaration. Shrinking gains nothing, and were the simulation to
        // miss an object-creating record it would under-declare and another reader
        // could fail on an out-of-range slot. `NumberOfObjects` is the table SIZE
        // (not an exact count), so the larger is always safe.
        let numberOfObjects = max(file.header.numberOfObjects, try computeNumberOfObjects(file))

        patchUInt16(&header, at: 6, UInt16(metafileWords & 0xFFFF))          // SizeLow
        patchUInt16(&header, at: 8, UInt16((metafileWords >> 16) & 0xFFFF))  // SizeHigh
        patchUInt16(&header, at: 10, numberOfObjects)                        // NumberOfObjects
        patchUInt32(&header, at: 12, maxRecordWords)                         // MaxRecord

        out.append(contentsOf: header)
        for chunk in recordChunks { out.append(contentsOf: chunk) }
        return Data(out)
    }

    /// Re-emits `file` and gzip-wraps it as .wmz bytes (reusing `GzipWriter`).
    public static func reEmitCompressed(_ file: WMFFile, source: Data) throws(WMFWriteError) -> Data {
        GzipWriter.compress(try reEmit(file, source: source))
    }

    // MARK: - Internals

    /// The placeable `Checksum`: the XOR of the first ten 16-bit WORDs (Key …
    /// Reserved, offsets 0, 2, …, 18), the same computation `WMFParse` verifies
    /// against ([MS-WMF] §2.3.2.3).
    static func placeableChecksum(_ placeable: [UInt8]) -> UInt16 {
        var checksum: UInt16 = 0
        for i in 0 ..< 10 {
            let lo = UInt16(placeable[i * 2])
            let hi = UInt16(placeable[i * 2 + 1])
            checksum ^= lo | (hi << 8)
        }
        return checksum
    }

    /// The header `NumberOfObjects` recomputed by simulating the object table over
    /// the walked records: each create record takes the lowest free slot, each
    /// DELETEOBJECT frees the slot it names; the peak concurrent count is the
    /// table size the header must declare ([MS-WMF] §3.1.4.1).
    static func computeNumberOfObjects(_ file: WMFFile) throws(WMFWriteError) -> UInt16 {
        var table = WMFObjectTable()
        for record in file.records {
            if objectCreateFunctions.contains(record.function) {
                _ = try table.allocate()
            } else if record.function == deleteObjectFunction {
                let payload = file.payload(of: record)
                guard payload.count >= 2 else { continue }
                let lo = UInt16(payload[payload.startIndex])
                let hi = UInt16(payload[payload.startIndex + 1])
                let raw = lo | (hi << 8)
                if raw & 0x8000 == 0 { table.free(Int(raw)) }   // stock handle: not a slot
            }
        }
        return table.numberOfObjects
    }

    /// The exact source bytes of one walked record (§8 bounds-checked). A record
    /// the `WMFFile` claims exists but whose range falls outside `src` is a
    /// mismatch between `file` and `source` — a typed error, never a trap.
    static func rawRecordBytes(_ src: [UInt8], _ record: WMFRawRecord) throws(WMFWriteError) -> [UInt8] {
        let start = record.offset
        let size = record.byteSize
        guard start >= 0, size >= 0, size <= src.count, start <= src.count - size else {
            throw .sourceRecordOutOfBounds(recordOffset: start, recordSize: size)
        }
        return Array(src[start ..< start + size])
    }
}
