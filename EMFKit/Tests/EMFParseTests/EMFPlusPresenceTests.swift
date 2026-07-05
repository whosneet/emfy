import Foundation
import Testing
@testable import EMFParse

// MARK: - EMF+ fixture builders

/// Builds one EMF+ record's bytes ([MS-EMFPLUS] §2.3): Type (u16), Flags
/// (u16), Size (u32, total incl. this 12-byte header), DataSize (u32), then
/// `data`. `sizeOverride` writes a lying Size while keeping the real body,
/// for the hostile cases. `data` is padded implicitly only by the caller.
private func emfPlusRecord(
    type: UInt16,
    flags: UInt16 = 0,
    data: [UInt8] = [],
    dataSizeOverride: UInt32? = nil,
    sizeOverride: UInt32? = nil
) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(sizeOverride ?? UInt32(12 + data.count))
    b.appendUInt32(dataSizeOverride ?? UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

/// Wraps an EMF+ record stream in an EMR_COMMENT_EMFPLUS record
/// ([MS-EMF] §2.3.3.4): Type (70), nSize, DataSize (u32), CommentIdentifier
/// (u32), then the stream. DataSize counts from the identifier, so it is
/// `4 + stream.count`. Pass `identifier` to forge a non-EMF+ comment.
private func emfPlusComment(
    stream: [UInt8],
    identifier: UInt32 = 0x2B46_4D45   // "EMF+"
) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(identifier)
    payload.appendBytes(stream)
    let data = payload.bytes                      // identifier + stream

    var b = FixtureBuilder()
    b.appendUInt32(70)                            // 0  iType = EMR_COMMENT
    b.appendUInt32(UInt32(8 + 4 + data.count))    // 4  nSize = hdr + DataSize + data
    b.appendUInt32(UInt32(data.count))            // 8  DataSize (from identifier on)
    b.appendBytes(data)                           // 12 identifier + EMF+ stream
    return b.bytes
}

/// Builds a clean file (108-byte header + the given record blobs + EOF) and
/// parses it, returning the file for `emfPlusPresence()` queries.
private func parseFile(records: [[UInt8]]) throws -> EMFFile {
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    for record in records {
        fixture.appendBytes(record)
    }
    fixture.appendBytes(FixtureBuilder.eof())
    return try EMFFile.parse(fixture.data)
}

// EMF+ record type ids used across the fixtures.
private let emfPlusHeader: UInt16 = 0x4001
private let emfPlusEndOfFile: UInt16 = 0x4002
private let emfPlusSetAntiAliasMode: UInt16 = 0x4021   // state/property, non-drawing
private let emfPlusFillRects: UInt16 = 0x400A          // drawing

@Suite("EMF+ presence classifier")
struct EMFPlusPresenceTests {

    // MARK: - Verdict cases (hand-built streams)

    @Test("Header + SetAntiAliasMode + EndOfFile → shellOnly")
    func shellOnlyStream() throws {
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + emfPlusRecord(type: emfPlusSetAntiAliasMode)
            + emfPlusRecord(type: emfPlusEndOfFile)
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    @Test("stream containing FillRects (0x400A) → drawingContent")
    func drawingStream() throws {
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + emfPlusRecord(type: emfPlusFillRects, data: [UInt8](repeating: 0, count: 8))
            + emfPlusRecord(type: emfPlusEndOfFile)
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .drawingContent)
    }

    @Test("drawing id in the SECOND of two comments → drawingContent")
    func drawingInSecondComment() throws {
        let first = emfPlusComment(
            stream: emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
                + emfPlusRecord(type: emfPlusSetAntiAliasMode)
        )
        let second = emfPlusComment(
            stream: emfPlusRecord(type: emfPlusFillRects, data: [UInt8](repeating: 0, count: 8))
                + emfPlusRecord(type: emfPlusEndOfFile)
        )
        let file = try parseFile(records: [first, second])
        #expect(file.emfPlusPresence() == .drawingContent)
    }

    @Test("no comment records at all → none")
    func noComments() throws {
        // A plain SETMAPMODE record and nothing EMF+.
        let mapMode = FixtureBuilder.record(type: 17, size: 12)
        let file = try parseFile(records: [mapMode])
        #expect(file.emfPlusPresence() == .none)
    }

    @Test("non-EMFPLUS comment (GDIC identifier) alone → none")
    func nonEMFPlusComment() throws {
        // "GDIC" identifier — a public GDI comment, not EMF+. Its "stream"
        // bytes even mimic a drawing record; the wrong identifier must make the
        // whole comment ignored.
        let gdic = emfPlusComment(
            stream: emfPlusRecord(type: emfPlusFillRects, data: [UInt8](repeating: 0, count: 8)),
            identifier: 0x4349_4447   // "GDIC"
        )
        let file = try parseFile(records: [gdic])
        #expect(file.emfPlusPresence() == .none)
    }

    // MARK: - Hostile streams (§8: safe stop, keep verdict, never hang)

    @Test("truncated EMF+ header mid-comment → safe stop, shellOnly kept")
    func truncatedHeaderMidComment() throws {
        // A valid non-drawing record, then an 8-byte fragment — 4-aligned (so
        // the OUTER comment record stays walk-valid) but shorter than a 12-byte
        // EMF+ header, and its low 2 bytes spell a drawing id (0x400A). The
        // scan must stop at the fragment (no full header fits) and keep the
        // shell verdict, never mistaking the fragment for a drawing record.
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + [0x0A, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]   // 8 bytes: not a full header
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    @Test("truncated header as the ONLY record → shellOnly, no crash")
    func truncatedHeaderOnly() throws {
        // A comment whose entire stream is a sub-header fragment: the comment
        // is a valid EMF+ comment (identifier present) so the verdict is
        // shellOnly, and the scan reads no records without hanging or crashing.
        let stream: [UInt8] = [0x0A, 0x40, 0x00, 0x00]   // 4 bytes only
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    @Test("Size = 0 hostile record → no hang, safe stop")
    func zeroSizeRecord() throws {
        // A well-formed non-drawing record, then a record whose Size field is 0.
        // A naive walk would advance by 0 and loop forever; the >= 12 guard
        // must stop instead. If this test returns at all, there is no hang.
        let zeroSized = emfPlusRecord(
            type: emfPlusFillRects,           // drawing id, but unreachable past the bad size
            data: [UInt8](repeating: 0, count: 8),
            sizeOverride: 0
        )
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + zeroSized
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        // The FillRects after the zero-size record must never be reached.
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    @Test("Size lying past the comment end → safe stop, no false drawing verdict")
    func sizeLyingPastEnd() throws {
        // A non-drawing record whose Size claims far more than the stream holds.
        // The over-long Size must stop the scan (offset + size > end), and the
        // drawing record physically appended after it must NOT be counted —
        // the lying record's declared body swallows those bytes, so a correct
        // bounds check refuses to walk into them.
        let lying = emfPlusRecord(
            type: emfPlusHeader,
            flags: 0x0001,
            data: [UInt8](repeating: 0, count: 16),
            sizeOverride: 4096
        )
        let stream = lying
            + emfPlusRecord(type: emfPlusFillRects, data: [UInt8](repeating: 0, count: 8))
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    // MARK: - Fragmented drawing record (header valid, body overruns comment)

    @Test("drawing header whose Size overruns the comment → drawingContent")
    func drawingHeaderOverrunsComment() throws {
        // A single DrawImage (0x401A) record whose 12-byte header is valid
        // (readable type, Size >= 12, 4-aligned) but whose declared Size runs
        // far past this comment's extent — the shape of a real EMF+ stream
        // fragmented across consecutive EMR_COMMENT_EMFPLUS records. The type is
        // decisive even though the body does not fit: this MUST report drawing
        // content (it reports .shellOnly before the fix, because the old extent
        // check ran before the type was ever consulted).
        let drawing = emfPlusRecord(
            type: 0x401A,                                 // DrawImage — a drawing record
            data: [UInt8](repeating: 0, count: 8),
            sizeOverride: 4096                            // body overruns the comment
        )
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + drawing
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .drawingContent)
    }

    @Test("NON-drawing header overrunning the comment the same way → shellOnly")
    func nonDrawingHeaderOverrunsComment() throws {
        // The same overrun shape but a NON-drawing type (SetAntiAliasMode): its
        // header carries no verdict, so the overrun stops the scan and the
        // verdict stays shellOnly — the fix must not flip non-drawing overruns.
        let nonDrawing = emfPlusRecord(
            type: emfPlusSetAntiAliasMode,                // 0x4021 — non-drawing
            data: [UInt8](repeating: 0, count: 8),
            sizeOverride: 4096
        )
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + nonDrawing
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    @Test("Size not 4-aligned → safe stop")
    func sizeNotAligned() throws {
        let misaligned = emfPlusRecord(
            type: emfPlusFillRects,           // drawing id, unreachable past the bad size
            data: [UInt8](repeating: 0, count: 8),
            sizeOverride: 13                  // not a multiple of 4
        )
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + misaligned
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    // MARK: - Drawing-id boundary (classification table edges)

    /// Every id in 0x4009…0x401C, plus 0x4036 and 0x4037, is a drawing record;
    /// the ids just outside (0x4008 below, 0x401D above, 0x4035 and 0x4038
    /// around the two singletons) are not.
    @Test("drawing-id boundaries", arguments: [
        (UInt16(0x4008), false), (0x4009, true), (0x401C, true), (0x401D, false),
        (0x4035, false), (0x4036, true), (0x4037, true), (0x4038, false),
    ])
    func drawingIdBoundaries(id: UInt16, isDrawing: Bool) throws {
        let stream = emfPlusRecord(type: emfPlusHeader, flags: 0x0001, data: [UInt8](repeating: 0, count: 16))
            + emfPlusRecord(type: id, data: [UInt8](repeating: 0, count: 4))
            + emfPlusRecord(type: emfPlusEndOfFile)
        let file = try parseFile(records: [emfPlusComment(stream: stream)])
        #expect(file.emfPlusPresence() == (isDrawing ? .drawingContent : .shellOnly))
    }

    // MARK: - Corpus (committed files)

    /// gate-p2-star.emf is a LibreOffice dual-mode export: an EMF+ shell with
    /// no drawing records alongside the GDI records v1 renders. Verdict:
    /// shellOnly. Also pins the first EMF+ record header fields, empirically
    /// confirming the [MS-EMFPLUS] record layout the classifier relies on.
    @Test("gate-p2-star.emf → shellOnly; first EMF+ record header fields")
    func corpusStar() throws {
        let data = try requireCorpus("gate-p2-star.emf")
        let file = try EMFFile.parse(data)
        #expect(file.emfPlusPresence() == .shellOnly)

        // First EMR_COMMENT is at file offset 108 (right after the 108-byte
        // header) and its first EMF+ record must decode as Header/dual.
        let comment = try #require(file.records.first { $0.type == 70 })
        #expect(comment.offset == 108)
        let slice = RecordSlice(reader: file.reader, record: comment)
        #expect(slice.u32(12) == 0x2B46_4D45)          // CommentIdentifier "EMF+"
        #expect(slice.u16(16) == 0x4001)                // Type
        #expect(slice.u16(18) == 0x0001)                // Flags (dual)
        #expect(slice.u32(20) == 28)                    // Size
        #expect(slice.u32(24) == 16)                    // DataSize
    }

    /// gate-p4-text.emf is likewise a LibreOffice dual-mode export: shell only.
    @Test("gate-p4-text.emf → shellOnly")
    func corpusText() throws {
        let data = try requireCorpus("gate-p4-text.emf")
        let file = try EMFFile.parse(data)
        #expect(file.emfPlusPresence() == .shellOnly)
    }

    /// handmade-strokes-paths.emf is a pure hand-authored GDI file with no
    /// EMF+ comments at all: none.
    @Test("handmade-strokes-paths.emf → none")
    func corpusHandmade() throws {
        let data = try requireCorpus("handmade-strokes-paths.emf")
        let file = try EMFFile.parse(data)
        #expect(file.emfPlusPresence() == .none)
    }
}
