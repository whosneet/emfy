import Foundation
import Testing
@testable import EMFParse

/// EMR_CREATEDIBPATTERNBRUSHPT (94, [MS-EMF] §2.3.7.4), EMR_CREATEMONOBRUSH
/// (93, §2.3.7.5) and EMR_SETBRUSHORGEX (13, §2.3.11.12) byte-fixture decode:
/// golden, truncated, and lying-offset/size variants. Both brush records share
/// the exact fixed layout — ihBrush@8, iUsage@12, offBmi@16, cbBmi@20,
/// offBits@24, cbBits@28, then the packed DIB — so one helper builds both.
@Suite("DIB pattern-brush and SETBRUSHORGEX payload decode")
struct PayloadDIBPatternBrushTests {

    // MARK: - Fixtures

    /// A 40-byte BITMAPINFOHEADER ([MS-WMF] §2.2.2.3).
    private static func bitmapInfoHeader(
        width: Int32, height: Int32, bitCount: UInt16,
        compression: UInt32 = 0, colorUsed: UInt32 = 0
    ) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendUInt32(40)            // HeaderSize
        b.appendInt32(width)          // Width
        b.appendInt32(height)         // Height (signed)
        b.appendUInt16(1)             // Planes
        b.appendUInt16(bitCount)      // BitCount
        b.appendUInt32(compression)   // Compression
        b.appendUInt32(0)             // ImageSize
        b.appendInt32(2835)           // XPelsPerMeter
        b.appendInt32(2835)           // YPelsPerMeter
        b.appendUInt32(colorUsed)     // ColorUsed
        b.appendUInt32(0)             // ColorImportant
        return b.bytes
    }

    /// Builds an EMR_CREATEDIBPATTERNBRUSHPT / EMR_CREATEMONOBRUSH record
    /// (shared layout). The 32-byte fixed part (record offsets 8..32) is
    /// followed by `bmi` then `bits` at offBmi = 32. Off/size fields are
    /// overridable to build malformed fixtures; `sizeOverride` writes a lying
    /// nSize.
    private static func brushRecord(
        type: UInt32,
        ihBrush: UInt32 = 1,
        usage: UInt32 = 0,          // DIB_RGB_COLORS
        bmi: [UInt8],
        bits: [UInt8],
        cbBmiOverride: UInt32? = nil,
        cbBitsOverride: UInt32? = nil,
        offBitsOverride: UInt32? = nil,
        sizeOverride: UInt32? = nil
    ) -> [UInt8] {
        let offBmi = 32
        let cbBmi = bmi.count
        let offBits = offBmi + cbBmi
        let cbBits = bits.count

        var payload = FixtureBuilder()            // starts at record offset 8
        payload.appendUInt32(ihBrush)             // ihBrush@8
        payload.appendUInt32(usage)               // iUsage@12
        payload.appendUInt32(UInt32(offBmi))      // offBmi@16
        payload.appendUInt32(cbBmiOverride ?? UInt32(cbBmi))   // cbBmi@20
        payload.appendUInt32(offBitsOverride ?? UInt32(offBits)) // offBits@24
        payload.appendUInt32(cbBitsOverride ?? UInt32(cbBits))   // cbBits@28
        payload.appendBytes(bmi)                  // @32 DIB header
        payload.appendBytes(bits)                 // DIB bits
        return FixtureBuilder.record(type: type, payload: payload.bytes, sizeOverride: sizeOverride)
    }

    /// Pulls the shared pattern-brush payload from either carrying case.
    private static func brushPayload(_ payload: EMFRecordPayload) -> CreateDIBPatternBrushPayload? {
        switch payload {
        case .createDIBPatternBrushPT(let p), .createMonoBrush(let p): return p
        default: return nil
        }
    }

    // A 24-bit 2×2 DIB: stride = ((2×24+31)/32)×4 = 8; 16 pixel bytes.
    private static let colorBMI = bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
    private static let colorBits: [UInt8] = Array(repeating: 0xAB, count: 16)

    // MARK: - CREATEDIBPATTERNBRUSHPT (94)

    @Test("CREATEDIBPATTERNBRUSHPT golden: colour DIB decodes to .pixels")
    func patternGolden() throws {
        let rec = Self.brushRecord(type: 94, ihBrush: 3, usage: 0, bmi: Self.colorBMI, bits: Self.colorBits)
        let payload = try decodeSingle(rec)
        guard case .createDIBPatternBrushPT(let p) = payload else {
            Issue.record("expected .createDIBPatternBrushPT, got \(payload)"); return
        }
        #expect(p.ihBrush == 3)
        #expect(p.usage == 0)
        #expect(p.dib.width == 2)
        #expect(p.dib.height == 2)
        #expect(p.dib.bitCount == 24)
        guard case .pixels(let bytes, let stride, _) = p.dib.content else {
            Issue.record("expected .pixels, got \(p.dib.content)"); return
        }
        #expect(stride == 8)
        #expect(bytes.count == 16)
    }

    @Test("CREATEDIBPATTERNBRUSHPT truncated below the 32-byte fixed part is .malformed")
    func patternTruncated() throws {
        // A 24-byte record cannot hold the 32-byte fixed part.
        let rec = FixtureBuilder.record(type: 94, payload: [UInt8](repeating: 0, count: 16))
        let payload = try decodeSingle(rec)
        #expect(payload.malformedReason != nil, "a short record must be .malformed")
    }

    @Test("CREATEDIBPATTERNBRUSHPT lying cbBits overruns the record → .malformed")
    func patternLyingSize() throws {
        // cbBits claims far more pixel bytes than the record carries.
        let rec = Self.brushRecord(
            type: 94, bmi: Self.colorBMI, bits: Self.colorBits,
            cbBitsOverride: 0xFFFF
        )
        let payload = try decodeSingle(rec)
        guard case .rangeOutOfBounds = payload.malformedReason else {
            Issue.record("expected .rangeOutOfBounds, got \(String(describing: payload.malformedReason))"); return
        }
    }

    @Test("CREATEDIBPATTERNBRUSHPT monochrome 1-bpp DIB decodes to .unsupported (valid)")
    func patternMonochromeContent() throws {
        // A 1-bpp DIB: the shared decoder returns a VALID `.unsupported` verdict,
        // NOT `.malformed`. Width 2, 1-bpp → stride 4; height 2 → 8 bytes.
        let monoBMI = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 1, colorUsed: 2)
        let palette: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 0]   // two RGBQuads
        let bits: [UInt8] = Array(repeating: 0xA0, count: 8)
        let rec = Self.brushRecord(type: 94, bmi: monoBMI + palette, bits: bits)
        let payload = try decodeSingle(rec)
        guard let p = Self.brushPayload(payload) else {
            Issue.record("expected a brush payload, got \(payload)"); return
        }
        guard case .unsupported(.bitCount(1)) = p.dib.content else {
            Issue.record("expected .unsupported(.bitCount(1)), got \(p.dib.content)"); return
        }
    }

    // MARK: - CREATEMONOBRUSH (93)

    @Test("CREATEMONOBRUSH shares the layout and decodes to its own case")
    func monoBrushCase() throws {
        let monoBMI = Self.bitmapInfoHeader(width: 8, height: 8, bitCount: 1, colorUsed: 2)
        let palette: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 0]
        // Width 8, 1-bpp → stride 4; height 8 → 32 bytes.
        let bits: [UInt8] = Array(repeating: 0x55, count: 32)
        let rec = Self.brushRecord(type: 93, ihBrush: 5, bmi: monoBMI + palette, bits: bits)
        let payload = try decodeSingle(rec)
        guard case .createMonoBrush(let p) = payload else {
            Issue.record("expected .createMonoBrush, got \(payload)"); return
        }
        #expect(p.ihBrush == 5)
        #expect(p.dib.bitCount == 1)
    }

    @Test("CREATEMONOBRUSH truncated is .malformed")
    func monoTruncated() throws {
        let rec = FixtureBuilder.record(type: 93, payload: [UInt8](repeating: 0, count: 12))
        let payload = try decodeSingle(rec)
        #expect(payload.malformedReason != nil)
    }

    // MARK: - SETBRUSHORGEX (13)

    @Test("SETBRUSHORGEX golden: a PointL origin")
    func brushOrgGolden() throws {
        var payload = FixtureBuilder()
        payload.appendInt32(12)    // x
        payload.appendInt32(-7)    // y
        let rec = FixtureBuilder.record(type: 13, payload: payload.bytes)
        let decoded = try decodeSingle(rec)
        guard case .setBrushOrgEx(let origin) = decoded else {
            Issue.record("expected .setBrushOrgEx, got \(decoded)"); return
        }
        #expect(origin.x == 12)
        #expect(origin.y == -7)
    }

    @Test("SETBRUSHORGEX truncated below 16 bytes is .malformed")
    func brushOrgTruncated() throws {
        // Only 4 payload bytes — a PointL needs 8.
        let rec = FixtureBuilder.record(type: 13, payload: [0, 0, 0, 0])
        let decoded = try decodeSingle(rec)
        #expect(decoded.malformedReason != nil)
    }
}
