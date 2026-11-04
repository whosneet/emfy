import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - WMF / metafile abuse fixtures (primer §8, plan §3 W6)
//
// Deterministic, hand-authored HOSTILE WMF (and gzip-wrapped WMF) inputs, each
// driven END TO END through the exact path the app and Quick Look run:
//
//   OpenedMetafile.open → MetafileRenderer.prepare → MetafileRenderer.makeImage
//
// Every case proves the §8 contract: a malformed or adversarial metafile must
// not crash, hang, or over-allocate; the render completes and hands back a
// best-effort image. Each asserts a POSITIVE signal beyond survival — a
// neighbouring well-formed draw still rendering (the EMFPlusAbuseTests pattern),
// a render-log entry, a typed embedded-EMF rejection, or a bounded clamped
// canvas — never merely "didn't crash". The walker/reassembly-level TYPED
// diagnostics for these same inputs are asserted at the parse layer
// (WMFWalkerTests, WMFEmbeddedEMFTests); this suite proves they survive the full
// render path. Fixtures are built in code, never committed to corpus/.
@Suite("Metafile abuse (survival through the front door)")
struct MetafileAbuseTests {

    // MARK: - Little-endian byte helpers ([MS-WMF] §1.3.1)

    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A placeable WMF header: bbox (0,0,`w`,`h`), `inch` units/inch ([MS-WMF]
    /// §2.3.2.3). The checksum is advisory, so it is left zero.
    private static func placeable(w: Int16, h: Int16, inch: UInt16) -> [UInt8] {
        u32(0x9AC6_CDD7) + u16(0)
            + i16(0) + i16(0) + i16(w) + i16(h)
            + u16(inch) + u32(0) + u16(0)
    }

    /// An 18-byte META_HEADER with advisory fields zeroed ([MS-WMF] §2.3.2.2).
    private static func metaHeader() -> [UInt8] {
        u16(1) + u16(9) + u16(0x0300) + u16(0) + u16(0) + u16(0) + u32(0) + u16(0)
    }

    /// A generic record ([MS-WMF] §2.3): RecordSize (WORDs, header included),
    /// RecordFunction, then the body. `sizeWordsOverride` forges a lying
    /// RecordSize; otherwise it is `(6 + body.count) / 2`.
    private static func record(_ function: UInt16, _ body: [UInt8], sizeWordsOverride: UInt32? = nil) -> [UInt8] {
        u32(sizeWordsOverride ?? UInt32((6 + body.count) / 2)) + u16(function) + body
    }

    private static func eof() -> [UInt8] { record(0x0000, []) }

    /// The WMF GDI records that fill the canvas solid RED (window org/ext then a
    /// solid-red brush + a full-canvas rectangle). Used as the well-formed
    /// neighbour whose ink proves the renderer survived a hostile record.
    private static func redFillRecords(w: Int16 = 96, h: Int16 = 96) -> [[UInt8]] {
        [
            record(0x020B, i16(0) + i16(0)),                        // SETWINDOWORG (Y,X)
            record(0x020C, i16(h) + i16(w)),                        // SETWINDOWEXT (Y,X)
            record(0x02FC, u16(0) + [255, 0, 0, 0] + u16(0)),       // CREATEBRUSHINDIRECT red → slot 0
            record(0x012D, u16(0)),                                 // SELECTOBJECT 0
            record(0x041B, i16(h) + i16(w) + i16(0) + i16(0)),      // RECTANGLE (B,R,T,L)
        ]
    }

    /// One META_ESCAPE_ENHANCED_METAFILE "WMFC" chunk ([MS-WMF] §2.3.6.25).
    private static func wmfcChunk(
        _ chunk: [UInt8], recordCount: UInt32, remaining: UInt32, total: UInt32,
        currentRecordSize: UInt32? = nil
    ) -> [UInt8] {
        var body: [UInt8] = []
        body += u16(0x000F)                                  // EscapeFunction
        body += u16(UInt16(truncatingIfNeeded: 34 + chunk.count))  // ByteCount
        body += u32(0x4346_4D57)                             // CommentIdentifier "WMFC"
        body += u32(0x0000_0001)                             // CommentType
        body += u32(0x0001_0000)                             // Version
        body += u16(0)                                       // Checksum (advisory)
        body += u32(0)                                       // Flags
        body += u32(recordCount)                             // CommentRecordCount
        body += u32(currentRecordSize ?? UInt32(chunk.count))  // CurrentRecordSize
        body += u32(remaining)                               // RemainingBytes
        body += u32(total)                                   // EnhancedMetafileDataSize
        body += chunk
        return record(0x0626, body)
    }

    /// Splits `emf` into `count` consistent consecutive WMFC chunks that
    /// reassemble to `emf` ([MS-WMF] §2.3.6.25).
    private static func embeddedEscapes(_ emf: [UInt8], count: Int) -> [[UInt8]] {
        let total = UInt32(emf.count)
        var records: [[UInt8]] = []
        let base = max(2, ((emf.count / count) + 1) & ~1)
        var offset = 0
        var accumulated = 0
        for i in 0 ..< count {
            let end = i == count - 1 ? emf.count : min(emf.count, offset + base)
            let chunk = Array(emf[offset ..< end])
            accumulated += chunk.count
            records.append(wmfcChunk(chunk, recordCount: UInt32(count),
                                     remaining: total - UInt32(accumulated), total: total))
            offset = end
        }
        return records
    }

    /// Assembles a placeable WMF from `records`, appending META_EOF.
    private static func placeableWMF(w: Int16 = 96, h: Int16 = 96, inch: UInt16 = 96, _ records: [[UInt8]]) -> Data {
        var bytes = placeable(w: w, h: h, inch: inch) + metaHeader()
        for r in records { bytes += r }
        bytes += eof()
        return Data(bytes)
    }

    /// Assembles a standard (non-placeable) WMF from `records`, appending META_EOF.
    private static func standardWMF(_ records: [[UInt8]]) -> Data {
        var bytes = metaHeader()
        for r in records { bytes += r }
        bytes += eof()
        return Data(bytes)
    }

    // MARK: - Render helper

    /// Runs `data` through the full front door and returns the raster, the render
    /// log, and the prepared metafile. The `#require`s ARE the survival proof: a
    /// trap or hang would take the process down before any of them is reached.
    private func render(_ data: Data) throws -> (RasterizedImage, EMFRenderLog, MetafileRenderer.Prepared) {
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened), "prepare returned nil")
        let (image, log) = try #require(MetafileRenderer.makeImage(prepared), "makeImage returned nil")
        let raster = try #require(RasterizedImage(image), "could not rasterize")
        return (raster, log, prepared)
    }

    private static let center = (x: 40, y: 40, width: 16, height: 16)
    private func isRed(_ raster: RasterizedImage, in rect: (x: Int, y: Int, width: Int, height: Int) = center) -> Bool {
        raster.contains(in: rect) { $0.r > 160 && $0.g < 120 && $0.b < 120 }
    }
    private func hasUnimplemented(_ log: EMFRenderLog, type: UInt32) -> Bool {
        log.entries.contains { if case .unimplementedRecord(let t, _) = $0 { return t == type }; return false }
    }
    private func hasCanvasClamped(_ log: EMFRenderLog) -> Bool {
        log.entries.contains { if case .canvasClamped = $0 { return true }; return false }
    }

    // MARK: - Lying RecordSize ([MS-WMF] §2.3; walker guards in WMFFile.walkRecords)
    //
    // The typed walk diagnostics (recordSizeTooSmall / recordSizeExceedsRemaining
    // / truncatedRecordHeader) are asserted in WMFParseTests.WMFWalkerTests. Here
    // the POSITIVE signal is rendered: a lying size mid-file stops the walk AFTER
    // the records already seen, so a leading well-formed red fill still shows; in
    // the first record it stops the walk at once, so only the page (correct size,
    // no ink) is produced.

    /// A lying RecordSize AFTER a well-formed red fill: too small (0/1/2 WORDs),
    /// past the end, and overflow-sized. The walk stops at the bad record; the
    /// red fill that preceded it still renders.
    @Test("a lying RecordSize mid-file stops the walk but the records before it still render",
          arguments: [UInt32(0), 1, 2, 4096, 0xFFFF_FFFF])
    func lyingRecordSizeMidFile(_ sizeWords: UInt32) throws {
        let bad = Self.record(0x0324, [], sizeWordsOverride: sizeWords)   // POLYGON, forged size
        let data = Self.placeableWMF(Self.redFillRecords() + [bad] + Self.redFillRecords())
        let (raster, _, prepared) = try render(data)
        #expect(prepared.kind == .wmfRecords)
        #expect(raster.width == 96 && raster.height == 96)
        #expect(isRed(raster), "the red fill before the lying-size record should render")
    }

    /// A lying RecordSize in the FIRST record halts the walk immediately: no draw
    /// records play, so the red fill placed after it does NOT render — only the
    /// placeable page (correct size, white) is produced. Graceful degradation,
    /// not a blank-on-error.
    @Test("a lying RecordSize in the first record halts the walk, leaving the correct empty page",
          arguments: [UInt32(0), 2, 0xFFFF_FFFF])
    func lyingRecordSizeFirstRecord(_ sizeWords: UInt32) throws {
        let bad = Self.record(0x0324, [], sizeWordsOverride: sizeWords)
        let data = Self.placeableWMF([bad] + Self.redFillRecords())
        let (raster, _, prepared) = try render(data)
        #expect(prepared.kind == .wmfRecords)
        #expect(prepared.naturalSize == CGSize(width: 96, height: 96))
        #expect(raster.width == 96 && raster.height == 96)
        #expect(!isRed(raster), "the walk should have stopped before the red fill after the bad first record")
    }

    // MARK: - Huge and out-of-range object indices ([MS-WMF] §3.1.4.1)

    /// A SELECTOBJECT / DELETEOBJECT of a hostile index — 0x7FFF, a stock-bit
    /// index (0x8000), the 4096 cap itself, and above it — is bounded (the 4096
    /// object table never grows for a 32767 index) and the well-formed red fill
    /// still renders. The red fill is placed first so its brush slot is created
    /// before any churn.
    @Test("hostile select/delete indices are bounded and the file still renders",
          arguments: [UInt16(0x7FFF), 0x8000, 0x8008, 4096, 5000, 0xFFFF])
    func hostileObjectIndices(_ index: UInt16) throws {
        let records = Self.redFillRecords() + [
            Self.record(0x012D, Self.u16(index)),   // SELECTOBJECT index
            Self.record(0x01F0, Self.u16(index)),   // DELETEOBJECT index
        ]
        let (raster, _, prepared) = try render(Self.placeableWMF(records))
        #expect(prepared.kind == .wmfRecords)
        #expect(isRed(raster), "the red fill should render despite the hostile object index")
    }

    /// Creating past the 4096-slot object-table cap: the over-cap creator is
    /// logged (`.unimplementedRecord(0xFFFF)`) and the table never grows beyond
    /// the cap. Bounded time proves the bitset allocator stays O(1) at the cap
    /// rather than scanning (§8).
    @Test("creating past the object-table cap logs the cap and stays bounded")
    func objectTableCapReached() throws {
        let brush = Self.record(0x02FC, Self.u16(0) + [0, 0, 0, 0] + Self.u16(0))   // CREATEBRUSHINDIRECT
        var records: [[UInt8]] = []
        records.reserveCapacity(4100)
        for _ in 0 ..< 4097 { records.append(brush) }   // 4096 fill the table; the 4097th overflows

        let start = ContinuousClock.now
        let (_, log, _) = try render(Self.placeableWMF(records))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2), "object-table fill took \(elapsed)")
        #expect(hasUnimplemented(log, type: 0xFFFF), "the over-cap creator should log .unimplementedRecord(0xFFFF): \(log.entries)")
    }

    /// Selecting a valid-but-unallocated low slot drives the shared DC object
    /// guard: the renderer logs `.invalidObjectIndex` and keeps the current
    /// selection. The leading red fill still shows.
    @Test("selecting an unallocated slot surfaces .invalidObjectIndex")
    func selectUnallocatedSlot() throws {
        let records = Self.redFillRecords() + [Self.record(0x012D, Self.u16(10))]   // slot 10, never created
        let (raster, log, _) = try render(Self.placeableWMF(records))
        #expect(isRed(raster))
        #expect(log.entries.contains { if case .invalidObjectIndex = $0 { return true }; return false },
                "an unallocated SELECTOBJECT slot should log .invalidObjectIndex: \(log.entries)")
    }

    // MARK: - Minimum-size and truncated-body W4 record families ([MS-WMF] §2.3.1, §2.3.3, §2.3.5)
    //
    // Each W4 family (text, DIB, region, polypolygon, escape) is admitted by the
    // walker at its 3-WORD minimum or with a body too short for the record, then
    // its decoder's short-body guard must drop it without over-reading. A leading
    // well-formed red fill (the EMFPlusAbuseTests pattern) renders before the
    // hostile record, proving its short-body guard did not derail the file.

    static let w4Functions: [UInt16] = [
        0x02FB, 0x0521, 0x0A32,   // text: CREATEFONTINDIRECT, TEXTOUT, EXTTEXTOUT
        0x0F43, 0x0940, 0x0B41, 0x0D33,   // DIB: STRETCHDIB, DIBBITBLT, DIBSTRETCHBLT, SETDIBTODEV
        0x06FF, 0x0228, 0x0429,   // region: CREATEREGION, FILLREGION, FRAMEREGION
        0x0538, 0x0324,           // polypolygon, polygon
        0x0626,                   // escape: META_ESCAPE
    ]

    @Test("a minimum-size or truncated W4 record is skipped and the next record still renders",
          arguments: w4Functions, [0, 4])
    func truncatedW4Family(_ function: UInt16, _ bodyLen: Int) throws {
        let truncated = Self.record(function, [UInt8](repeating: 0, count: bodyLen))
        let data = Self.placeableWMF(Self.redFillRecords() + [truncated])
        let (raster, _, prepared) = try render(data)
        #expect(prepared.kind == .wmfRecords)
        #expect(isRed(raster), "the red fill before the truncated 0x\(String(function, radix: 16)) should render")
    }

    /// The two W4 families whose truncated form yields an explicit render-log
    /// note (a non-rendered positive signal): a short font → `.unimplemented`
    /// (0x02FB), a plain escape → `.unimplemented` (0x0626).
    @Test("a truncated font and a plain escape surface a render-log skip",
          arguments: [UInt16(0x02FB), 0x0626])
    func truncatedW4LogsSkip(_ function: UInt16) throws {
        let data = Self.placeableWMF(Self.redFillRecords() + [Self.record(function, [1, 2])])
        let (raster, log, _) = try render(data)
        #expect(isRed(raster))
        #expect(hasUnimplemented(log, type: UInt32(function)),
                "0x\(String(function, radix: 16)) should log .unimplementedRecord: \(log.entries)")
    }

    // MARK: - Lying or truncated embedded EMFs inside META_ESCAPE ([MS-WMF] §2.3.6.25)
    //
    // The typed reassembly rejections are asserted in
    // WMFParseTests.WMFEmbeddedEMFTests. Here each inconsistent sequence must
    // reach `.embeddedEMF == .rejected` through prepare and fall back to the WMF
    // records, which still render (red ink).

    /// Chunks whose EnhancedMetafileDataSize disagree are rejected; the records play.
    @Test("embedded chunks with disagreeing totals fall back to the WMF records")
    func embeddedTotalsDisagree() throws {
        let emf = Array(UInt8(0) ..< 60)
        let c0 = Self.wmfcChunk(Array(emf[0 ..< 30]), recordCount: 2, remaining: 30, total: 60)
        let c1 = Self.wmfcChunk(Array(emf[30 ..< 60]), recordCount: 2, remaining: 0, total: 999)   // lies
        let (raster, _, prepared) = try render(Self.placeableWMF([c0, c1] + Self.redFillRecords()))
        #expect(prepared.embeddedEMF == .rejected)
        #expect(prepared.kind == .wmfRecords)
        #expect(isRed(raster))
    }

    /// A chunk whose RemainingBytes lies is rejected; the records play.
    @Test("an embedded chunk whose RemainingBytes lies falls back to the WMF records")
    func embeddedRemainingBytesLies() throws {
        let emf = Array(UInt8(0) ..< 60)
        let c0 = Self.wmfcChunk(Array(emf[0 ..< 30]), recordCount: 2, remaining: 12345, total: 60)   // lies
        let c1 = Self.wmfcChunk(Array(emf[30 ..< 60]), recordCount: 2, remaining: 0, total: 60)
        let (raster, _, prepared) = try render(Self.placeableWMF([c0, c1] + Self.redFillRecords()))
        #expect(prepared.embeddedEMF == .rejected)
        #expect(isRed(raster))
    }

    /// An EnhancedMetafileDataSize of 64 MiB + 1 (past the reassembly cap) is
    /// rejected at the FIRST chunk — the buffer is never grown toward the claimed
    /// total, proving no hostile-driven allocation. The records play, bounded.
    @Test("an embedded total of 64 MiB + 1 is refused without allocating toward it")
    func embeddedTotalOverCap() throws {
        let overCap = UInt32(64 * 1024 * 1024 + 1)
        let chunk = Self.wmfcChunk([1, 2, 3, 4], recordCount: 1, remaining: overCap - 4, total: overCap)
        let start = ContinuousClock.now
        let (raster, _, prepared) = try render(Self.placeableWMF([chunk] + Self.redFillRecords()))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2), "an over-cap embedded total should be refused immediately, took \(elapsed)")
        #expect(prepared.embeddedEMF == .rejected)
        #expect(isRed(raster))
    }

    /// A chunk run that never reaches its declared total (an incomplete sequence)
    /// is rejected; the records play.
    @Test("an embedded sequence that never completes falls back to the WMF records")
    func embeddedNeverCompletes() throws {
        // One chunk declares a 1000-byte total but supplies 10 bytes and ends.
        let chunk = Self.wmfcChunk(Array(UInt8(1) ... 10), recordCount: 1, remaining: 990, total: 1000)
        let (raster, _, prepared) = try render(Self.placeableWMF([chunk] + Self.redFillRecords()))
        #expect(prepared.embeddedEMF == .rejected)
        #expect(isRed(raster))
    }

    /// A non-escape record interleaved mid-sequence ends the run early, so the
    /// total is never reached: rejected, records play.
    @Test("a non-escape record interleaved mid-sequence rejects the embedded EMF")
    func embeddedInterleavedRecord() throws {
        let emf = Array(UInt8(0) ..< 60)
        let c0 = Self.wmfcChunk(Array(emf[0 ..< 30]), recordCount: 2, remaining: 30, total: 60)
        let c1 = Self.wmfcChunk(Array(emf[30 ..< 60]), recordCount: 2, remaining: 0, total: 60)
        let interloper = Self.record(0x001E, [])   // META_SAVEDC between the two chunks
        let (raster, _, prepared) = try render(Self.placeableWMF([c0, interloper, c1] + Self.redFillRecords()))
        #expect(prepared.embeddedEMF == .rejected)
        #expect(isRed(raster))
    }

    /// A consistently reassembled embedded EMF that is ITSELF hostile (an absurd
    /// 2-million-pixel header bound) parses and plays — but through the EMF canvas
    /// caps, so the output is clamped and bounded, not a 2-Mpx allocation.
    @Test("a reassembled but hostile embedded EMF plays through the EMF canvas caps")
    func embeddedHostileEMFClamped() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 2_000_000, 50)   // ~2 M wide — far over the 16384 per-side cap
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 255)
        fixture.selectObject(1)
        fixture.rectangle(-5, -5, 100, 100)
        let emf = Array(fixture.data())

        let data = Self.placeableWMF(Self.embeddedEscapes(emf, count: 3))
        let (raster, log, prepared) = try render(data)
        #expect(prepared.embeddedEMF == .played)
        #expect(prepared.kind == .emf)
        #expect(raster.width <= 16_384 && raster.height <= 16_384, "the hostile EMF canvas must be clamped")
        #expect(hasCanvasClamped(log), "the clamp should be logged: \(log.entries)")
    }

    // MARK: - Hostile placeable headers ([MS-WMF] §2.3.2.3)

    /// Inch = 0 cannot drive a DPI scale; the canvas falls back to the logical
    /// span, still clamped and finite.
    @Test("a placeable Inch of 0 falls back to a bounded logical-unit canvas")
    func placeableInchZero() throws {
        let data = Self.placeableWMF(w: 300, h: 200, inch: 0, Self.redFillRecords(w: 300, h: 200))
        let (raster, _, prepared) = try render(data)
        #expect(prepared.naturalSize == CGSize(width: 300, height: 200))
        #expect(raster.width == 300 && raster.height == 200)
        #expect(isRed(raster))
    }

    /// Inch = 1 with a 32767-wide BoundingBox would be ~3.1 Mpx/side; the canvas
    /// is clamped to the 16384 per-side cap.
    @Test("a placeable Inch of 1 with a 32767 BoundingBox clamps to the per-side cap")
    func placeableHugeBoundingBox() throws {
        let data = Self.placeableWMF(w: 32767, h: 1, inch: 1, [])
        let (raster, _, prepared) = try render(data)
        #expect(prepared.naturalSize.width <= 16_384 && prepared.naturalSize.width >= 1)
        #expect(prepared.naturalSize.height >= 1)
        #expect(raster.width <= 16_384 && raster.width >= 1)
    }

    /// A negative / inverted BoundingBox keeps a finite, clamped canvas and renders.
    @Test("a negative or inverted BoundingBox stays bounded and renders",
          arguments: [(Int16(0), Int16(0), Int16(-100), Int16(-80)), (100, 80, 0, 0)])
    func placeableInvertedBoundingBox(_ box: (Int16, Int16, Int16, Int16)) throws {
        var bytes = Self.u32(0x9AC6_CDD7) + Self.u16(0)
            + Self.i16(box.0) + Self.i16(box.1) + Self.i16(box.2) + Self.i16(box.3)
            + Self.u16(96) + Self.u32(0) + Self.u16(0)
        bytes += Self.metaHeader()
        for r in Self.redFillRecords() { bytes += r }
        bytes += Self.eof()
        let (raster, _, prepared) = try render(Data(bytes))
        #expect(prepared.naturalSize.width >= 1 && prepared.naturalSize.height >= 1)
        #expect(prepared.naturalSize.width <= 16_384 && prepared.naturalSize.height <= 16_384)
        #expect(raster.width >= 1 && raster.height >= 1)
    }

    // MARK: - W4a-known gaps: window-extent sign flip and MM_TEXT after the preamble
    //
    // These are documented W4a gaps (PROGRESS, 5 Nov): the file need not look
    // right, but it must stay bounded and non-crashing (§8).

    /// A standard WMF whose first window extent is negative stays bounded.
    @Test("a WMF with a negative window extent stays bounded and non-crashing")
    func negativeWindowExtent() throws {
        let data = Self.standardWMF([
            Self.record(0x020B, Self.i16(0) + Self.i16(0)),          // SETWINDOWORG
            Self.record(0x020C, Self.i16(-50) + Self.i16(-100)),     // SETWINDOWEXT (Y,X) negative
            Self.record(0x041B, Self.i16(40) + Self.i16(40) + Self.i16(0) + Self.i16(0)),  // RECTANGLE
        ])
        let (raster, _, prepared) = try render(data)
        #expect(prepared.naturalSize.width >= 1 && prepared.naturalSize.height >= 1)
        #expect(prepared.naturalSize.width <= 16_384 && prepared.naturalSize.height <= 16_384)
        #expect(raster.width >= 1 && raster.height >= 1)
    }

    /// A placeable WMF that switches to MM_TEXT after the anisotropic preamble
    /// (the W4a 1:1-off-canvas case) stays bounded and non-crashing.
    @Test("a WMF that sets MM_TEXT after the preamble stays bounded and non-crashing")
    func mmTextAfterPreamble() throws {
        let records = [Self.record(0x0103, Self.u16(1))] + Self.redFillRecords()   // SETMAPMODE MM_TEXT
        let (raster, _, prepared) = try render(Self.placeableWMF(records))
        #expect(prepared.kind == .wmfRecords)
        #expect(raster.width == 96 && raster.height == 96)   // canvas size is unaffected; content may be off-canvas
    }
}
