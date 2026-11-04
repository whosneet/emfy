import Foundation

/// The single error `WMFFile.parse` throws, and only when the input has no
/// readable WMF header — the one condition under which there is nothing to hand
/// back. After a valid header, parsing never throws (malformed records become
/// `WMFDiagnostic`s). Offsets are byte offsets from the start of the file.
public enum WMFParseError: Error, Sendable, Equatable {
    /// Fewer bytes than a minimal metafile can carry: an 18-byte META_HEADER,
    /// or — when the Aldus placeable key is present — a 22-byte placeable header
    /// plus the 18-byte META_HEADER. `count` is what was given.
    case tooShort(count: Int)
    /// The META_HEADER at the expected offset was not plausible: `Type` not in
    /// {MEMORYMETAFILE 1, DISKMETAFILE 2}, `HeaderSize` not 9 WORDs, or
    /// `Version` not in {METAVERSION100 0x0100, METAVERSION300 0x0300}
    /// ([MS-WMF] §2.3.2.2). The three fields found are carried for diagnostics.
    case implausibleHeader(type: UInt16, headerSize: UInt16, version: UInt16)
}

/// A parsed WMF file: the optional placeable header, the advisory META_HEADER,
/// the walked records, any diagnostics raised during the walk, and how many
/// bytes the walk covered.
public struct WMFFile: Sendable, Equatable {
    /// The Aldus placeable header, present only for a placeable WMF.
    public let placeable: WMFPlaceableHeader?
    /// The decoded META_HEADER. Every field is advisory (§8).
    public let header: WMFMetaHeader
    /// Every generic record located, in file order. The control (header)
    /// records are NOT in this list — the walk covers the records after the
    /// META_HEADER, ending with META_EOF for a clean file.
    public let records: [WMFRawRecord]
    /// Non-fatal issues found during the walk (empty for a clean file).
    public let diagnostics: [WMFDiagnostic]
    /// Absolute file offset the walk reached, from offset 0: the placeable
    /// header, the META_HEADER, and every admitted record. Equals the file
    /// length for a clean, EOF-terminated file with no trailing bytes.
    public let bytesWalked: Int
    /// Byte offset where the record walk began — the placeable header (if any)
    /// plus the 18-byte META_HEADER. The "header bytes" term of the byte
    /// accounting `header + records + trailing == file size`.
    public let headerByteCount: Int
    /// The normalised byte buffer the walk ran over, retained so record
    /// payloads can be sliced lazily via `payload(of:)`.
    let reader: WMFByteReader

    init(
        placeable: WMFPlaceableHeader?,
        header: WMFMetaHeader,
        records: [WMFRawRecord],
        diagnostics: [WMFDiagnostic],
        bytesWalked: Int,
        headerByteCount: Int,
        reader: WMFByteReader
    ) {
        self.placeable = placeable
        self.header = header
        self.records = records
        self.diagnostics = diagnostics
        self.bytesWalked = bytesWalked
        self.headerByteCount = headerByteCount
        self.reader = reader
    }

    // MARK: - Constants

    /// META_PLACEABLE `Key` ([MS-WMF] §2.3.2.3), little-endian at offset 0.
    static let placeableKey: UInt32 = 0x9AC6_CDD7
    /// The placeable header is 22 bytes; the META_HEADER follows immediately.
    static let placeableHeaderSize = 22
    /// The META_HEADER is 9 WORDs = 18 bytes ([MS-WMF] §2.3.2.2).
    static let metaHeaderSize = 18
    /// A generic record cannot be smaller than its own 6-byte (3-WORD) header
    /// ([MS-WMF] §2.3).
    static let minRecordWords: UInt32 = 3
    /// META_EOF `RecordFunction` ([MS-WMF] §2.1.1.1).
    static let eofFunction: UInt16 = 0x0000
    /// Upper bound on the number of records the walk will materialise (§8).
    ///
    /// Equivalent to EMFFile's `recordCountLimit` and chosen for the same
    /// reason: each walked record costs a fixed-size `WMFRawRecord`, while the
    /// on-disk minimum WMF record is 6 bytes, so a crafted all-tiny-records file
    /// would otherwise inflate the record array without bound and could jetsam a
    /// sandboxed Quick Look extension mid-parse. 1,000,000 bounds the array well
    /// above any real-world metafile and stops the walk on reaching it, keeping
    /// everything parsed so far. (EMFFile's constant is internal to that module;
    /// duplicating the value here avoids widening EMFParse's API for a bare Int.)
    static let recordCountLimit = 1_000_000

    // MARK: - Entry point

    /// Parses `data` into a `WMFFile`.
    ///
    /// Throws `WMFParseError` only when no readable header exists (too short, or
    /// an implausible META_HEADER). Once the header validates, this never
    /// throws: malformed records are recorded as diagnostics, the walk stops,
    /// and everything parsed so far is returned.
    public static func parse(_ data: Data) throws(WMFParseError) -> WMFFile {
        let reader = WMFByteReader(data)
        let total = reader.count

        // The smallest viable file is an 18-byte META_HEADER on its own.
        guard total >= metaHeaderSize else {
            throw .tooShort(count: total)
        }

        // Optional Aldus placeable wrapper: the 0x9AC6CDD7 key at offset 0,
        // immediately followed by a plausible META_HEADER at offset 22.
        var placeable: WMFPlaceableHeader?
        var metaOffset = 0
        if reader.readUInt32(at: 0) == placeableKey {
            guard total >= placeableHeaderSize + metaHeaderSize else {
                throw .tooShort(count: total)
            }
            guard isPlausibleMetaHeader(reader, at: placeableHeaderSize) else {
                // The key is present but no plausible header follows: not a WMF
                // we can read. Report the fields we tried to read at offset 22.
                throw implausibleHeaderError(reader, at: placeableHeaderSize)
            }
            placeable = decodePlaceable(reader)
            metaOffset = placeableHeaderSize
        }

        // Validate the META_HEADER at its offset (offset 0 for a standard WMF).
        guard total >= metaOffset + metaHeaderSize else {
            throw .tooShort(count: total)
        }
        guard isPlausibleMetaHeader(reader, at: metaOffset) else {
            throw implausibleHeaderError(reader, at: metaOffset)
        }

        let header = decodeMetaHeader(reader, at: metaOffset)
        let recordsStart = metaOffset + metaHeaderSize

        // Walk the generic records after the META_HEADER.
        let walk = walkRecords(reader: reader, startOffset: recordsStart)

        var diagnostics: [WMFDiagnostic] = []
        // A placeable checksum mismatch leads the list, matching where the
        // header sits in the file.
        if let placeable, !placeable.checksumOK {
            diagnostics.append(
                .placeableChecksumMismatch(
                    stored: placeable.checksumStored,
                    computed: placeable.checksumComputed
                )
            )
        }
        diagnostics.append(contentsOf: walk.diagnostics)

        // Advisory cross-checks against the walk's own accounting (never affect
        // the record list). All in the Int domain — converting the walk's Int
        // counts to UInt32 would trap on >4 GB inputs, exactly the hostile crash
        // class §8 bans; UInt32 → Int never traps on a 64-bit platform.
        //
        // 1. Whole-metafile size (SizeLow/SizeHigh), in bytes, versus the bytes
        //    the walk covered from the META_HEADER onward. The placeable wrapper
        //    is excluded: it is an extension, not part of the metafile proper.
        //    `Int(UInt32) * 2` cannot overflow a 64-bit Int.
        let declaredMetafileBytes = Int(header.metafileSizeWords) * 2
        let walkedMetafileBytes = walk.bytesWalked - metaOffset
        if declaredMetafileBytes != walkedMetafileBytes {
            diagnostics.append(
                .metafileSizeMismatch(
                    headerSays: declaredMetafileBytes,
                    walked: walkedMetafileBytes
                )
            )
        }
        // 2. MaxRecord (WORDs) versus the largest record the walk saw (WORDs).
        if Int(header.maxRecord) != walk.maxRecordWords {
            diagnostics.append(
                .maxRecordMismatch(
                    headerSays: header.maxRecord,
                    walked: walk.maxRecordWords
                )
            )
        }
        // NumberOfObjects is decoded as advisory but deliberately NOT
        // cross-checked here: it is the object-table size (max concurrent
        // objects), not the number of creation records, so it can only be
        // reconciled once the object table exists (W4). Counting creation
        // records would be a different quantity and would misreport on every
        // normal file (real exports reuse table slots via DELETEOBJECT).

        return WMFFile(
            placeable: placeable,
            header: header,
            records: walk.records,
            diagnostics: diagnostics,
            bytesWalked: walk.bytesWalked,
            headerByteCount: recordsStart,
            reader: reader
        )
    }

    /// Slices a record's `rdParam` payload bytes. Records are admitted only when
    /// their byte span lies inside the buffer, so the range is in bounds; the
    /// `?? Data()` is purely defensive.
    public func payload(of record: WMFRawRecord) -> Data {
        reader.data(at: record.payloadOffset, length: record.payloadByteCount) ?? Data()
    }

    // MARK: - Header plausibility and decode

    /// META_HEADER plausibility ([MS-WMF] §2.3.2.2): `Type` ∈ {MEMORYMETAFILE
    /// 0x0001, DISKMETAFILE 0x0002} (§2.1.1.18), `HeaderSize` == 0x0009 (nine
    /// 16-bit WORDs), and `Version` ∈ {METAVERSION100 0x0100, METAVERSION300
    /// 0x0300} (§2.1.1.19).
    static func isPlausibleMetaHeader(_ reader: WMFByteReader, at offset: Int) -> Bool {
        guard let type = reader.readUInt16(at: offset),
              let headerSize = reader.readUInt16(at: offset + 2),
              let version = reader.readUInt16(at: offset + 4)
        else { return false }
        let typeOK = type == 0x0001 || type == 0x0002
        let sizeOK = headerSize == 0x0009
        let versionOK = version == 0x0100 || version == 0x0300
        return typeOK && sizeOK && versionOK
    }

    /// Builds the `.implausibleHeader` error, reading whatever Type/HeaderSize/
    /// Version it can at `offset` (0 where unreadable).
    private static func implausibleHeaderError(
        _ reader: WMFByteReader,
        at offset: Int
    ) -> WMFParseError {
        .implausibleHeader(
            type: reader.readUInt16(at: offset) ?? 0,
            headerSize: reader.readUInt16(at: offset + 2) ?? 0,
            version: reader.readUInt16(at: offset + 4) ?? 0
        )
    }

    /// Decodes the META_PLACEABLE header ([MS-WMF] §2.3.2.3). The caller has
    /// already confirmed the key and that 22 bytes are available, so the fixed
    /// reads are in range; `nil` reads fall back to 0 without force-unwrapping.
    ///
    /// Layout: Key(4) @0, HWmf(2) @4, BoundingBox(8) @6, Inch(2) @14,
    /// Reserved(4) @16, Checksum(2) @20. The checksum is the XOR of the first
    /// ten 16-bit WORDs (Key…Reserved, offsets 0, 2, …, 18).
    private static func decodePlaceable(_ reader: WMFByteReader) -> WMFPlaceableHeader {
        let boundingBox = WMFRect16(
            left: reader.readInt16(at: 6) ?? 0,
            top: reader.readInt16(at: 8) ?? 0,
            right: reader.readInt16(at: 10) ?? 0,
            bottom: reader.readInt16(at: 12) ?? 0
        )
        let inch = reader.readUInt16(at: 14) ?? 0
        let stored = reader.readUInt16(at: 20) ?? 0

        var computed: UInt16 = 0
        for i in 0 ..< 10 {
            computed ^= reader.readUInt16(at: i * 2) ?? 0
        }

        return WMFPlaceableHeader(
            boundingBox: boundingBox,
            inch: inch,
            checksumStored: stored,
            checksumComputed: computed
        )
    }

    /// Decodes the META_HEADER ([MS-WMF] §2.3.2.2). Layout: Type(2) @0,
    /// HeaderSize(2) @2, Version(2) @4, SizeLow(2) @6, SizeHigh(2) @8,
    /// NumberOfObjects(2) @10, MaxRecord(4) @12, NumberOfMembers(2) @16, all
    /// relative to `offset`. The caller has confirmed 18 bytes are available, so
    /// every read is in range; `nil` reads fall back to 0 defensively.
    private static func decodeMetaHeader(
        _ reader: WMFByteReader,
        at offset: Int
    ) -> WMFMetaHeader {
        WMFMetaHeader(
            type: reader.readUInt16(at: offset) ?? 0,
            headerSizeWords: reader.readUInt16(at: offset + 2) ?? 0,
            version: reader.readUInt16(at: offset + 4) ?? 0,
            sizeLow: reader.readUInt16(at: offset + 6) ?? 0,
            sizeHigh: reader.readUInt16(at: offset + 8) ?? 0,
            numberOfObjects: reader.readUInt16(at: offset + 10) ?? 0,
            maxRecord: reader.readUInt32(at: offset + 12) ?? 0,
            numberOfMembers: reader.readUInt16(at: offset + 16) ?? 0
        )
    }

    // MARK: - Record walk

    private struct WalkResult {
        var records: [WMFRawRecord]
        var diagnostics: [WMFDiagnostic]
        var bytesWalked: Int
        var maxRecordWords: Int
    }

    /// Walks generic records from `startOffset` to META_EOF (or the first
    /// malformed record). Each record: read the 6-byte `RecordSize`/
    /// `RecordFunction` header, then check `RecordSize >= 3 WORDs` and
    /// `RecordSize * 2 <= remaining` (overflow-checked) BEFORE trusting the
    /// record. On any violation, record a diagnostic and stop, keeping earlier
    /// records. Stops after META_EOF; reports trailing bytes or a missing EOF.
    private static func walkRecords(
        reader: WMFByteReader,
        startOffset: Int
    ) -> WalkResult {
        let total = reader.count
        var records: [WMFRawRecord] = []
        var diagnostics: [WMFDiagnostic] = []
        var offset = startOffset
        var sawEOF = false
        var maxRecordWords = 0

        while offset < total {
            // §8 memory guard: stop before the record array can grow without
            // bound on a hostile all-tiny-records file.
            if records.count >= recordCountLimit {
                diagnostics.append(.recordCountCapped(limit: recordCountLimit))
                break
            }

            let remaining = total - offset

            // Need 6 bytes: RecordSize(4) + RecordFunction(2).
            guard remaining >= 6,
                  let sizeWords = reader.readUInt32(at: offset),
                  let function = reader.readUInt16(at: offset + 4)
            else {
                diagnostics.append(
                    .truncatedRecordHeader(offset: offset, remaining: remaining)
                )
                break
            }

            // A record cannot be smaller than its own 3-WORD header.
            if sizeWords < minRecordWords {
                diagnostics.append(
                    .recordSizeTooSmall(offset: offset, sizeWords: sizeWords)
                )
                break
            }

            // byteSize = RecordSize * 2, overflow-checked (§8). On a 64-bit Int
            // the multiply cannot overflow for a UInt32 input; the check is kept
            // so the arithmetic is provably safe rather than merely assumed.
            let (byteSize, mulOverflow) = Int(sizeWords).multipliedReportingOverflow(by: 2)
            if mulOverflow || byteSize > remaining {
                diagnostics.append(
                    .recordSizeExceedsRemaining(
                        offset: offset,
                        byteSize: byteSize,
                        remaining: remaining
                    )
                )
                break
            }

            records.append(
                WMFRawRecord(function: function, sizeWords: sizeWords, offset: offset)
            )
            if Int(sizeWords) > maxRecordWords {
                maxRecordWords = Int(sizeWords)
            }
            offset += byteSize

            if function == eofFunction {
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
            // Ran off the end cleanly but never hit META_EOF.
            diagnostics.append(.missingEOF)
        }

        return WalkResult(
            records: records,
            diagnostics: diagnostics,
            bytesWalked: offset,
            maxRecordWords: maxRecordWords
        )
    }
}
