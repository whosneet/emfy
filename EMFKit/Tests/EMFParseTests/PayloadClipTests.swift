import Foundation
import Testing
@testable import EMFParse

@Suite("Clipping record payload decode")
struct PayloadClipTests {

    // MARK: - EMR_SELECTCLIPPATH (67)

    @Test("selectClipPath: five RegionMode values plus an unknown raw")
    func selectClipPathModes() throws {
        func modeRecord(_ raw: UInt32) -> [UInt8] {
            var b = FixtureBuilder()
            b.appendUInt32(raw)
            return FixtureBuilder.record(type: 67, payload: b.bytes)
        }

        // RegionMode ([MS-EMF] §2.1.29): RGN_AND=1 … RGN_COPY=5.
        #expect(try decodeSingle(modeRecord(0x01)) == .selectClipPath(.and))
        #expect(try decodeSingle(modeRecord(0x02)) == .selectClipPath(.or))
        #expect(try decodeSingle(modeRecord(0x03)) == .selectClipPath(.xor))
        #expect(try decodeSingle(modeRecord(0x04)) == .selectClipPath(.diff))
        #expect(try decodeSingle(modeRecord(0x05)) == .selectClipPath(.copy))
        // Out-of-range value is carried, not rejected (log-and-skip).
        #expect(try decodeSingle(modeRecord(0x99)) == .selectClipPath(.unknown(0x99)))
    }

    @Test("selectClipPath with no mode field is malformed")
    func selectClipPathTooSmall() throws {
        #expect(try decodeSingle(FixtureBuilder.record(type: 67, payload: []))
            == .malformed(type: 67, reason: .tooSmall(minimumSize: 12, actualSize: 8)))
    }

    // MARK: - EMR_EXTSELECTCLIPRGN (75)

    /// Assembles an EMR_EXTSELECTCLIPRGN payload (everything after the 8-byte
    /// Type/Size record header): RgnDataSize, RegionMode, then a RegionData
    /// object ([MS-EMF] §2.2.24) — a RegionDataHeader (§2.2.25) followed by
    /// `rects`. Header fields default to the spec-required constants but are
    /// overridable to build malformed cases.
    private static func extClipPayload(
        rgnDataSizeOverride: UInt32? = nil,
        mode: UInt32,
        headerSize: UInt32 = 0x20,
        headerType: UInt32 = 0x01,
        countRectsOverride: UInt32? = nil,
        bounds: RectL,
        rects: [RectL]
    ) -> [UInt8] {
        var region = FixtureBuilder()
        region.appendUInt32(headerSize)                     // 0  Size
        region.appendUInt32(headerType)                     // 4  Type
        region.appendUInt32(countRectsOverride ?? UInt32(rects.count)) // 8 CountRects
        region.appendUInt32(UInt32(rects.count * 16))       // 12 RgnSize
        region.appendInt32(bounds.left)                     // 16 Bounds
        region.appendInt32(bounds.top)
        region.appendInt32(bounds.right)
        region.appendInt32(bounds.bottom)
        for r in rects {
            region.appendInt32(r.left)
            region.appendInt32(r.top)
            region.appendInt32(r.right)
            region.appendInt32(r.bottom)
        }

        var b = FixtureBuilder()
        b.appendUInt32(rgnDataSizeOverride ?? UInt32(region.count))  // RgnDataSize
        b.appendUInt32(mode)                                         // RegionMode
        b.appendBytes(region.bytes)                                  // RgnData
        return b.bytes
    }

    @Test("extSelectClipRgn golden: 2-rect region, header + both rects asserted")
    func extClipRgnGolden() throws {
        let bounds = RectL(left: 0, top: 0, right: 100, bottom: 100)
        let rects = [
            RectL(left: 0, top: 0, right: 40, bottom: 100),
            RectL(left: 60, top: 0, right: 100, bottom: 100),
        ]
        let payload = Self.extClipPayload(mode: 0x01, bounds: bounds, rects: rects)
        // RgnDataSize(4) + RegionMode(4) + header(32) + 2 rects(32) = 72.
        #expect(payload.count == 72)
        // Whole record: 8-byte Type/Size header + 72 = 80.
        let record = FixtureBuilder.record(type: 75, payload: payload)
        #expect(record.count == 80)

        #expect(try decodeSingle(record)
            == .extSelectClipRgn(ExtSelectClipRgnPayload(
                mode: .and,
                bounds: bounds,
                rects: rects
            )))
    }

    @Test("extSelectClipRgn RGN_COPY with RgnDataSize 0 is the valid reset form")
    func extClipRgnCopyReset() throws {
        // RGN_COPY (5) + no region data → reset to the default clipping region
        // ([MS-EMF] §2.3.2.2). A 16-byte record (Type/Size + two u32s), VALID.
        var b = FixtureBuilder()
        b.appendUInt32(0)        // RgnDataSize = 0 (omitted region data)
        b.appendUInt32(0x05)     // RegionMode = RGN_COPY
        let record = FixtureBuilder.record(type: 75, payload: b.bytes)
        #expect(record.count == 16)

        #expect(try decodeSingle(record)
            == .extSelectClipRgn(ExtSelectClipRgnPayload(mode: .copy, bounds: nil, rects: [])))
    }

    @Test("extSelectClipRgn lying CountRects: countTooLarge, no allocation")
    func extClipRgnLyingCount() throws {
        // RgnDataSize (64) and nSize both hold room for exactly 2 rects, but
        // CountRects claims 1000. Rejected before any RectL is allocated.
        let bounds = RectL(left: 0, top: 0, right: 100, bottom: 100)
        let rects = [
            RectL(left: 0, top: 0, right: 40, bottom: 100),
            RectL(left: 60, top: 0, right: 100, bottom: 100),
        ]
        let payload = Self.extClipPayload(
            mode: 0x01,
            countRectsOverride: 1000,
            bounds: bounds,
            rects: rects
        )
        let record = FixtureBuilder.record(type: 75, payload: payload)

        let (file, raw) = try parseWithSingleRecord(record)
        #expect(file.diagnostics.isEmpty)   // walk unaffected by the bad payload
        #expect(file.records.count == 3)
        #expect(file.payload(of: raw)
            == .malformed(type: 75, reason: .countTooLarge(declared: 1000, maxFitting: 2)))
    }

    @Test("extSelectClipRgn RgnDataSize larger than remaining record bytes is malformed")
    func extClipRgnRgnDataSizeTooLarge() throws {
        // RgnDataSize claims 1000 bytes of region data, but only 8 bytes
        // remain after the two fixed u32s. Rejected before reading the header.
        var b = FixtureBuilder()
        b.appendUInt32(1000)     // RgnDataSize: LIES
        b.appendUInt32(0x01)     // RegionMode = RGN_AND
        b.appendUInt32(0)        // 8 stray bytes of "region data"
        b.appendUInt32(0)
        let record = FixtureBuilder.record(type: 75, payload: b.bytes)
        // Whole record = 8 + 16 = 24 bytes → available after offset 16 is 8.
        #expect(record.count == 24)

        #expect(try decodeSingle(record)
            == .malformed(type: 75, reason: .countTooLarge(declared: 1000, maxFitting: 8)))
    }

    @Test("extSelectClipRgn RegionDataHeader with wrong Type is malformed")
    func extClipRgnBadHeaderType() throws {
        // Header Type must be RDH_RECTANGLES = 0x01 ([MS-EMF] §2.2.25); 0x02
        // is not a valid region type.
        let bounds = RectL(left: 0, top: 0, right: 100, bottom: 100)
        let rects = [RectL(left: 0, top: 0, right: 100, bottom: 100)]
        let payload = Self.extClipPayload(
            mode: 0x01,
            headerType: 0x02,   // wrong constant
            bounds: bounds,
            rects: rects
        )
        let record = FixtureBuilder.record(type: 75, payload: payload)

        #expect(try decodeSingle(record)
            == .malformed(type: 75, reason: .badRegionHeader(size: 0x20, type: 0x02)))
    }

    @Test("extSelectClipRgn RegionDataHeader with wrong Size is malformed")
    func extClipRgnBadHeaderSize() throws {
        // Header Size must be 0x20 ([MS-EMF] §2.2.25).
        let bounds = RectL(left: 0, top: 0, right: 100, bottom: 100)
        let rects = [RectL(left: 0, top: 0, right: 100, bottom: 100)]
        let payload = Self.extClipPayload(
            mode: 0x01,
            headerSize: 0x28,   // wrong constant
            bounds: bounds,
            rects: rects
        )
        let record = FixtureBuilder.record(type: 75, payload: payload)

        #expect(try decodeSingle(record)
            == .malformed(type: 75, reason: .badRegionHeader(size: 0x28, type: 0x01)))
    }
}
