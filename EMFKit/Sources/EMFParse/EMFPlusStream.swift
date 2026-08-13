import Foundation

/// The decoded EmfPlusHeader control record ([MS-EMFPLUS] §2.3.3.3), present
/// when the EMF+ stream opens with one. All numeric fields are kept raw; higher
/// layers interpret `version` (an EmfPlusGraphicsVersion, e.g. 0xDBC01002).
public struct EMFPlusHeaderInfo: Sendable, Equatable {
    /// `Version`: the raw EmfPlusGraphicsVersion word ([MS-EMFPLUS] §2.2.2.19).
    public var version: UInt32
    /// EMF+ Dual: the EmfPlusHeader record-header `Flags` bit 0x0001. When set,
    /// the metafile carries a complete GDI (EMF) description alongside the EMF+
    /// one ([MS-EMFPLUS] §2.3.3.3).
    public var isDual: Bool
    /// The `EmfPlusFlags` V bit 0x00000001: recorded for a video-display
    /// reference device (clear = printer) ([MS-EMFPLUS] §2.3.3.3).
    public var isVideoDisplay: Bool
    /// `LogicalDpiX`: horizontal resolution the metafile was recorded for, in
    /// pixels per inch.
    public var logicalDpiX: UInt32
    /// `LogicalDpiY`: vertical resolution the metafile was recorded for.
    public var logicalDpiY: UInt32

    public init(
        version: UInt32,
        isDual: Bool,
        isVideoDisplay: Bool,
        logicalDpiX: UInt32,
        logicalDpiY: UInt32
    ) {
        self.version = version
        self.isDual = isDual
        self.isVideoDisplay = isVideoDisplay
        self.logicalDpiX = logicalDpiX
        self.logicalDpiY = logicalDpiY
    }
}

/// A non-fatal issue found while reassembling or walking the EMF+ record stream.
///
/// Mirrors `EMFDiagnostic` and its log-and-skip model (primer §8): a malformed
/// EMF+ record stops the walk and everything walked so far is kept — the file is
/// never failed on EMF+ content. `streamOffset` values are offsets into the
/// reassembled stream buffer (a single logical record can span several comments,
/// so there is no single file offset for it); `recordOffset` values are file
/// offsets of the containing EMR_COMMENT record.
public enum EMFPlusDiagnostic: Sendable, Equatable {
    /// An EMR_COMMENT_EMFPLUS declared a `DataSize` running past its own record
    /// extent; the stream contribution was clamped to what the record holds.
    /// `keptStreamBytes` is how many stream bytes were actually taken.
    case commentDataSizeClamped(recordOffset: Int, declaredDataSize: UInt32, keptStreamBytes: Int)
    /// An EMF+ record's `Size` was below the 12-byte header minimum. The walk
    /// stops. `size` is the bad value.
    case recordSizeTooSmall(streamOffset: Int, size: UInt32)
    /// An EMF+ record's `Size` was not a multiple of 4. The walk stops.
    case recordSizeNotAligned(streamOffset: Int, size: UInt32)
    /// An EMF+ record's `DataSize` exceeded `Size` - 12 (the data cannot fit in
    /// the record's own declared size). The walk stops.
    case recordDataSizeExceedsSize(streamOffset: Int, size: UInt32, dataSize: UInt32)
    /// An EMF+ record's `DataSize` ran past the end of the reassembled stream.
    /// The walk stops WITHOUT emitting the truncated record. `availableBytes` is
    /// how many bytes actually remained from the record start.
    case recordDataTruncated(streamOffset: Int, declaredDataSize: UInt32, availableBytes: Int)
    /// Bytes remained at the end of the stream but were too few to hold a
    /// 12-byte record header. `count` is how many.
    case trailingBytes(count: Int)
    /// EMF+ comments were present but the stream's first record was not
    /// EmfPlusHeader (0x4001) — or the stream held no records. The header is
    /// left `nil`; the walk still keeps every record ([MS-EMFPLUS] §2.3.3.3
    /// requires EmfPlusHeader to be first). Not raised for pure-GDI files.
    case headerRecordMissing
    /// The first record was EmfPlusHeader but its `Size` was not the required
    /// 0x1C ([MS-EMFPLUS] §2.3.3.3). The header is still best-effort decoded.
    case headerUnexpectedSize(size: UInt32)
    /// The first record was EmfPlusHeader but its `DataSize` was not the
    /// required 0x10 ([MS-EMFPLUS] §2.3.3.3). Still best-effort decoded.
    case headerUnexpectedDataSize(dataSize: UInt32)
}

/// The reassembled and walked EMF+ record stream of an `EMFFile`: the records,
/// the decoded header (if any), diagnostics, and exact byte accounting.
///
/// Produced by `EMFFile.emfPlusStream()`. For a pure-GDI file (no EMF+ comments)
/// every collection is empty, `header` is `nil`, and all three counts are 0.
public struct EMFPlusStream: Sendable, Equatable {
    /// Every EMF+ record walked out of the reassembled stream, in stream order.
    /// Each record carries `sourceRecordIndex`, the `EMFFile.records` position of
    /// the comment its header started in — the anchor EMF+ playback uses to
    /// interleave GDI records after an EmfPlusGetDC ([MS-EMFPLUS] §1.3.1).
    public let records: [EMFPlusRecord]
    /// The decoded EmfPlusHeader, or `nil` when the stream does not open with
    /// one (see `EMFPlusDiagnostic.headerRecordMissing`).
    public let header: EMFPlusHeaderInfo?
    /// Non-fatal issues found during reassembly and the walk (empty when clean).
    public let diagnostics: [EMFPlusDiagnostic]
    /// Total bytes in the reassembled stream — the sum of every EMF+ comment's
    /// clamped payload contribution.
    public let assembledByteCount: Int
    /// Bytes accounted for by successfully walked records: the offset the walk
    /// reached. Always equals `assembledByteCount - leftoverByteCount`.
    public let bytesConsumed: Int
    /// Bytes left unwalked after the last good record — a malformed/truncated
    /// stop or a sub-header tail. Always `assembledByteCount - bytesConsumed`.
    public let leftoverByteCount: Int

    init(
        records: [EMFPlusRecord],
        header: EMFPlusHeaderInfo?,
        diagnostics: [EMFPlusDiagnostic],
        assembledByteCount: Int,
        bytesConsumed: Int,
        leftoverByteCount: Int
    ) {
        self.records = records
        self.header = header
        self.diagnostics = diagnostics
        self.assembledByteCount = assembledByteCount
        self.bytesConsumed = bytesConsumed
        self.leftoverByteCount = leftoverByteCount
    }
}

extension EMFFile {
    /// Reassembles the EMF+ record stream carried inside this file's
    /// EMR_COMMENT_EMFPLUS records and walks it into `[EMFPlusRecord]`.
    ///
    /// EMF+ data lives inside EMR_COMMENT (type 70) records whose 4-byte
    /// identifier is 0x2B464D45 ("EMF+"); a single logical EMF+ record routinely
    /// spans consecutive such comments, so their payloads are concatenated into
    /// one buffer before the [MS-EMFPLUS] §2.3 12-byte-header walk. Never throws
    /// and never affects `parse(_:)`: all reads go through the bounds-checked
    /// `RecordSlice`/`ByteReader`, and any malformed EMF+ record stops the walk
    /// while keeping everything already produced (primer §8, log-and-skip).
    public func emfPlusStream() -> EMFPlusStream {
        let assembly = assembleEMFPlusStream()
        let walk = Self.walkAssembledStream(assembly.buffer, segments: assembly.segments)
        let header = Self.decodeHeaderInfo(
            from: walk.records,
            sawEMFPlusComment: assembly.sawEMFPlusComment
        )

        return EMFPlusStream(
            records: walk.records,
            header: header.info,
            diagnostics: assembly.diagnostics + walk.diagnostics + header.diagnostics,
            assembledByteCount: assembly.buffer.count,
            bytesConsumed: walk.consumed,
            leftoverByteCount: assembly.buffer.count - walk.consumed
        )
    }

    // MARK: - Pass 1: reassembly

    /// Concatenates the EMF+ stream bytes of every EMR_COMMENT_EMFPLUS record,
    /// in file order, into one contiguous buffer, and records where each
    /// contributing comment's bytes start in that buffer. A comment whose
    /// `DataSize` overruns its record is clamped (with a diagnostic). Bounded by
    /// construction: the buffer never exceeds the sum of the comment payloads,
    /// itself at most the file size.
    ///
    /// `segments` is the ascending (by `streamStart`) boundary list mapping each
    /// contributed run of stream bytes back to the `EMFFile.records` index of its
    /// source comment, so the walk can stamp every EMF+ record with the source
    /// position [MS-EMFPLUS] §1.3.1 GetDC arbitration needs.
    private func assembleEMFPlusStream()
        -> (buffer: Data,
            segments: [(streamStart: Int, recordIndex: Int)],
            diagnostics: [EMFPlusDiagnostic],
            sawEMFPlusComment: Bool) {
        var assembled = Data()
        var segments: [(streamStart: Int, recordIndex: Int)] = []
        var diagnostics: [EMFPlusDiagnostic] = []
        var sawEMFPlusComment = false

        for (index, record) in records.enumerated() where record.type == Self.commentType {
            let slice = RecordSlice(reader: reader, record: record)

            // EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4): DataSize (u32) at record
            // offset 8, CommentIdentifier (u32) at offset 12. The identifier must
            // be readable and equal "EMF+" for this to be an EMF+ comment.
            guard let dataSize = slice.u32(8),
                  let identifier = slice.u32(Self.commentIdentifierOffset),
                  identifier == Self.emfPlusIdentifier
            else {
                continue
            }
            sawEMFPlusComment = true

            // The comment data spans [12, 12 + DataSize); the EMF+ stream is the
            // part past the 4-byte identifier, [16, 12 + DataSize), clamped to
            // the record's own extent. `12 + Int(dataSize)` cannot overflow: a
            // UInt32 widened to Int on a 64-bit platform.
            let declaredEnd = Self.commentIdentifierOffset + Int(dataSize)
            let streamEnd = min(declaredEnd, slice.size)
            if declaredEnd > slice.size {
                diagnostics.append(
                    .commentDataSizeClamped(
                        recordOffset: record.offset,
                        declaredDataSize: dataSize,
                        keptStreamBytes: max(0, streamEnd - Self.emfPlusStreamOffset)
                    )
                )
            }

            let length = streamEnd - Self.emfPlusStreamOffset
            if length > 0,
               let segment = slice.bytes(at: Self.emfPlusStreamOffset, length: length) {
                // Boundary: this comment's payload starts at the current buffer
                // end. Recorded only when bytes are actually appended, so a
                // comment that contributes nothing never enters the map and
                // `streamStart` stays strictly increasing.
                segments.append((streamStart: assembled.count, recordIndex: index))
                assembled.append(segment)
            }
        }

        return (assembled, segments, diagnostics, sawEMFPlusComment)
    }

    // MARK: - Pass 2: walk

    /// Walks the reassembled buffer into records. Each iteration validates the
    /// 12-byte header (`Size` >= 12, 4-aligned, `DataSize` <= `Size` - 12) and
    /// that the data is fully present BEFORE emitting; any violation records a
    /// diagnostic and stops, keeping earlier records. The loop only ever advances
    /// by a validated, non-zero amount (>= 12), so it cannot hang. `segments`
    /// resolves each record's header offset to the source-comment records-index
    /// stamped on `EMFPlusRecord.sourceRecordIndex`.
    private static func walkAssembledStream(
        _ assembled: Data,
        segments: [(streamStart: Int, recordIndex: Int)]
    ) -> (records: [EMFPlusRecord], diagnostics: [EMFPlusDiagnostic], consumed: Int) {
        // Read scalars through a start-index-safe reader; slice `assembled` (a
        // freshly built, zero-based Data) for record bodies so each `data` is a
        // no-copy slice sharing the one assembled buffer.
        let streamReader = ByteReader(assembled)
        let count = streamReader.count
        var records: [EMFPlusRecord] = []
        var diagnostics: [EMFPlusDiagnostic] = []
        var offset = 0
        var stoppedEarly = false

        while offset + Self.emfPlusRecordHeaderSize <= count {
            // The 12 header bytes are guaranteed present by the loop condition.
            guard let type = streamReader.readUInt16(at: offset),
                  let flags = streamReader.readUInt16(at: offset + 2),
                  let size = streamReader.readUInt32(at: offset + 4),
                  let dataSize = streamReader.readUInt32(at: offset + 8)
            else {
                stoppedEarly = true
                break
            }

            let recordSize = Int(size)
            if recordSize < Self.emfPlusRecordHeaderSize {
                diagnostics.append(.recordSizeTooSmall(streamOffset: offset, size: size))
                stoppedEarly = true
                break
            }
            if recordSize % 4 != 0 {
                diagnostics.append(.recordSizeNotAligned(streamOffset: offset, size: size))
                stoppedEarly = true
                break
            }
            if Int(dataSize) > recordSize - Self.emfPlusRecordHeaderSize {
                diagnostics.append(
                    .recordDataSizeExceedsSize(streamOffset: offset, size: size, dataSize: dataSize)
                )
                stoppedEarly = true
                break
            }

            // The RecordData must be fully present before the record is emitted.
            let remaining = count - offset
            let need = Self.emfPlusRecordHeaderSize + Int(dataSize)
            if need > remaining {
                diagnostics.append(
                    .recordDataTruncated(
                        streamOffset: offset,
                        declaredDataSize: dataSize,
                        availableBytes: remaining
                    )
                )
                stoppedEarly = true
                break
            }

            let dataStart = offset + Self.emfPlusRecordHeaderSize
            records.append(
                EMFPlusRecord(
                    type: type,
                    flags: flags,
                    declaredSize: size,
                    declaredDataSize: dataSize,
                    data: assembled[dataStart ..< dataStart + Int(dataSize)],
                    sourceRecordIndex: Self.sourceCommentIndex(forStreamOffset: offset, in: segments)
                )
            )

            // Advance by Size, clamped to the buffer: a final record whose
            // alignment padding is cut off still moves the walk to the end (its
            // data was complete), keeping the byte accounting exact.
            offset += min(recordSize, remaining)
        }

        // Trailing bytes are only "trailing" when the walk ran to the end
        // cleanly; an early malformed/truncated stop already explains the
        // leftover through its own diagnostic.
        if !stoppedEarly {
            let trailing = count - offset
            if trailing > 0 {
                diagnostics.append(.trailingBytes(count: trailing))
            }
        }

        return (records, diagnostics, offset)
    }

    /// Resolves a walked record's stream-buffer header offset to the
    /// `EMFFile.records` index of the EMR_COMMENT_EMFPLUS whose payload
    /// contributed the header's FIRST byte — the last `segments` entry whose
    /// `streamStart` is <= `offset` (the list is ascending by `streamStart`).
    /// Falls back to the first segment for the degenerate empty / all-greater
    /// cases, unreachable while any record exists because the first contributing
    /// comment always starts the buffer at offset 0.
    private static func sourceCommentIndex(
        forStreamOffset offset: Int,
        in segments: [(streamStart: Int, recordIndex: Int)]
    ) -> Int {
        var low = 0
        var high = segments.count - 1
        var result = segments.first?.recordIndex ?? 0
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].streamStart <= offset {
                result = segments[mid].recordIndex
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    // MARK: - Header decode

    /// Decodes the EmfPlusHeader fields when the first walked record is
    /// EmfPlusHeader (0x4001). A first record of any other type — or none — with
    /// EMF+ comments present yields `headerRecordMissing` and a `nil` header;
    /// a pure-GDI file (no EMF+ comments) yields a `nil` header and no
    /// diagnostic. Header Size/DataSize MUSTs are checked but never fatal
    /// ([MS-EMFPLUS] §2.3.3.3).
    private static func decodeHeaderInfo(
        from records: [EMFPlusRecord],
        sawEMFPlusComment: Bool
    ) -> (info: EMFPlusHeaderInfo?, diagnostics: [EMFPlusDiagnostic]) {
        guard let first = records.first, first.type == Self.emfPlusHeaderType else {
            return (nil, sawEMFPlusComment ? [.headerRecordMissing] : [])
        }

        var diagnostics: [EMFPlusDiagnostic] = []
        if first.declaredSize != Self.emfPlusHeaderSize {
            diagnostics.append(.headerUnexpectedSize(size: first.declaredSize))
        }
        if first.declaredDataSize != Self.emfPlusHeaderDataSize {
            diagnostics.append(.headerUnexpectedDataSize(dataSize: first.declaredDataSize))
        }

        // RecordData ([MS-EMFPLUS] §2.3.3.3): Version (u32) at +0, EmfPlusFlags
        // (u32) at +4, LogicalDpiX (u32) at +8, LogicalDpiY (u32) at +12. Read
        // start-index-safely; a short DataSize leaves absent fields at 0 without
        // force-unwrapping.
        let body = ByteReader(first.data)
        let version = body.readUInt32(at: 0) ?? 0
        let emfPlusFlags = body.readUInt32(at: 4) ?? 0
        let dpiX = body.readUInt32(at: 8) ?? 0
        let dpiY = body.readUInt32(at: 12) ?? 0

        let info = EMFPlusHeaderInfo(
            version: version,
            isDual: (first.flags & Self.emfPlusDualFlag) != 0,
            isVideoDisplay: (emfPlusFlags & Self.emfPlusVideoDisplayFlag) != 0,
            logicalDpiX: dpiX,
            logicalDpiY: dpiY
        )
        return (info, diagnostics)
    }

    // MARK: - Constants

    /// EmfPlusHeader type id ([MS-EMFPLUS] §2.1.1.1 / §2.3.3.3).
    static let emfPlusHeaderType: UInt16 = 0x4001
    /// EmfPlusHeader `Size` MUST value ([MS-EMFPLUS] §2.3.3.3).
    static let emfPlusHeaderSize: UInt32 = 0x1C
    /// EmfPlusHeader `DataSize` MUST value ([MS-EMFPLUS] §2.3.3.3).
    static let emfPlusHeaderDataSize: UInt32 = 0x10
    /// EmfPlusHeader record-header `Flags` EMF+ Dual bit ([MS-EMFPLUS] §2.3.3.3).
    static let emfPlusDualFlag: UInt16 = 0x0001
    /// EmfPlusHeader `EmfPlusFlags` video-display bit ([MS-EMFPLUS] §2.3.3.3).
    static let emfPlusVideoDisplayFlag: UInt32 = 0x0000_0001
}
