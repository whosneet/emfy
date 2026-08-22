import Foundation
import Testing
@testable import EMFParse

// MARK: - Local fixture builders

// Mirror the EMF+ framing helpers from EMFPlusStreamTests/EMFPlusInventoryTests
// (kept file-private there, so duplicated here). Every record is well-formed
// unless a test deliberately forges one field.

/// One EMF+ record ([MS-EMFPLUS] §2.3): Type, Flags (u16), Size, DataSize (u32),
/// then `data`.
private func plusRecord(type: UInt16, flags: UInt16 = 0, data: [UInt8] = []) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(UInt32(12 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

/// Wraps an EMF+ stream in one EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4).
private func plusComment(stream: [UInt8]) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(0x2B46_4D45)   // "EMF+"
    payload.appendBytes(stream)
    let data = payload.bytes
    var b = FixtureBuilder()
    b.appendUInt32(70)                          // EMR_COMMENT
    b.appendUInt32(UInt32(8 + 4 + data.count))  // nSize
    b.appendUInt32(UInt32(data.count))          // DataSize
    b.appendBytes(data)
    return b.bytes
}

/// EmfPlusObject Flags word ([MS-EMFPLUS] §2.3.5.1): C at bit 15, ObjectType at
/// bits 14…8, ObjectID at the low byte.
private func objectFlags(continues: Bool, objectType: UInt8, objectID: UInt8) -> UInt16 {
    var flags: UInt16 = continues ? 0x8000 : 0
    flags |= (UInt16(objectType) & 0x7F) << 8
    flags |= UInt16(objectID)
    return flags
}

/// One EmfPlusObject (0x4008) record. A continued chunk carries a 4-byte
/// TotalObjectSize prefix ahead of its object bytes (present in EVERY chunk on
/// the wire); a plain record carries none.
private func objectRecord(
    continues: Bool, objectType: UInt8, objectID: UInt8,
    totalObjectSize: UInt32? = nil, objectBytes: [UInt8]
) -> [UInt8] {
    var data = FixtureBuilder()
    if let total = totalObjectSize { data.appendUInt32(total) }
    data.appendBytes(objectBytes)
    return plusRecord(
        type: 0x4008,
        flags: objectFlags(continues: continues, objectType: objectType, objectID: objectID),
        data: data.bytes)
}

/// Builds a clean file (108-byte header + one comment carrying every record
/// blob + EOF), parses it, walks the EMF+ stream, and reassembles objects.
private func parseObjects(_ blobs: [[UInt8]]) throws
    -> (definitions: [EMFPlusObjectDefinition], diagnostics: [EMFPlusObjectDiagnostic]) {
    var stream: [UInt8] = []
    for blob in blobs { stream.append(contentsOf: blob) }
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    fixture.appendBytes(plusComment(stream: stream))
    fixture.appendBytes(FixtureBuilder.eof())
    return try EMFFile.parse(fixture.data).emfPlusStream().objectDefinitions()
}

private func argb(_ blue: UInt8, _ green: UInt8, _ red: UInt8, _ alpha: UInt8) -> EMFPlusARGB {
    EMFPlusARGB(blue: blue, green: green, red: red, alpha: alpha)
}

// Object-payload byte builders (the object definition itself, no record framing).

private func solidBrushBytes(version: UInt32 = 0xDBC0_1002, colorBGRA: [UInt8]) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(version)     // Version
    b.appendUInt32(0)           // Type = BrushTypeSolidColor
    b.appendBytes(colorBGRA)    // SolidColor, wire order B,G,R,A
    return b.bytes
}

// MARK: - Envelope & reassembly

@Suite("EMF+ object envelope & reassembly")
struct EMFPlusObjectEnvelopeTests {

    @Test("single-chunk plain object → id, type, byte-exact payload, no diagnostics")
    func singleChunkPlain() throws {
        let payload: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7]
        let (defs, diags) = try parseObjects([
            objectRecord(continues: false, objectType: 1, objectID: 5, objectBytes: payload)
        ])
        #expect(defs.count == 1)
        let def = try #require(defs.first)
        #expect(def.objectID == 5)
        #expect(def.objectType == .brush)
        #expect(Array(def.data) == payload)
        #expect(diags.isEmpty)
    }

    /// Two-chunk continued object with the libemf2svg test-109 arithmetic shape:
    /// TotalObjectSize in EVERY chunk, real bytes per chunk = DataSize-4, C set on
    /// both (including the last), completion by accounting. Real test-109 sums
    /// (65008-4)+(57108-4) = 122108; this fixture uses the same relationship with
    /// tractable sizes: (104-4)+(76-4) = 172.
    @Test("continued object, 2 chunks → one definition, byte-exact, accounting-terminated")
    func continuedTwoChunks() throws {
        let total: UInt32 = 172
        let chunk1 = (0 ..< 100).map { UInt8($0) }      // 100 object bytes → DataSize 104
        let chunk2 = (100 ..< 172).map { UInt8($0) }    // 72 object bytes  → DataSize 76
        let expected = (0 ..< 172).map { UInt8($0) }

        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 7, totalObjectSize: total, objectBytes: chunk1),
            objectRecord(continues: true, objectType: 1, objectID: 7, totalObjectSize: total, objectBytes: chunk2),
        ])
        #expect(defs.count == 1)
        let def = try #require(defs.first)
        #expect(def.objectID == 7)
        #expect(def.objectType == .brush)
        #expect(def.data.count == 172)
        #expect(Array(def.data) == expected)
        #expect(diags.isEmpty)
    }

    @Test("a continuation chunk that lies about TotalObjectSize decodes as usual but is flagged (L10)")
    func continuationSizeDisagreementFlagged() throws {
        let total: UInt32 = 172
        let chunk1 = (0 ..< 100).map { UInt8($0) }
        let chunk2 = (100 ..< 172).map { UInt8($0) }
        let expected = (0 ..< 172).map { UInt8($0) }

        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 7, totalObjectSize: total, objectBytes: chunk1),
            // Same id/type, but the repeated TotalObjectSize prefix lies (999 vs 172).
            objectRecord(continues: true, objectType: 1, objectID: 7, totalObjectSize: 999, objectBytes: chunk2),
        ])
        // Accounting is unchanged: the opening total (172) stays authoritative.
        #expect(defs.count == 1)
        let def = try #require(defs.first)
        #expect(def.objectID == 7)
        #expect(Array(def.data) == expected, "the object decodes byte-exactly as with an honest prefix")
        #expect(diags == [.continuationSizeDisagreement(objectID: 7, expected: 172, got: 999)],
                "the disagreement should be the only diagnostic: \(diags)")
    }

    @Test("continued object, 4 chunks → one definition, byte-exact, accounting-terminated")
    func continuedFourChunks() throws {
        let total: UInt32 = 144                          // 4 × (40-4)
        var blobs: [[UInt8]] = []
        for i in 0 ..< 4 {
            let bytes = (i * 36 ..< (i + 1) * 36).map { UInt8($0) }
            blobs.append(objectRecord(
                continues: true, objectType: 1, objectID: 12, totalObjectSize: total, objectBytes: bytes))
        }
        let (defs, diags) = try parseObjects(blobs)
        #expect(defs.count == 1)
        let def = try #require(defs.first)
        #expect(def.objectID == 12)
        #expect(Array(def.data) == (0 ..< 144).map { UInt8($0) })
        #expect(diags.isEmpty)
    }

    @Test("continuation with a mismatched ObjectID → diagnostic, pending dropped, chunk starts fresh")
    func mismatchedContinuation() throws {
        let (defs, diags) = try parseObjects([
            // Opens an incomplete sequence for id 7 (40 of 200 bytes).
            objectRecord(continues: true, objectType: 1, objectID: 7, totalObjectSize: 200,
                         objectBytes: (0 ..< 40).map { UInt8($0) }),
            // A continuation for a different id: drops the pending, starts fresh,
            // and completes in one chunk (60 of 60 bytes).
            objectRecord(continues: true, objectType: 1, objectID: 9, totalObjectSize: 60,
                         objectBytes: (0 ..< 60).map { UInt8($0) }),
        ])
        #expect(defs.map(\.objectID) == [9])
        #expect(diags == [
            .continuationMismatch(pendingID: 7, pendingType: .brush, arrivingID: 9, arrivingType: .brush)
        ])
    }

    @Test("pending continuation dangling at stream end → diagnostic, dropped")
    func danglingContinuation() throws {
        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 3, totalObjectSize: 200,
                         objectBytes: (0 ..< 100).map { UInt8($0) })
        ])
        #expect(defs.isEmpty)
        #expect(diags == [
            .danglingContinuation(objectID: 3, totalObjectSize: 200, accumulatedBytes: 100)
        ])
    }

    @Test("ObjectID > 63 → diagnostic, object still produced")
    func objectIDOutOfRange() throws {
        let (defs, diags) = try parseObjects([
            objectRecord(continues: false, objectType: 1, objectID: 100, objectBytes: [1, 2, 3, 4])
        ])
        #expect(defs.count == 1)
        #expect(defs.first?.objectID == 100)
        #expect(diags == [.objectIDOutOfRange(objectID: 100, objectType: .brush)])
    }

    @Test("continued chunk too short to hold TotalObjectSize → diagnostic, dropped")
    func chunkTooShortFresh() throws {
        // A continued (C set) record whose RecordData is empty: 0 bytes cannot
        // hold the 4-byte TotalObjectSize prefix. DataSize 0 stays walk-valid.
        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 2, objectBytes: [])
        ])
        #expect(defs.isEmpty)
        #expect(diags == [.chunkTooShort(dataSize: 0)])
    }

    @Test("too-short continuation mid-sequence → chunkTooShort + dangling, pending dropped")
    func chunkTooShortMidSequence() throws {
        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 5, totalObjectSize: 100,
                         objectBytes: (0 ..< 40).map { UInt8($0) }),
            objectRecord(continues: true, objectType: 1, objectID: 5, objectBytes: []),
        ])
        #expect(defs.isEmpty)
        #expect(diags == [
            .chunkTooShort(dataSize: 0),
            .danglingContinuation(objectID: 5, totalObjectSize: 100, accumulatedBytes: 40),
        ])
    }

    @Test("accumulated bytes exceed TotalObjectSize → clamped with diagnostic")
    func continuationOverflowClamped() throws {
        // One continued chunk carrying 16 object bytes but declaring TotalObjectSize 8.
        let (defs, diags) = try parseObjects([
            objectRecord(continues: true, objectType: 1, objectID: 1, totalObjectSize: 8,
                         objectBytes: (0 ..< 16).map { UInt8($0) })
        ])
        #expect(defs.count == 1)
        #expect(Array(defs.first?.data ?? Data()) == (0 ..< 8).map { UInt8($0) })
        #expect(diags == [.continuationOverflow(objectID: 1, totalObjectSize: 8, accumulatedBytes: 16)])
    }

    @Test("multiple plain objects → definitions in stream order")
    func multipleObjectsInOrder() throws {
        let (defs, diags) = try parseObjects([
            objectRecord(continues: false, objectType: 1, objectID: 10, objectBytes: [0, 0, 0, 0]),
            objectRecord(continues: false, objectType: 2, objectID: 20, objectBytes: [0, 0, 0, 0]),
            objectRecord(continues: false, objectType: 3, objectID: 30, objectBytes: [0, 0, 0, 0]),
        ])
        #expect(defs.map(\.objectID) == [10, 20, 30])
        #expect(defs.map(\.objectType) == [.brush, .pen, .path])
        #expect(diags.isEmpty)
    }
}

// MARK: - Brush decode

@Suite("EMF+ brush decode")
struct EMFPlusBrushDecodeTests {

    private func decode(type: UInt8, objectBytes: [UInt8]) throws -> EMFPlusObjectValue {
        let (defs, _) = try parseObjects([
            objectRecord(continues: false, objectType: type, objectID: 0, objectBytes: objectBytes)
        ])
        return try #require(defs.first).decodedValue()
    }

    @Test("solid brush → ARGB channels in wire order B,G,R,A")
    func solidBrush() throws {
        let value = try decode(type: 1, objectBytes: solidBrushBytes(colorBGRA: [0x11, 0x22, 0x33, 0xFF]))
        guard case .brush(let brush) = value else { Issue.record("expected .brush, got \(value)"); return }
        #expect(brush.version == 0xDBC0_1002)
        #expect(brush.brushType == .solid)
        #expect(brush.data == .solid(argb(0x11, 0x22, 0x33, 0xFF)))
    }

    @Test("hatch brush → style + fore/back colors")
    func hatchBrush() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(1)               // Type = BrushTypeHatchFill
        b.appendUInt32(0x05)            // HatchStyle = DiagonalCross
        b.appendBytes([0x01, 0x02, 0x03, 0x04])   // ForeColor B,G,R,A
        b.appendBytes([0x05, 0x06, 0x07, 0x08])   // BackColor B,G,R,A
        let value = try decode(type: 1, objectBytes: b.bytes)
        guard case .brush(let brush) = value else { Issue.record("expected .brush, got \(value)"); return }
        #expect(brush.brushType == .hatch)
        #expect(brush.data == .hatch(
            style: .diagonalCross, foreColor: argb(1, 2, 3, 4), backColor: argb(5, 6, 7, 8)))
    }

    @Test("linear gradient, no optional data → RectF + colors + flags, blend/transform nil")
    func linearGradientMinimal() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(4)               // Type = BrushTypeLinearGradient
        b.appendUInt32(0)               // BrushDataFlags = none
        b.appendInt32(1)                // WrapMode = TileFlipX
        b.appendFloat(1); b.appendFloat(2); b.appendFloat(3); b.appendFloat(4)   // RectF
        b.appendBytes([0x10, 0x20, 0x30, 0x40])   // StartColor
        b.appendBytes([0x50, 0x60, 0x70, 0x80])   // EndColor
        b.appendUInt32(0xAAAA_AAAA)     // Reserved1
        b.appendUInt32(0xBBBB_BBBB)     // Reserved2
        let value = try decode(type: 1, objectBytes: b.bytes)
        guard case .brush(let brush) = value, case .linearGradient(let lg) = brush.data else {
            Issue.record("expected linear gradient, got \(value)"); return
        }
        #expect(lg.brushDataFlags == 0)
        #expect(lg.wrapMode == 1)
        #expect(lg.rect == EMFPlusRectF(x: 1, y: 2, width: 3, height: 4))
        #expect(lg.startColor == argb(0x10, 0x20, 0x30, 0x40))
        #expect(lg.endColor == argb(0x50, 0x60, 0x70, 0x80))
        #expect(lg.reserved1 == 0xAAAA_AAAA)
        #expect(lg.reserved2 == 0xBBBB_BBBB)
        #expect(lg.transform == nil)
        #expect(lg.blend == nil)
    }

    @Test("linear gradient with preset-color blend array")
    func linearGradientPresetColors() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(4)               // Type = BrushTypeLinearGradient
        b.appendUInt32(0x0000_0004)     // BrushDataFlags = BrushDataPresetColors
        b.appendInt32(0)                // WrapMode
        b.appendFloat(0); b.appendFloat(0); b.appendFloat(10); b.appendFloat(0)   // RectF
        b.appendBytes([0, 0, 0, 0xFF])  // StartColor
        b.appendBytes([0xFF, 0xFF, 0xFF, 0xFF])   // EndColor
        b.appendUInt32(0)               // Reserved1
        b.appendUInt32(0)               // Reserved2
        // EmfPlusBlendColors: PositionCount 2, positions, colors.
        b.appendUInt32(2)
        b.appendFloat(0.0); b.appendFloat(1.0)
        b.appendBytes([0x0A, 0x0B, 0x0C, 0x0D])   // color[0]
        b.appendBytes([0x1A, 0x1B, 0x1C, 0x1D])   // color[1]
        let value = try decode(type: 1, objectBytes: b.bytes)
        guard case .brush(let brush) = value, case .linearGradient(let lg) = brush.data else {
            Issue.record("expected linear gradient, got \(value)"); return
        }
        #expect(lg.blend == .presetColors(EMFPlusBlendColors(
            positions: [0.0, 1.0],
            colors: [argb(0x0A, 0x0B, 0x0C, 0x0D), argb(0x1A, 0x1B, 0x1C, 0x1D)])))
    }

    @Test("texture brush → raw marker (bitmap decode deferred)")
    func textureBrush() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(2)               // Type = BrushTypeTextureFill
        b.appendBytes([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let value = try decode(type: 1, objectBytes: b.bytes)
        guard case .brush(let brush) = value else { Issue.record("expected .brush, got \(value)"); return }
        #expect(brush.brushType == .texture)
        #expect(brush.data == .texture(raw: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])))
    }

    @Test("truncated solid brush → typed malformed failure, no crash")
    func truncatedBrush() throws {
        // Version + Type only; the SolidColor is missing.
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)
        b.appendUInt32(0)               // Type = solid, but no color follows
        let value = try decode(type: 1, objectBytes: b.bytes)
        #expect(value == .malformed(type: .brush, reason: .truncated(field: "EmfPlusSolidBrushData.SolidColor")))
    }
}

// MARK: - Pen decode

@Suite("EMF+ pen decode")
struct EMFPlusPenDecodeTests {

    private func decode(objectBytes: [UInt8]) throws -> EMFPlusObjectValue {
        let (defs, _) = try parseObjects([
            objectRecord(continues: false, objectType: 2, objectID: 0, objectBytes: objectBytes)
        ])
        return try #require(defs.first).decodedValue()
    }

    /// PenData(flags, unit, width) with the optional blocks selected by `flags`
    /// appended verbatim, then a trailing solid BrushObject.
    private func penBytes(type: UInt32 = 0, flags: UInt32, unit: UInt32 = 0, width: Float,
                          optional: [UInt8], brushColorBGRA: [UInt8] = [0x11, 0x22, 0x33, 0xFF]) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)     // Version
        b.appendUInt32(type)            // Type (MUST be 0)
        b.appendUInt32(flags)           // PenDataFlags
        b.appendUInt32(unit)            // PenUnit
        b.appendFloat(width)            // PenWidth
        b.appendBytes(optional)         // gated optional blocks
        b.appendBytes(solidBrushBytes(colorBGRA: brushColorBGRA))   // BrushObject
        return b.bytes
    }

    @Test("minimal pen (flags 0) + width + embedded solid brush")
    func minimalPen() throws {
        let value = try decode(objectBytes: penBytes(flags: 0, width: 1.5, optional: []))
        guard case .pen(let pen) = value else { Issue.record("expected .pen, got \(value)"); return }
        #expect(pen.type == 0)
        #expect(pen.penData.flags == 0)
        #expect(pen.penData.unit == 0)
        #expect(pen.penData.width == 1.5)
        #expect(pen.penData.transform == nil)
        #expect(pen.penData.startCap == nil)
        #expect(pen.penData.dashedLine == nil)
        #expect(pen.penData.customStartCap == nil)
        #expect(pen.penData.customEndCap == nil)
        #expect(pen.brush.data == .solid(argb(0x11, 0x22, 0x33, 0xFF)))
    }

    @Test("pen with full scalar block set (flags 0x3E: caps/join/miter/style)")
    func penScalarBlocks() throws {
        var opt = FixtureBuilder()
        opt.appendInt32(1)      // StartCap
        opt.appendInt32(2)      // EndCap
        opt.appendInt32(3)      // Join
        opt.appendFloat(10)     // MiterLimit
        opt.appendInt32(4)      // LineStyle
        let value = try decode(objectBytes: penBytes(flags: 0x3E, width: 2.0, optional: opt.bytes))
        guard case .pen(let pen) = value else { Issue.record("expected .pen, got \(value)"); return }
        #expect(pen.penData.startCap == 1)
        #expect(pen.penData.endCap == 2)
        #expect(pen.penData.join == 3)
        #expect(pen.penData.miterLimit == 10)
        #expect(pen.penData.lineStyle == 4)
        #expect(pen.penData.transform == nil)
        #expect(pen.penData.dashedLineCap == nil)
        #expect(pen.penData.dashedLine == nil)
        #expect(pen.brush.data == .solid(argb(0x11, 0x22, 0x33, 0xFF)))
    }

    @Test("pen with a DashedLine array → count round-trips, brush still reached")
    func penDashedLine() throws {
        var opt = FixtureBuilder()
        opt.appendUInt32(3)     // DashedLineDataSize
        opt.appendFloat(1); opt.appendFloat(2); opt.appendFloat(3)
        let value = try decode(objectBytes: penBytes(flags: 0x100, width: 1.0, optional: opt.bytes))
        guard case .pen(let pen) = value else { Issue.record("expected .pen, got \(value)"); return }
        #expect(pen.penData.dashedLine == [1, 2, 3])
        #expect(pen.brush.data == .solid(argb(0x11, 0x22, 0x33, 0xFF)))
    }

    @Test("pen with a lying DashedLine count → typed malformed failure, no crash")
    func penDashedLineLyingCount() throws {
        var opt = FixtureBuilder()
        opt.appendUInt32(1000)  // count far larger than the bytes that follow
        opt.appendFloat(1); opt.appendFloat(2)   // only 8 bytes of data
        // No brush appended: the decode must fail before reaching it.
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)
        b.appendUInt32(0)
        b.appendUInt32(0x100)   // PenDataDashedLine
        b.appendUInt32(0)
        b.appendFloat(1.0)
        b.appendBytes(opt.bytes)
        let value = try decode(objectBytes: b.bytes)
        guard case .malformed(.pen, .arrayCountExceedsBuffer(let field, let count, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "PenData.DashedLineData")
        #expect(count == 1000)
    }

    @Test("pen with a custom start cap → sized past correctly to reach the brush")
    func penCustomCapSizedPast() throws {
        let capBytes: [UInt8] = [0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB]
        var opt = FixtureBuilder()
        opt.appendUInt32(UInt32(capBytes.count))   // CustomStartCapSize
        opt.appendBytes(capBytes)                  // opaque cap of arbitrary size
        let value = try decode(objectBytes: penBytes(flags: 0x800, width: 1.0, optional: opt.bytes,
                                                     brushColorBGRA: [0x09, 0x08, 0x07, 0x06]))
        guard case .pen(let pen) = value else { Issue.record("expected .pen, got \(value)"); return }
        #expect(pen.penData.customStartCap == Data(capBytes))
        // The cursor landed exactly on the trailing brush after skipping the cap.
        #expect(pen.brush.data == .solid(argb(0x09, 0x08, 0x07, 0x06)))
    }

    @Test("pen with a lying CustomStartCapSize → typed malformed failure, no crash")
    func penLyingCustomCapSize() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0xDBC0_1002)
        b.appendUInt32(0)
        b.appendUInt32(0x800)   // PenDataCustomStartCap
        b.appendUInt32(0)
        b.appendFloat(1.0)
        b.appendUInt32(9999)    // CustomStartCapSize far past the remaining bytes
        b.appendBytes([0x01, 0x02, 0x03, 0x04])
        let value = try decode(objectBytes: b.bytes)
        guard case .malformed(.pen, .customCapSizeExceedsBuffer(let field, let size, _)) = value else {
            Issue.record("expected malformed customCapSizeExceedsBuffer, got \(value)"); return
        }
        #expect(field == "PenData.CustomStartCapData")
        #expect(size == 9999)
    }

    @Test("pen Type != 0 → kept verbatim, decoding still continues to the brush")
    func penTypeNonZero() throws {
        let value = try decode(objectBytes: penBytes(type: 5, flags: 0, width: 1.0, optional: []))
        guard case .pen(let pen) = value else { Issue.record("expected .pen, got \(value)"); return }
        #expect(pen.type == 5)
        #expect(pen.brush.data == .solid(argb(0x11, 0x22, 0x33, 0xFF)))
    }
}
