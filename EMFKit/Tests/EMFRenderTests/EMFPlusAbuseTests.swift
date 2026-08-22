import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - EMF+ abuse fixtures (primer §6 phase 6, §8)
//
// Deterministic, hand-authored HOSTILE EMF+ files, each driven end to end
// through `EMFRenderer.makeImage` — the exact entry Quick Look and the
// thumbnail extension call on untrusted input. Every case proves the same
// contract: a malformed or adversarial EMF+ stream must not crash, hang, or
// over-allocate; playback completes and returns a best-effort image. The
// fixtures are built in code (never committed to corpus/, which is
// Neet-approved content only) and, apart from the deliberate table-churn case,
// are each well under a few KB of wire bytes.
//
// Each EMF+ record is Type(u16)/Flags(u16)/Size(u32)/DataSize(u32) then data
// ([MS-EMFPLUS] §2.3); the stream is wrapped in EMR_COMMENT_EMFPLUS records
// ([MS-EMF] §2.3.3.4) inside a `RenderFixture` file with a valid 108-byte header.

private let plusVersion: UInt32 = 0xDBC0_1002

/// Little-endian byte bag (reuses RenderFixture's writer).
private func le(_ build: (inout RenderFixture.LE) -> Void) -> [UInt8] {
    var writer = RenderFixture.LE()
    build(&writer)
    return writer.bytes
}

/// One EMF+ record with an honest Size (12 + data) ([MS-EMFPLUS] §2.3).
private func plusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8] = []) -> [UInt8] {
    le { writer in
        writer.u16(type)
        writer.u16(flags)
        writer.u32(UInt32(12 + data.count))
        writer.u32(UInt32(data.count))
        writer.raw(data)
    }
}

/// One EMF+ record with a caller-chosen Size/DataSize — for the header-field
/// abuse where the declared Size lies about the record's true extent.
private func plusRecordRawSize(
    _ type: UInt16, _ flags: UInt16, size: UInt32, dataSize: UInt32, _ data: [UInt8] = []
) -> [UInt8] {
    le { writer in
        writer.u16(type)
        writer.u16(flags)
        writer.u32(size)
        writer.u32(dataSize)
        writer.raw(data)
    }
}

/// EmfPlusHeader (§2.3.3.3); Dual by default so a dual file plays its EMF+ half.
private func plusHeader(dual: Bool = false) -> [UInt8] {
    plusRecord(0x4001, dual ? 0x0001 : 0x0000, le { $0.u32(plusVersion); $0.u32(0); $0.u32(96); $0.u32(96) })
}

private func plusEndOfFile() -> [UInt8] { plusRecord(0x4002, 0) }   // §2.3.3.1
private func getDC() -> [UInt8] { plusRecord(0x4004, 0) }           // §2.3.3.2

/// An EmfPlusObject record (§2.3.5.1): Flags = C? | ObjectType<<8 | ObjectID.
private func plusObject(id: UInt8, type: UInt8, cont: Bool = false, payload: [UInt8]) -> [UInt8] {
    let flags = (cont ? UInt16(0x8000) : 0) | (UInt16(type) << 8) | UInt16(id)
    return plusRecord(0x4008, flags, payload)
}

/// EmfPlusBrush solid (§2.2.1.1/§2.2.2.43): Version, Type 0, SolidColor(ARGB).
private func solidBrushPayload(_ argb: UInt32) -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(0); $0.u32(argb) }
}

/// EmfPlusFillRects (§2.3.4.20) with the S flag (direct ARGB) and one RectF —
/// a well-formed drawing record used to engage EMF+ mode ([MS-EMFPLUS] §1.3.1:
/// a surviving drawing record is what routes a file through EMF+ playback).
private func fillRectsDirect(_ color: UInt32, _ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x400A, 0x8000, le { writer in
        writer.u32(color); writer.u32(1)
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

/// EmfPlusSetClipRegion (§2.3.1.5): Flags low byte = region ObjectID; bits 8-11
/// carry the CombineMode (0 = Replace). No data — the region lives in the table.
private func setClipRegion(regionId: UInt8, mode: UInt16 = 0) -> [UInt8] {
    plusRecord(0x4034, (mode << 8) | UInt16(regionId))
}

/// An ARGB DWORD (0xAARRGGBB).
private func argb(_ a: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
}

// MARK: - Region tree builders ([MS-EMFPLUS] §2.2.2.40)

/// A RegionNodeDataTypeRect leaf: Type(0x10000000) then an EmfPlusRectF (§2.2.2.40).
private func regionRectLeaf() -> [UInt8] {
    le { writer in
        writer.u32(0x1000_0000)
        writer.f32(0); writer.f32(0); writer.f32(10); writer.f32(10)
    }
}

/// A left-nested chain of `depth` RegionNodeDataTypeAnd combine nodes
/// terminating in rect leaves (§2.2.2.41). Pre-order: type, left subtree (the
/// deeper chain), right leaf — so the DECODE recurses `depth` levels down the
/// left spine before it reaches the terminal leaf. The parser caps region
/// recursion at 64 (EMFPlusRegion.swift `regionMaxDepth`): the leaf of a
/// `depth`-chain is decoded at recursion depth `depth`, so `depth <= 63` binds
/// and `depth >= 64` fails typed with `.regionTreeTooDeep`.
private func regionCombineChain(_ depth: Int) -> [UInt8] {
    guard depth > 0 else { return regionRectLeaf() }
    return le { $0.u32(0x0000_0001) } + regionCombineChain(depth - 1) + regionRectLeaf()
}

/// An EmfPlusRegion object payload (§2.2.1.8): Version, RegionNodeCount
/// (advisory), then the combine-chain root subtree.
private func regionPayload(depth: Int) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion)
        writer.u32(UInt32(2 * depth + 1))   // advisory node count
    } + regionCombineChain(depth)
}

// MARK: - File assembly

private extension RenderFixture {
    /// Appends an EMR_COMMENT_EMFPLUS carrying `stream` ([MS-EMF] §2.3.3.4).
    mutating func plusComment(_ stream: [UInt8]) {
        var payload = RenderFixture.LE()
        payload.u32(UInt32(4 + stream.count))   // DataSize (identifier + stream)
        payload.u32(0x2B46_4D45)                // "EMF+"
        payload.raw(stream)
        append(type: 70, payload: payload.bytes)
    }
}

// Count-bomb drawing records (audit M16 / F3): a hostile u32-max count with a
// body too short to hold the points/glyphs — the reader validates the count
// against the record's own bytes and skips (recordUndecodable), never allocating.
private func drawLinesCountBomb() -> [UInt8] { plusRecord(0x400D, 0, le { $0.u32(0xFFFF_FFFF) }) }
private func fillPolygonCountBomb() -> [UInt8] { plusRecord(0x400C, 0x8000, le { $0.u32(argb(255, 0, 0, 0)); $0.u32(0xFFFF_FFFF) }) }
private func drawCurveCountBomb() -> [UInt8] { plusRecord(0x4018, 0, le { $0.f32(0.5); $0.u32(0); $0.u32(0); $0.u32(0xFFFF_FFFF) }) }
private func drawDriverStringCountBomb() -> [UInt8] { plusRecord(0x4036, 0x8000, le { $0.u32(argb(255, 0, 0, 0)); $0.u32(0); $0.u32(0); $0.u32(0xFFFF_FFFF) }) }

@Suite("EMF+ abuse (survival through makeImage)")
struct EMFPlusAbuseTests {

    /// Runs a hostile file through the real thumbnail/Quick Look entry point and
    /// asserts the §8 contract: `makeImage` returns (never traps/hangs) and hands
    /// back a non-degenerate best-effort image. Reaching the assertion at all is
    /// the survival proof — a trap or hang would take the process down first.
    private func expectSurvives(_ file: EMFFile, _ label: String) {
        guard let (image, _) = EMFRenderer.makeImage(file) else {
            Issue.record("\(label): makeImage returned nil (bitmap context allocation failed)")
            return
        }
        #expect(image.width > 0 && image.height > 0, "\(label): produced a degenerate image")
    }

    /// Survives AND hands back the raster + log so a test can assert a POSITIVE
    /// signal beyond survival (audit M16): the leading well-formed drawing's ink
    /// and/or the honesty-channel entry the abuse produced.
    private func rasterAndLog(_ file: EMFFile, _ label: String) -> (RasterizedImage, EMFRenderLog)? {
        guard let (image, log) = EMFRenderer.makeImage(file) else {
            Issue.record("\(label): makeImage returned nil"); return nil
        }
        guard let raster = RasterizedImage(image) else {
            Issue.record("\(label): could not rasterize"); return nil
        }
        return (raster, log)
    }

    private static func isColorRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 150 && p.g < 70 && p.b < 70 }
    private static func isColorGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 110 && p.r < 90 && p.b < 90 }
    private static func isColorBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 160 && p.r < 90 && p.g < 90 }
    private func hasUndecodable(_ log: EMFRenderLog, type: UInt16) -> Bool {
        log.entries.contains { if case .emfPlusRecordUndecodable(let t, _) = $0 { return t == type }; return false }
    }
    private func hasObjectIssue(_ log: EMFRenderLog, _ kind: EMFPlusObjectIssueKind) -> Bool {
        log.entries.contains { if case .emfPlusObjectIssue(let k, _) = $0 { return k == kind }; return false }
    }

    // MARK: - (a) Continued-object bomb: TotalObjectSize = u32-max, tiny chunks

    @Test("a continued object declaring a 4 GiB TotalObjectSize never binds or over-allocates")
    func continuedObjectSizeBomb() throws {
        // Four C-flagged EmfPlusObject chunks for the same id/type. The first
        // DWORD of each continued chunk's data is TotalObjectSize (0xFFFFFFFF);
        // the object table (EMFPlusPlayback ObjectTable) accumulates by
        // DataSize-4 per chunk and only binds once the accumulation reaches
        // TotalObjectSize. It never can here, so the object stays pending —
        // proving there is no pre-allocation off the declared total.
        let chunk = le { $0.u32(0xFFFF_FFFF); $0.u32(0xDEAD_BEEF) }   // total + 4 payload bytes
        var stream = plusHeader()
        for _ in 0 ..< 4 { stream += plusObject(id: 5, type: 1, cont: true, payload: chunk) }
        stream += fillRectsDirect(argb(255, 200, 0, 0), (10, 10, 20, 20))   // engages EMF+ mode
        stream += plusEndOfFile()

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        guard let (raster, _) = rasterAndLog(try fixture.parsed(), "continued-object bomb") else { return }
        // Positive signal (M16): the trailing well-formed FillRects still drew; the
        // 4 GiB continuation never binds or over-allocates — it simply dangles.
        #expect(Self.isColorRed(raster[20, 20]), "the well-formed red fill should render, got \(raster[20, 20])")
    }

    // MARK: - (b) 64-deep and 65-deep region trees on a SetClipRegion path

    @Test("region trees at and beyond the recursion cap clip without crashing")
    func deepRegionClipTrees() throws {
        // depth 63: the terminal leaf decodes at recursion depth 63 (< 64) → the
        // region binds and SetClipRegion walks the 64-level tree to build a clip
        // path (the render-side region walk is bounded by the same cap). depth 64:
        // the leaf is reached at depth 64 → typed `.regionTreeTooDeep`, the object
        // is `.malformed`, SetClipRegion finds no region and no-ops. Both must
        // complete makeImage — neither recursion (decode or clip-path build) may
        // overflow the stack.
        for depth in [63, 64] {
            var stream = plusHeader()
            stream += plusObject(id: 1, type: 4, payload: regionPayload(depth: depth))
            stream += setClipRegion(regionId: 1)
            stream += fillRectsDirect(argb(255, 0, 0, 200), (0, 0, 90, 90))
            stream += plusEndOfFile()

            var fixture = RenderFixture()
            fixture.plusComment(stream)
            guard let (raster, log) = rasterAndLog(try fixture.parsed(), "region depth \(depth) clip") else { continue }
            #expect(Self.isColorBlue(raster[5, 5]), "the blue fill should render at depth \(depth), got \(raster[5, 5])")
            if depth == 64 {
                // The over-deep region decodes malformed; SetClipRegion then finds
                // no usable region — both now surface (audit M7/D4).
                #expect(hasObjectIssue(log, .undecodable), "a too-deep region should bind malformed: \(log.entries)")
                #expect(hasObjectIssue(log, .missingReference), "SetClipRegion on it should note missingReference: \(log.entries)")
            }
        }
    }

    // MARK: - (c) DrawString Length = u32-max

    @Test("DrawString with a 4 Gi-character Length is rejected, not allocated")
    func drawStringLengthBomb() throws {
        // BrushId, FormatID, Length(=0xFFFFFFFF), LayoutRect(16 B), no string.
        // EMFPlusText.decodeString validates Length against remaining/2 BEFORE
        // reserving the array, so the lying length fails to nil and the record
        // skips ([MS-EMFPLUS] §2.3.4.14, primer §8). The S flag makes it a
        // self-standing drawing record so EMF+ mode still engages.
        let data = le { writer in
            writer.u32(argb(255, 0, 0, 0))   // BrushId (S set → direct colour)
            writer.u32(0xFFFF_FFFF)          // FormatID (none)
            writer.u32(0xFFFF_FFFF)          // Length — the bomb
            writer.f32(10); writer.f32(10); writer.f32(80); writer.f32(20)   // LayoutRect
        }
        var stream = plusHeader()
        stream += plusRecord(0x401C, 0x8000 | 0x0001, data)   // S | fontId 1
        stream += plusEndOfFile()

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        guard let (_, log) = rasterAndLog(try fixture.parsed(), "DrawString length bomb") else { return }
        // Positive signal (M16): the lying Length is caught and the record noted.
        #expect(hasUndecodable(log, type: 0x401C), "a 4 Gi-char DrawString should note recordUndecodable(0x401C): \(log.entries)")
    }

    // MARK: - (d) FillRects Count = u32-max with the S flag (no rect bytes)

    @Test("FillRects with a 4 Gi Count and no rect data reads none and allocates none")
    func fillRectsCountBomb() throws {
        // S flag set (direct colour), Count = 0xFFFFFFFF, zero RectF bytes. The
        // FillRects loop reads incrementally and BREAKS the instant a rect read
        // fails, so the count is never used to size an allocation ([MS-EMFPLUS]
        // §2.3.4.20, primer §8: internal counts validated against the record's
        // own bytes).
        let data = le { writer in
            writer.u32(argb(255, 255, 0, 0))   // BrushId = direct red
            writer.u32(0xFFFF_FFFF)            // Count — the bomb
        }
        var stream = plusHeader()
        stream += fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20))   // well-formed leading draw
        stream += plusRecord(0x400A, 0x8000, data)                          // the count bomb
        stream += plusEndOfFile()

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        guard let (raster, _) = rasterAndLog(try fixture.parsed(), "FillRects count bomb") else { return }
        // Positive signal (M16): the leading fill drew; the bomb's Count is never
        // used to size an allocation (the rect loop breaks on the first short read).
        #expect(Self.isColorRed(raster[15, 15]), "the leading well-formed fill should render, got \(raster[15, 15])")
    }

    // MARK: - (e) Object record redefining id 63 ten thousand times (table churn)

    @Test("ten thousand redefinitions of object id 63 churn one slot without growth")
    func objectTableChurn() throws {
        // Every EmfPlusObject rebinds the single top slot (id 63, the last of the
        // 64-slot table): the table never grows, the churn only replaces one
        // decoded value. Larger than a few KB on the wire by construction (10k
        // records), but built by a loop and never committed to disk.
        var stream = plusHeader()
        for index in 0 ..< 10_000 {
            let color = argb(255, UInt8(index & 0xFF), 0, 0)
            stream += plusObject(id: 63, type: 1, payload: solidBrushPayload(color))
        }
        stream += fillRectsDirect(argb(255, 0, 128, 0), (10, 10, 40, 40))   // engages EMF+ mode
        stream += plusEndOfFile()

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        guard let (raster, _) = rasterAndLog(try fixture.parsed(), "object table churn") else { return }
        // Positive signal (M16): the trailing well-formed green fill still drew
        // after 10k redefinitions churned one slot.
        #expect(Self.isColorGreen(raster[25, 25]), "the green fill should render after the churn, got \(raster[25, 25])")
    }

    // MARK: - (f) GetDC window holding a GDI record whose count lies about its size

    @Test("a malformed GDI record inside a GetDC window is caught by the GDI guards")
    func gdiWindowLyingRecord() throws {
        // EMF+ mode engaged by the leading FillRects; a GetDC opens the GDI window
        // ([MS-EMFPLUS] §1.3.1) in which the next EMR record plays through the
        // shared `playGDIRecord`. That record is an EMR_POLYGON16 whose declared
        // point Count (0xFFFFFFFF) far exceeds what its nSize (28) can hold — a
        // record lying about its true size. The existing GDI point-count guard
        // (validated against the record's own extent, primer §8) must hold on the
        // window path exactly as on the pure-GDI path: log-and-skip, no over-read.
        let poly16Body = le { writer in
            writer.i32(0); writer.i32(0); writer.i32(50); writer.i32(50)   // Bounds (16 B)
            writer.u32(0xFFFF_FFFF)                                        // Count — the lie
            // no PointS data: a 28-byte record claiming ~4 billion points
        }

        var fixture = RenderFixture()
        fixture.plusComment(plusHeader(dual: true) + fillRectsDirect(argb(255, 0, 160, 0), (10, 10, 30, 30)))
        fixture.plusComment(getDC())                        // open the GDI window
        fixture.append(type: 86, payload: poly16Body)       // EMR_POLYGON16 in-window
        fixture.plusComment(plusEndOfFile())                // close the window
        guard let (raster, _) = rasterAndLog(try fixture.parsed(), "GDI-in-window lying record") else { return }
        // Positive signal (M16): the EMF+ green fill rendered; the lying GDI
        // record was caught by the point-count guard, not rendered.
        #expect(Self.isColorGreen(raster[20, 20]), "the EMF+ green fill should render, got \(raster[20, 20])")
    }

    // MARK: - (g) EMF+ record claiming Size = 0x7FFFFFFC

    @Test("an EMF+ record claiming a 2 GiB Size stops the walk without reading it")
    func emfPlusRecordGiantSize() throws {
        // The stream walker (EMFPlusStream.walkAssembledStream) advances by
        // min(Size, remaining), so a record declaring Size 0x7FFFFFFC (near
        // INT32_MAX, 4-aligned) with a truthful DataSize 0 is emitted and the walk
        // then jumps to the buffer end — it never tries to read two gigabytes
        // (primer §8). The leading FillRects gives real output first.
        var stream = plusHeader()
        stream += fillRectsDirect(argb(255, 200, 0, 0), (10, 10, 30, 30))
        stream += plusRecordRawSize(0x400A, 0x8000, size: 0x7FFF_FFFC, dataSize: 0)

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        expectSurvives(try fixture.parsed(), "EMF+ giant-Size record")
    }

    // MARK: - (h) Stream truncation reaches the render log on BOTH branches (audit M7 / C1)

    /// A trailing record header claiming `declaredDataSize` data bytes with NONE
    /// present → the walk stops with `.recordDataTruncated` (Size == DataSize+12,
    /// so it is not flagged as size-exceeds first). Placed last in the stream.
    private func truncatedTailRecord(type: UInt16, declaredDataSize: UInt32) -> [UInt8] {
        plusRecordRawSize(type, 0x8000, size: 12 + declaredDataSize, dataSize: declaredDataSize)
    }

    @Test("a truncated EMF+ record surfaces .recordDataTruncated on the drawing (EMF+) branch")
    func streamTruncationDrawingBranch() throws {
        var stream = plusHeader()
        stream += fillRectsDirect(argb(255, 200, 0, 0), (10, 10, 20, 20))   // real drawing → EMF+ branch
        stream += truncatedTailRecord(type: 0x400A, declaredDataSize: 40)   // claims 40 bytes, none follow
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        let (image, log) = try #require(EMFRenderer.makeImage(try fixture.parsed()))
        #expect(image.width > 0 && image.height > 0)
        #expect(log.entries.contains(.emfPlusStreamIssue(kind: .recordDataTruncated, count: 1)),
                "expected a recordDataTruncated stream issue, got \(log.entries)")
    }

    @Test("a truncated EMF+ record surfaces .recordDataTruncated even on the GDI (no-drawing) branch")
    func streamTruncationGDIBranch() throws {
        // Dual header, NO surviving EMF+ drawing record → the file plays its GDI
        // fallback, but the broken EMF+ half must still be reported (audit M7).
        var stream = plusHeader(dual: true)
        stream += truncatedTailRecord(type: 0x400A, declaredDataSize: 40)   // stops the walk before it emits
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        let (_, log) = try #require(EMFRenderer.makeImage(try fixture.parsed()))
        #expect(log.entries.contains(.emfPlusStreamIssue(kind: .recordDataTruncated, count: 1)),
                "the GDI branch must still report the broken EMF+ stream, got \(log.entries)")
    }

    // MARK: - (i) Record-count cap (audit M2 / D2)

    @Test("an over-cap EMF+ stream stops at the record-count limit and surfaces the cap")
    func recordCountCapReached() throws {
        // A stream of minimal 12-byte records past the shared cap; build the bytes
        // by repeating one chunk (fast). Non-drawing (0x4003) → GDI branch.
        let chunk = plusRecord(0x4003, 0)   // EmfPlusComment: Size 12, DataSize 0
        let n = EMFFile.recordCountLimit + 50
        var stream: [UInt8] = []
        stream.reserveCapacity(chunk.count * n)
        for _ in 0 ..< n { stream.append(contentsOf: chunk) }

        var fixture = RenderFixture()
        fixture.plusComment(stream)
        let file = try fixture.parsed()

        // Render-level first (transient walk): the cap surfaces via the C1 path.
        let (image, log) = try #require(EMFRenderer.makeImage(file))
        #expect(image.width > 0 && image.height > 0)
        #expect(log.entries.contains(.emfPlusStreamIssue(kind: .recordCountCapped, count: 1)),
                "makeImage should surface recordCountCapped: \(log.entries)")

        // Parse-level: exactly `recordCountLimit` records kept, and marked.
        let s = file.emfPlusStream()
        #expect(s.records.count == EMFFile.recordCountLimit, "walk should cap at the limit, got \(s.records.count)")
        #expect(s.diagnostics.contains { if case .recordCountCapped = $0 { return true }; return false },
                "the walk should emit recordCountCapped")
    }

    // MARK: - (j) Over-long record Size diagnostic (audit M3 / D3)

    @Test("a mid-stream over-long Size swallows the following record but is flagged")
    func recordSizeExcessPaddingSwallowsNext() throws {
        var stream = plusHeader()
        stream += plusRecordRawSize(0x4003, 0, size: 52, dataSize: 0)   // 40 excess bytes (> 3)
        stream += plusEndOfFile()                                        // would-be next record
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        let s = try fixture.parsed().emfPlusStream()

        #expect(s.diagnostics.contains { if case .recordSizeExcessPadding = $0 { return true }; return false },
                "an over-long Size should be flagged: \(s.diagnostics)")
        // ADVANCE RULE UNCHANGED (audit M3): the walk still advances by the
        // declared Size, so the EndOfFile after the inflated record is swallowed
        // — it is NOT walked. This diagnostic only flags the suspicious header.
        #expect(s.records.map(\.type) == [0x4001, 0x4003],
                "the record after an over-long Size is swallowed, got \(s.records.map(\.type))")
    }

    @Test("an over-long EMF+ record Size surfaces .recordSizeExcessPadding through makeImage")
    func recordSizeExcessPaddingSurfaces() throws {
        var stream = plusHeader()
        stream += fillRectsDirect(argb(255, 200, 0, 0), (10, 10, 20, 20))   // real draw first
        stream += plusRecordRawSize(0x4003, 0, size: 52, dataSize: 0)        // over-long, last record
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        let (image, log) = try #require(EMFRenderer.makeImage(try fixture.parsed()))
        #expect(image.width > 0 && image.height > 0)
        #expect(log.entries.contains(.emfPlusStreamIssue(kind: .recordSizeExcessPadding, count: 1)),
                "an over-long record Size should surface recordSizeExcessPadding: \(log.entries)")
    }

    // MARK: - (k) Count bombs on the remaining reader paths (audit M16 / F3)

    /// A leading well-formed red fill (probed) + a count-bomb record (asserted as
    /// recordUndecodable). Survival, positive ink, AND the honesty entry.
    private func expectCountBomb(_ bomb: [UInt8], type: UInt16, _ label: String) throws {
        var stream = plusHeader()
        stream += fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20))   // well-formed leading draw
        stream += bomb
        stream += plusEndOfFile()
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        guard let (raster, log) = rasterAndLog(try fixture.parsed(), label) else { return }
        #expect(Self.isColorRed(raster[15, 15]), "\(label): the leading fill should render, got \(raster[15, 15])")
        #expect(hasUndecodable(log, type: type), "\(label): expected recordUndecodable(\(type)): \(log.entries)")
    }

    @Test("a DrawLines count bomb is rejected, not allocated")
    func drawLinesCountBombSurvives() throws { try expectCountBomb(drawLinesCountBomb(), type: 0x400D, "DrawLines count bomb") }

    @Test("a FillPolygon count bomb is rejected, not allocated")
    func fillPolygonCountBombSurvives() throws { try expectCountBomb(fillPolygonCountBomb(), type: 0x400C, "FillPolygon count bomb") }

    @Test("a DrawCurve count bomb is rejected, not allocated")
    func drawCurveCountBombSurvives() throws { try expectCountBomb(drawCurveCountBomb(), type: 0x4018, "DrawCurve count bomb") }

    @Test("a DrawDriverString glyph-count bomb is rejected, not allocated")
    func drawDriverStringCountBombSurvives() throws { try expectCountBomb(drawDriverStringCountBomb(), type: 0x4036, "DrawDriverString glyph-count bomb") }
}
