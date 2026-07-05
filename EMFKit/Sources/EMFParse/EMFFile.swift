import Foundation

/// The single error `EMFFile.parse` throws, and only when the input has no
/// valid EMF header — the one condition under which there is nothing to hand
/// back. After a valid header, parsing never throws (malformed records become
/// `EMFDiagnostic`s). Offsets are byte offsets from the start of the file.
public enum EMFParseError: Error, Sendable, Equatable {
    /// Fewer bytes than the minimum viable file: an 88-byte base header plus
    /// an 8-byte trailing record header (96 bytes). `count` is what was given.
    case tooShort(count: Int)
    /// The first record's `iType` was not 1 (EMR_HEADER). `type` is the value
    /// found at offset 0.
    case notHeaderRecord(type: UInt32)
    /// `RecordSignature` at file offset 40 was not 0x464D4520 (" EMF").
    /// `found` is the value read.
    case badSignature(found: UInt32)
    /// The header record's `nSize` was structurally invalid: below the 88-byte
    /// minimum, not a multiple of 4, or larger than the file. `size` is the
    /// value found at offset 4.
    case invalidHeaderSize(size: UInt32)
}

/// A parsed EMF file: the decoded header, the record inventory, any
/// diagnostics raised during the walk, and how many bytes the walk covered.
public struct EMFFile: Sendable, Equatable {
    /// The decoded EMR_HEADER (also present as `records[0]`).
    public let header: EMFHeader
    /// Every record located, in file order. `records[0]` is the header record.
    public let records: [EMFRawRecord]
    /// Non-fatal issues found during the walk (empty for a clean file).
    public let diagnostics: [EMFDiagnostic]
    /// Number of bytes the walk accounted for, from offset 0. Equals the file
    /// length for a clean, EOF-terminated file with no trailing bytes.
    public let bytesWalked: Int

    init(
        header: EMFHeader,
        records: [EMFRawRecord],
        diagnostics: [EMFDiagnostic],
        bytesWalked: Int
    ) {
        self.header = header
        self.records = records
        self.diagnostics = diagnostics
        self.bytesWalked = bytesWalked
    }

    // MARK: - Constants

    /// " EMF" little-endian, the required `RecordSignature` ([MS-EMF] §2.2.9).
    static let recordSignatureValue: UInt32 = 0x464D_4520
    /// EMR_HEADER type id.
    static let headerType: UInt32 = 1
    /// EMR_EOF type id.
    static let eofType: UInt32 = 14
    /// Minimum fixed header size, in bytes (base variant).
    static let baseHeaderSize = 88
    /// Every record opens with an 8-byte `Type`/`Size` header.
    static let recordHeaderSize = 8

    // MARK: - Entry point

    /// Parses `data` into an `EMFFile`.
    ///
    /// Throws `EMFParseError` only when no valid header exists (too short;
    /// first record not EMR_HEADER; wrong `RecordSignature`; structurally
    /// invalid header `nSize`). Once the header validates, this never throws:
    /// malformed records are recorded as diagnostics, the walk stops, and
    /// everything parsed so far is returned.
    public static func parse(_ data: Data) throws(EMFParseError) -> EMFFile {
        let reader = ByteReader(data)
        let total = reader.count

        // A viable file needs an 88-byte base header plus at least an 8-byte
        // trailing record header (the EMR_EOF). Anything shorter cannot carry
        // a header we could validate.
        guard total >= baseHeaderSize + recordHeaderSize else {
            throw .tooShort(count: total)
        }

        // First record must be EMR_HEADER (type 1) at offset 0.
        guard let firstType = reader.readUInt32(at: 0) else {
            throw .tooShort(count: total)
        }
        guard firstType == headerType else {
            throw .notHeaderRecord(type: firstType)
        }

        // Header record nSize at offset 4.
        guard let headerRecordSize = reader.readUInt32(at: 4) else {
            throw .tooShort(count: total)
        }

        // RecordSignature at fixed file offset 40.
        guard let signature = reader.readUInt32(at: 40) else {
            throw .tooShort(count: total)
        }
        guard signature == recordSignatureValue else {
            throw .badSignature(found: signature)
        }

        // Validate the header record's own size: >= 88, 4-aligned, and within
        // the file. `headerRecordSize` is the record's total size (nSize).
        let headerSizeInt = Int(headerRecordSize)
        guard headerRecordSize >= UInt32(baseHeaderSize),
              headerRecordSize % 4 == 0,
              headerSizeInt <= total
        else {
            throw .invalidHeaderSize(size: headerRecordSize)
        }

        // Decode the header object (guaranteed to succeed: all fixed fields
        // sit inside [0, 88) which we have already bounded).
        let header = decodeHeader(
            reader: reader,
            headerRecordSize: headerRecordSize
        )

        let headerRecord = EMFRawRecord(
            type: headerType,
            size: headerRecordSize,
            offset: 0
        )

        // Walk the remaining records starting right after the header record.
        let walk = walkRecords(
            reader: reader,
            firstRecord: headerRecord,
            startOffset: headerSizeInt
        )

        var diagnostics = walk.diagnostics

        // Advisory-field cross-checks (never affect the record list itself).
        // Compared in the Int domain: converting the walk's Int counts to
        // UInt32 would trap on inputs past 4 GB — exactly the hostile-input
        // crash class §8 bans. UInt32 → Int never traps on a 64-bit platform.
        if Int(header.records) != walk.records.count {
            diagnostics.append(
                .recordCountMismatch(
                    headerSays: header.records,
                    walked: walk.records.count
                )
            )
        }
        if Int(header.bytes) != walk.bytesWalked {
            diagnostics.append(
                .byteCountMismatch(
                    headerSays: header.bytes,
                    walked: walk.bytesWalked
                )
            )
        }

        return EMFFile(
            header: header,
            records: walk.records,
            diagnostics: diagnostics,
            bytesWalked: walk.bytesWalked
        )
    }

    // MARK: - Header decode

    /// Decodes the EMR_HEADER object. All reads target offsets within
    /// [0, 88) plus the extension words within the validated header record, so
    /// every read is in range; `nil` reads fall back to 0 defensively without
    /// force-unwrapping.
    private static func decodeHeader(
        reader: ByteReader,
        headerRecordSize: UInt32
    ) -> EMFHeader {
        // rclBounds at 8, rclFrame at 24 (RectL: left/top/right/bottom).
        let bounds = RectL(
            left: reader.readInt32(at: 8) ?? 0,
            top: reader.readInt32(at: 12) ?? 0,
            right: reader.readInt32(at: 16) ?? 0,
            bottom: reader.readInt32(at: 20) ?? 0
        )
        let frame = RectL(
            left: reader.readInt32(at: 24) ?? 0,
            top: reader.readInt32(at: 28) ?? 0,
            right: reader.readInt32(at: 32) ?? 0,
            bottom: reader.readInt32(at: 36) ?? 0
        )
        let recordSignature = reader.readUInt32(at: 40) ?? 0
        let version = reader.readUInt32(at: 44) ?? 0
        let bytes = reader.readUInt32(at: 48) ?? 0
        let records = reader.readUInt32(at: 52) ?? 0
        let handles = reader.readUInt16(at: 56) ?? 0
        // 58: Reserved (u16) — skipped.
        let nDescription = reader.readUInt32(at: 60) ?? 0
        let offDescription = reader.readUInt32(at: 64) ?? 0
        let nPalEntries = reader.readUInt32(at: 68) ?? 0
        let device = SizeL(
            cx: reader.readInt32(at: 72) ?? 0,
            cy: reader.readInt32(at: 76) ?? 0
        )
        let millimeters = SizeL(
            cx: reader.readInt32(at: 80) ?? 0,
            cy: reader.readInt32(at: 84) ?? 0
        )

        // Candidate HeaderExtension1 pixel-format fields at offsets 88/92,
        // read BEFORE variant selection because the HeaderSize algorithm
        // consults them ([MS-EMF] §2.3.4.2). For an 88-byte header these
        // reads land on the next record's bytes; headerSize()'s >= 100 gate
        // guarantees such values are never consulted.
        let cbPixelFormat = reader.readUInt32(at: 88) ?? 0
        let offPixelFormat = reader.readUInt32(at: 92) ?? 0

        let effectiveSize = headerSize(
            recordSize: headerRecordSize,
            nDescription: nDescription,
            offDescription: offDescription,
            cbPixelFormat: cbPixelFormat,
            offPixelFormat: offPixelFormat
        )

        // Variant selection from the FINAL capped fixed-part size. The < 88
        // case is impossible here — parse() already rejected it.
        let variant: EMFHeaderVariant
        if effectiveSize >= 108 {
            variant = .extension2
        } else if effectiveSize >= 100 {
            variant = .extension1
        } else {
            variant = .base
        }

        var ext1: EMFHeaderExtension1?
        var ext2: EMFHeaderExtension2?
        if variant != .base {
            ext1 = EMFHeaderExtension1(
                cbPixelFormat: cbPixelFormat,
                offPixelFormat: offPixelFormat,
                bOpenGL: reader.readUInt32(at: 96) ?? 0
            )
        }
        if variant == .extension2 {
            ext2 = EMFHeaderExtension2(
                micrometersX: reader.readUInt32(at: 100) ?? 0,
                micrometersY: reader.readUInt32(at: 104) ?? 0
            )
        }

        let description = decodeDescription(
            reader: reader,
            nDescription: nDescription,
            offDescription: offDescription,
            headerRecordSize: headerRecordSize
        )

        return EMFHeader(
            bounds: bounds,
            frame: frame,
            recordSignature: recordSignature,
            version: version,
            bytes: bytes,
            records: records,
            handles: handles,
            nDescription: nDescription,
            offDescription: offDescription,
            nPalEntries: nPalEntries,
            device: device,
            millimeters: millimeters,
            extension1: ext1,
            extension2: ext2,
            description: description,
            variant: variant
        )
    }

    /// The HeaderSize algorithm ([MS-EMF] §2.3.4.2), computed from the offsets
    /// of BOTH optional variable-length fields:
    ///
    /// 1. Start from the header record's `nSize`.
    /// 2. Description cap: a description string starting below the running
    ///    size ends the fixed part where the description begins.
    /// 3. Pixel-format cap: only when the running size is still >= 100 — i.e.
    ///    the HeaderExtension1 fields at offsets 88/92 are inside the fixed
    ///    part and can be trusted — a pixel-format field starting below the
    ///    running size ends the fixed part where the pixel format begins.
    ///
    /// `cbPixelFormat`/`offPixelFormat` are the candidate values read at
    /// offsets 88/92; for headers whose fixed part ends before offset 96 those
    /// bytes belong to whatever follows, and step 3's >= 100 gate guarantees
    /// they are ignored. Returned as `Int` for variant comparison.
    static func headerSize(
        recordSize: UInt32,
        nDescription: UInt32,
        offDescription: UInt32,
        cbPixelFormat: UInt32,
        offPixelFormat: UInt32
    ) -> Int {
        var size = Int(recordSize)
        if nDescription != 0, offDescription != 0, Int(offDescription) < size {
            size = Int(offDescription)
        }
        if size >= 100, cbPixelFormat != 0, offPixelFormat != 0,
           Int(offPixelFormat) < size {
            size = Int(offPixelFormat)
        }
        return size
    }

    /// Decodes the UTF-16LE description string, but only when `nDescription`
    /// is non-zero and the byte range `[offDescription, offDescription + 2n)`
    /// lies fully inside the header record. Returns `nil` otherwise — including
    /// when the declared length would overflow or the bytes are unreadable.
    private static func decodeDescription(
        reader: ByteReader,
        nDescription: UInt32,
        offDescription: UInt32,
        headerRecordSize: UInt32
    ) -> String? {
        guard nDescription != 0, offDescription != 0 else { return nil }

        // Byte length = 2 * character count. Guard the multiply against
        // overflow before computing the end offset.
        let (byteLen, mulOverflow) = nDescription.multipliedReportingOverflow(by: 2)
        guard !mulOverflow else { return nil }

        let start = Int(offDescription)
        let length = Int(byteLen)
        let (end, addOverflow) = start.addingReportingOverflow(length)
        guard !addOverflow, end <= Int(headerRecordSize) else { return nil }

        guard let raw = reader.data(at: start, length: length) else {
            return nil
        }
        return String(bytes: raw, encoding: .utf16LittleEndian)
    }

    // MARK: - Record walk

    private struct WalkResult {
        var records: [EMFRawRecord]
        var diagnostics: [EMFDiagnostic]
        var bytesWalked: Int
    }

    /// Walks records from `startOffset` to EMR_EOF (or the first malformed
    /// record). `firstRecord` is the already-validated header record, seeded as
    /// `records[0]`; `startOffset` is the offset just past it.
    ///
    /// Every record: read the 8-byte header, then check `nSize` >= 8,
    /// `nSize % 4 == 0`, and `nSize <= remaining` BEFORE trusting the record.
    /// On any violation, record a diagnostic and stop, keeping earlier
    /// records. Stops after EMR_EOF; reports trailing bytes or a missing EOF.
    private static func walkRecords(
        reader: ByteReader,
        firstRecord: EMFRawRecord,
        startOffset: Int
    ) -> WalkResult {
        let total = reader.count
        var records: [EMFRawRecord] = [firstRecord]
        var diagnostics: [EMFDiagnostic] = []
        var offset = startOffset
        var sawEOF = false

        while offset < total {
            let remaining = total - offset

            // Need a full 8-byte record header to read Type and Size.
            guard remaining >= recordHeaderSize,
                  let type = reader.readUInt32(at: offset),
                  let size = reader.readUInt32(at: offset + 4)
            else {
                diagnostics.append(
                    .truncatedRecordHeader(offset: offset, remaining: remaining)
                )
                break
            }

            // Bounds-check nSize before admitting the record.
            if size < UInt32(recordHeaderSize) {
                diagnostics.append(.sizeTooSmall(offset: offset, size: size))
                break
            }
            if size % 4 != 0 {
                diagnostics.append(.sizeNotAligned(offset: offset, size: size))
                break
            }
            if Int(size) > remaining {
                diagnostics.append(
                    .sizeExceedsRemaining(
                        offset: offset,
                        size: size,
                        remaining: remaining
                    )
                )
                break
            }

            records.append(
                EMFRawRecord(type: type, size: size, offset: offset)
            )
            offset += Int(size)

            if type == eofType {
                sawEOF = true
                break
            }
        }

        if sawEOF {
            let trailing = total - offset
            if trailing > 0 {
                diagnostics.append(.trailingBytesAfterEOF(count: trailing))
            }
        } else if diagnostics.isEmpty {
            // Ran off the end cleanly but never hit EMR_EOF.
            diagnostics.append(.missingEOF)
        }

        return WalkResult(
            records: records,
            diagnostics: diagnostics,
            bytesWalked: offset
        )
    }
}
