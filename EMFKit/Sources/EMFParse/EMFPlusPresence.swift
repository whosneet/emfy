import Foundation

/// How much EMF+ (GDI+) content a file carries, judged from its EMF+ record
/// stream — the signal the viewer needs to give an honest partial-support
/// notice (primer §2: v1 renders GDI only and must never silently blank-render
/// an EMF+-only file).
///
/// EMF+ lives inside EMR_COMMENT records tagged with the "EMF+" identifier
/// ([MS-EMF] §2.3.3.4, EMR_COMMENT_EMFPLUS). Their payload is a stream of
/// EMF+ records ([MS-EMFPLUS] §2.3). The distinction that matters is whether
/// any *drawing* record is present: a file may carry only an EMF+ shell
/// (Header/EndOfFile plus state/property records) as a dual-mode companion to
/// its GDI records — which v1 renders faithfully from the GDI side — versus a
/// file whose actual picture is encoded as EMF+ draw calls, which v1 cannot
/// render and must flag.
public enum EMFPlusPresence: Sendable, Equatable {
    /// No "EMF+" comment records at all — a pure GDI file. v1 renders it in
    /// full; no notice is warranted.
    case none
    /// EMF+ comment records are present, but the stream contains no drawing
    /// records — only shell records (Header/EndOfFile) and state/property
    /// records. This is the dual-mode shell many converters emit alongside the
    /// GDI records; v1 renders the GDI side faithfully and needs no warning.
    case shellOnly
    /// The EMF+ stream contains at least one drawing record, so part of the
    /// picture is expressed in EMF+ that v1 does not render. The viewer should
    /// surface a "contains EMF+ content, partial rendering" notice.
    case drawingContent
}

extension EMFFile {
    /// Classifies this file's EMF+ content into `EMFPlusPresence`.
    ///
    /// Scans every EMR_COMMENT (type 70) record whose 4-byte comment
    /// identifier is 0x2B464D45 ("EMF+"), walks the EMF+ record stream inside
    /// each comment payload, and reports whether any drawing record appears.
    /// A drawing record anywhere → `.drawingContent`; EMF+ comments present but
    /// no drawing record → `.shellOnly`; no EMF+ comments → `.none`.
    ///
    /// Never throws and never affects `parse(_:)` — it reads the same walked
    /// records over the retained buffer through the bounds-checked `RecordSlice`
    /// (primer §8): a hostile comment payload cannot read outside its record,
    /// let alone the file, and a lying or zero-size EMF+ record stops the scan
    /// of that one comment without hanging or corrupting the verdict.
    public func emfPlusPresence() -> EMFPlusPresence {
        var sawEMFPlusComment = false

        for record in records where record.type == Self.commentType {
            let slice = RecordSlice(reader: reader, record: record)

            // EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4): DataSize (u32) at record
            // offset 8, then the comment data from offset 12; its first 4 bytes
            // are the CommentIdentifier. The identifier must be readable and
            // equal to "EMF+" for this to be an EMF+ comment at all.
            guard let dataSize = slice.u32(8),
                  let identifier = slice.u32(Self.commentIdentifierOffset),
                  identifier == Self.emfPlusIdentifier
            else {
                continue
            }
            sawEMFPlusComment = true

            // The EMF+ record stream begins right after the identifier
            // (offset 16). Its authoritative end is DataSize bytes past the
            // start of the comment data (offset 12), i.e. record offset
            // 12 + DataSize — clamped to the slice, which is itself clamped to
            // the file. `12 + DataSize` cannot overflow: DataSize is a UInt32
            // widened to Int on a 64-bit platform.
            let declaredEnd = Self.commentIdentifierOffset + Int(dataSize)
            let streamEnd = min(declaredEnd, slice.size)

            if scanEMFPlusStream(slice: slice, start: Self.emfPlusStreamOffset, end: streamEnd) {
                // A drawing record settles the verdict for the whole file; no
                // reason to scan further comments.
                return .drawingContent
            }
        }

        return sawEMFPlusComment ? .shellOnly : .none
    }

    /// Walks the EMF+ record stream in `[start, end)` (record-relative offsets)
    /// and returns `true` as soon as a drawing record is seen, else `false`.
    ///
    /// Each EMF+ record ([MS-EMFPLUS] §2.3, verified empirically against
    /// corpus/gate-p2-star.emf): Type (u16) at +0, Flags (u16) at +2, Size
    /// (u32, total record size including this 12-byte header, 4-aligned) at +4,
    /// DataSize (u32) at +8, then the data. This walk only reads Type and Size.
    ///
    /// §8: `Size` is bounds-checked against the stream extent before advancing.
    /// `Size` < 12 or not 4-aligned stops this comment's scan (the verdict keeps
    /// whatever was seen). A `Size` of 0 fails the `>= 12` check and stops — the
    /// loop only ever advances by a fully-validated `recordSize`, so it can
    /// never hang.
    ///
    /// The drawing-record type is consulted the moment a 12-byte header is
    /// readable and structurally sound (`Size >= 12`, 4-aligned), BEFORE the
    /// body-fits-in-`end` check: EMF+ streams are routinely fragmented across
    /// consecutive EMR_COMMENT_EMFPLUS records, so a drawing record's declared
    /// body legitimately overruns this one comment's extent. A drawing type is
    /// decisive regardless of where its body ends. For a NON-drawing type an
    /// overrun still stops the scan — its header carries no verdict, and the
    /// loop must not advance past `end` into bytes this comment does not own.
    private func scanEMFPlusStream(slice: RecordSlice, start: Int, end: Int) -> Bool {
        var offset = start
        // A full 12-byte EMF+ record header must fit before we trust it.
        while offset + Self.emfPlusRecordHeaderSize <= end {
            guard let type = slice.u16(offset),
                  let size = slice.u32(offset + 4)
            else {
                break
            }

            let recordSize = Int(size)
            // Structural validity of the header itself gates the type read.
            guard recordSize >= Self.emfPlusRecordHeaderSize,
                  recordSize % 4 == 0
            else {
                break
            }

            // A drawing record settles the verdict even when its body overruns
            // this comment (fragmented stream): the type alone is decisive.
            if Self.isEMFPlusDrawingRecord(type) {
                return true
            }

            // Non-drawing record: it must fit fully before we advance past it.
            guard offset + recordSize <= end else {
                break
            }
            offset += recordSize
        }
        return false
    }

    // MARK: - Constants

    /// EMR_COMMENT type id ([MS-EMF] §2.1.1).
    static let commentType: UInt32 = 70
    /// "EMF+" little-endian: the EMR_COMMENT_EMFPLUS comment identifier
    /// ([MS-EMF] §2.3.3.4).
    static let emfPlusIdentifier: UInt32 = 0x2B46_4D45
    /// Record-relative offset of the CommentIdentifier (first 4 bytes of the
    /// comment data, which starts at offset 12).
    static let commentIdentifierOffset = 12
    /// Record-relative offset where the EMF+ record stream begins (just past
    /// the 4-byte identifier).
    static let emfPlusStreamOffset = 16
    /// Every EMF+ record opens with a 12-byte Type/Flags/Size/DataSize header.
    static let emfPlusRecordHeaderSize = 12

    /// True when `type` is an EMF+ drawing record ([MS-EMFPLUS] RecordType
    /// enumeration, verified 2026-07-05): the contiguous drawing block
    /// 0x4009…0x401C (Clear, FillRects … DrawString), plus the two later
    /// drawing records 0x4036 (DrawDriverString) and 0x4037 (StrokeFillPath).
    /// Every other id — Header, EndOfFile, GetDC, object/property/state/
    /// transform/clip records — is non-drawing.
    static func isEMFPlusDrawingRecord(_ type: UInt16) -> Bool {
        (0x4009 ... 0x401C).contains(type) || type == 0x4036 || type == 0x4037
    }
}
