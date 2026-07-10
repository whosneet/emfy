import Foundation
import Testing
@testable import EMFParse

@Suite("Bitmap record payload decode")
struct PayloadBitmapTests {

    // MARK: - DIB fixture helpers

    /// A 40-byte BitmapInfoHeader ([MS-WMF] §2.2.2.3, verified layout in the
    /// task). `height` is signed (negative = top-down).
    private static func bitmapInfoHeader(
        width: Int32,
        height: Int32,
        bitCount: UInt16,
        compression: UInt32 = 0,      // BI_RGB
        imageSize: UInt32 = 0,
        colorUsed: UInt32 = 0
    ) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendUInt32(40)            // HeaderSize
        b.appendInt32(width)          // Width
        b.appendInt32(height)         // Height (signed)
        b.appendUInt16(1)             // Planes (MUST be 1)
        b.appendUInt16(bitCount)      // BitCount
        b.appendUInt32(compression)   // Compression
        b.appendUInt32(imageSize)     // ImageSize
        b.appendInt32(2835)           // XPelsPerMeter
        b.appendInt32(2835)           // YPelsPerMeter
        b.appendUInt32(colorUsed)     // ColorUsed
        b.appendUInt32(0)             // ColorImportant
        return b.bytes
    }

    /// Builds an EMR_STRETCHDIBITS record. The 80-byte fixed part is followed
    /// by `bmi` then `bits`, at record-relative offsets 80 and 80+cbBmi. All
    /// four off/cb fields can be overridden to build malformed fixtures.
    private static func stretchDIBitsRecord(
        bounds: RectL = RectL(left: 0, top: 0, right: 8, bottom: 8),
        dest: PointL = PointL(x: 0, y: 0),
        destSize: SizeL = SizeL(cx: 8, cy: 8),
        src: PointL = PointL(x: 0, y: 0),
        srcSize: SizeL = SizeL(cx: 8, cy: 8),
        usageSrc: UInt32 = 0,          // DIB_RGB_COLORS
        rasterOperation: UInt32 = 0x00CC0020, // SRCCOPY
        bmi: [UInt8],
        bits: [UInt8],
        cbBitsOverride: UInt32? = nil,
        offBitsOverride: UInt32? = nil
    ) -> [UInt8] {
        let offBmi = 80
        let cbBmi = bmi.count
        let offBits = offBmi + cbBmi
        let cbBits = bits.count

        var payload = FixtureBuilder()  // starts at record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(bounds)) // Bounds@8 (16)
        payload.appendInt32(dest.x)                 // xDest@24
        payload.appendInt32(dest.y)                 // yDest@28
        payload.appendInt32(src.x)                  // xSrc@32
        payload.appendInt32(src.y)                  // ySrc@36
        payload.appendInt32(srcSize.cx)             // cxSrc@40
        payload.appendInt32(srcSize.cy)             // cySrc@44
        payload.appendUInt32(UInt32(offBmi))        // offBmiSrc@48
        payload.appendUInt32(UInt32(cbBmi))         // cbBmiSrc@52
        payload.appendUInt32(offBitsOverride ?? UInt32(offBits)) // offBitsSrc@56
        payload.appendUInt32(cbBitsOverride ?? UInt32(cbBits))   // cbBitsSrc@60
        payload.appendUInt32(usageSrc)              // UsageSrc@64
        payload.appendUInt32(rasterOperation)       // BitBltRasterOperation@68
        payload.appendInt32(destSize.cx)            // cxDest@72
        payload.appendInt32(destSize.cy)            // cyDest@76
        // payload length now 72 (record offsets 8..80). BMI at 80, bits after.
        payload.appendBytes(bmi)
        payload.appendBytes(bits)
        return FixtureBuilder.record(type: 81, payload: payload.bytes)
    }

    private static func dib(from payload: EMFRecordPayload) -> DIB? {
        if case .stretchDIBits(let p) = payload { return p.dib }
        return nil
    }

    /// Builds a sourceless EMR_STRETCHDIBITS (80-byte fixed part, no bitmap):
    /// offBmiSrc/cbBmiSrc/offBitsSrc/cbBitsSrc all 0 — the valid rop-only form.
    private static func stretchDIBitsSourceless(
        dest: PointL = PointL(x: 0, y: 0),
        destSize: SizeL = SizeL(cx: 8, cy: 8),
        rasterOperation: UInt32 = 0x0000_0042   // BLACKNESS
    ) -> [UInt8] {
        var payload = FixtureBuilder()  // record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 8, bottom: 8))) // Bounds@8
        payload.appendInt32(dest.x)                 // xDest@24
        payload.appendInt32(dest.y)                 // yDest@28
        payload.appendInt32(0)                      // xSrc@32
        payload.appendInt32(0)                      // ySrc@36
        payload.appendInt32(0)                      // cxSrc@40
        payload.appendInt32(0)                      // cySrc@44
        payload.appendUInt32(0)                     // offBmiSrc@48 == 0
        payload.appendUInt32(0)                     // cbBmiSrc@52 == 0 → sourceless
        payload.appendUInt32(0)                     // offBitsSrc@56
        payload.appendUInt32(0)                     // cbBitsSrc@60
        payload.appendUInt32(0)                     // UsageSrc@64
        payload.appendUInt32(rasterOperation)       // BitBltRasterOperation@68
        payload.appendInt32(destSize.cx)            // cxDest@72
        payload.appendInt32(destSize.cy)            // cyDest@76
        return FixtureBuilder.record(type: 81, payload: payload.bytes)
    }

    /// Builds an EMR_SETDIBITSTODEVICE record WITH a source DIB. The 76-byte
    /// fixed part is followed by `bmi` then `bits`, at record-relative offsets
    /// 76 and 76+cbBmi. off/cb fields can be overridden to build malformed
    /// fixtures.
    private static func setDIBitsToDeviceRecord(
        bounds: RectL = RectL(left: 0, top: 0, right: 8, bottom: 8),
        dest: PointL = PointL(x: 0, y: 0),
        src: PointL = PointL(x: 0, y: 0),
        srcSize: SizeL = SizeL(cx: 8, cy: 8),
        usageSrc: UInt32 = 0,
        startScan: UInt32 = 0,
        scanCount: UInt32 = 8,
        bmi: [UInt8],
        bits: [UInt8],
        offBmiOverride: UInt32? = nil,
        offBitsOverride: UInt32? = nil
    ) -> [UInt8] {
        let offBmi = 76
        let cbBmi = bmi.count
        let offBits = offBmi + cbBmi
        let cbBits = bits.count

        var payload = FixtureBuilder()  // record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(bounds))   // Bounds@8
        payload.appendInt32(dest.x)                 // xDest@24
        payload.appendInt32(dest.y)                 // yDest@28
        payload.appendInt32(src.x)                  // xSrc@32
        payload.appendInt32(src.y)                  // ySrc@36
        payload.appendInt32(srcSize.cx)             // cxSrc@40
        payload.appendInt32(srcSize.cy)             // cySrc@44
        payload.appendUInt32(offBmiOverride ?? UInt32(offBmi))   // offBmiSrc@48
        payload.appendUInt32(UInt32(cbBmi))         // cbBmiSrc@52
        payload.appendUInt32(offBitsOverride ?? UInt32(offBits)) // offBitsSrc@56
        payload.appendUInt32(UInt32(cbBits))        // cbBitsSrc@60
        payload.appendUInt32(usageSrc)              // UsageSrc@64
        payload.appendUInt32(startScan)             // iStartScan@68
        payload.appendUInt32(scanCount)             // cScans@72
        // payload length now 68 (record offsets 8..76). BMI at 76, bits after.
        payload.appendBytes(bmi)
        payload.appendBytes(bits)
        return FixtureBuilder.record(type: 80, payload: payload.bytes)
    }

    /// Builds an EMR_STRETCHBLT record WITH a source DIB. The 108-byte fixed
    /// part (BITBLT's 100 + cxSrc/cySrc) is followed by `bmi` then `bits`, at
    /// record-relative offsets 108 and 108+cbBmi.
    private static func stretchBltRecord(
        bounds: RectL = RectL(left: 0, top: 0, right: 8, bottom: 8),
        dest: PointL = PointL(x: 0, y: 0),
        destSize: SizeL = SizeL(cx: 8, cy: 8),
        src: PointL = PointL(x: 0, y: 0),
        srcSize: SizeL = SizeL(cx: 4, cy: 4),
        rasterOperation: UInt32 = 0x00CC0020,   // SRCCOPY
        usageSrc: UInt32 = 0,
        bmi: [UInt8],
        bits: [UInt8]
    ) -> [UInt8] {
        let offBmi = 108
        let cbBmi = bmi.count
        let offBits = offBmi + cbBmi
        let cbBits = bits.count

        var payload = FixtureBuilder()  // record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(bounds))   // Bounds@8
        payload.appendInt32(dest.x)                 // xDest@24
        payload.appendInt32(dest.y)                 // yDest@28
        payload.appendInt32(destSize.cx)            // cxDest@32
        payload.appendInt32(destSize.cy)            // cyDest@36
        payload.appendUInt32(rasterOperation)       // BitBltRasterOperation@40
        payload.appendInt32(src.x)                  // xSrc@44
        payload.appendInt32(src.y)                  // ySrc@48
        // XformSrc@52 (24 bytes) — identity.
        payload.appendFloat(1); payload.appendFloat(0)
        payload.appendFloat(0); payload.appendFloat(1)
        payload.appendFloat(0); payload.appendFloat(0)
        payload.appendBytes([0, 0, 0, 0])           // BkColorSrc@76
        payload.appendUInt32(usageSrc)              // UsageSrc@80
        payload.appendUInt32(UInt32(offBmi))        // offBmiSrc@84
        payload.appendUInt32(UInt32(cbBmi))         // cbBmiSrc@88
        payload.appendUInt32(UInt32(offBits))       // offBitsSrc@92
        payload.appendUInt32(UInt32(cbBits))        // cbBitsSrc@96
        payload.appendInt32(srcSize.cx)             // cxSrc@100 (STRETCHBLT only)
        payload.appendInt32(srcSize.cy)             // cySrc@104
        // payload length now 100 (record offsets 8..108). BMI at 108, bits after.
        payload.appendBytes(bmi)
        payload.appendBytes(bits)
        return FixtureBuilder.record(type: 77, payload: payload.bytes)
    }

    /// Builds a sourceless EMR_SETDIBITSTODEVICE (76-byte fixed part, no
    /// bitmap): offBmiSrc/cbBmiSrc/offBitsSrc/cbBitsSrc all 0. No raster op.
    private static func setDIBitsToDeviceSourceless(
        dest: PointL = PointL(x: 0, y: 0),
        srcSize: SizeL = SizeL(cx: 8, cy: 8)
    ) -> [UInt8] {
        var payload = FixtureBuilder()  // record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 8, bottom: 8))) // Bounds@8
        payload.appendInt32(dest.x)                 // xDest@24
        payload.appendInt32(dest.y)                 // yDest@28
        payload.appendInt32(0)                      // xSrc@32
        payload.appendInt32(0)                      // ySrc@36
        payload.appendInt32(srcSize.cx)             // cxSrc@40
        payload.appendInt32(srcSize.cy)             // cySrc@44
        payload.appendUInt32(0)                     // offBmiSrc@48 == 0
        payload.appendUInt32(0)                     // cbBmiSrc@52 == 0 → sourceless
        payload.appendUInt32(0)                     // offBitsSrc@56
        payload.appendUInt32(0)                     // cbBitsSrc@60
        payload.appendUInt32(0)                     // UsageSrc@64
        payload.appendUInt32(0)                     // iStartScan@68
        payload.appendUInt32(0)                     // cScans@72
        return FixtureBuilder.record(type: 80, payload: payload.bytes)
    }

    // MARK: - 24-bit golden

    @Test("STRETCHDIBITS 24-bit 2×2 golden: stride padding asserted")
    func stretch24Golden() throws {
        // Width 2, 24-bit → row = 2×3 = 6 bytes, padded to a 4-byte multiple
        // = stride 8 (2 padding bytes per row). Height 2 → 16 bytes required.
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        // Two rows of two BGR pixels + 2 padding bytes each.
        let row0: [UInt8] = [0x10, 0x20, 0x30,  0x40, 0x50, 0x60,  0xAA, 0xBB]
        let row1: [UInt8] = [0x11, 0x21, 0x31,  0x41, 0x51, 0x61,  0xCC, 0xDD]
        let bits = row0 + row1
        #expect(bits.count == 16)
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            bounds: RectL(left: 0, top: 0, right: 2, bottom: 2),
            destSize: SizeL(cx: 2, cy: 2),
            srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: bits
        ))
        let d = try #require(Self.dib(from: payload))
        #expect(d.width == 2)
        #expect(d.height == 2)
        #expect(d.bitCount == 24)
        #expect(d.compression == .rgb)
        #expect(d.isTopDown == false)
        guard case .pixels(let bytes, let stride, let palette) = d.content else {
            Issue.record("expected .pixels, got \(d.content)")
            return
        }
        #expect(stride == 8)                       // 6 rounded up to a 4-multiple
        #expect(palette.isEmpty)                   // truecolor has no palette
        #expect(bytes.count == 16)                 // stride × |height|
        #expect(Array(bytes) == bits)
    }

    @Test("STRETCHDIBITS golden with full field set: geometry, usage, rop")
    func stretchFullFieldSet() throws {
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        let bits = [UInt8](repeating: 0x55, count: 16)
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            bounds: RectL(left: 3, top: 4, right: 33, bottom: 44),
            dest: PointL(x: 3, y: 4),
            destSize: SizeL(cx: 30, cy: 40),
            src: PointL(x: 1, y: 1),
            srcSize: SizeL(cx: 2, cy: 2),
            usageSrc: 0,                   // DIB_RGB_COLORS
            rasterOperation: 0x00CC0020,   // SRCCOPY
            bmi: bmi, bits: bits
        ))
        guard case .stretchDIBits(let p) = payload else {
            Issue.record("expected .stretchDIBits, got \(payload)")
            return
        }
        #expect(p.bounds == RectL(left: 3, top: 4, right: 33, bottom: 44))
        #expect(p.dest == PointL(x: 3, y: 4))
        #expect(p.destSize == SizeL(cx: 30, cy: 40))
        #expect(p.src == PointL(x: 1, y: 1))
        #expect(p.srcSize == SizeL(cx: 2, cy: 2))
        #expect(p.usageSrc == 0)
        #expect(p.rasterOperation == 0x00CC0020)
        #expect(p.dib != nil)
    }

    // MARK: - 32-bit golden

    @Test("STRETCHDIBITS 32-bit golden: stride == width×4, no padding")
    func stretch32Golden() throws {
        // Width 2, 32-bit → row = 8, already 4-aligned → stride 8. Height 2.
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 32)
        let bits: [UInt8] = Array(0 ..< 16)        // 2 rows × 8 bytes
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: bits
        ))
        let d = try #require(Self.dib(from: payload))
        #expect(d.bitCount == 32)
        guard case .pixels(let bytes, let stride, let palette) = d.content else {
            Issue.record("expected .pixels, got \(d.content)")
            return
        }
        #expect(stride == 8)
        #expect(palette.isEmpty)
        #expect(Array(bytes) == bits)
    }

    // MARK: - 8-bit palettised golden

    @Test("STRETCHDIBITS 8-bit palettised golden: palette BGRX order asserted")
    func stretch8Palettised() throws {
        // Width 2, 8-bit → row = 2, padded to stride 4. Height 2 → 8 bytes.
        // ColorUsed = 2 → a 2-entry palette right after the 40-byte header.
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 8, colorUsed: 2)
        // Palette quads on disk are Blue, Green, Red, Reserved ([MS-WMF] §2.2.2.20).
        let palette: [UInt8] = [
            0x01, 0x02, 0x03, 0x00,   // entry 0: B=1 G=2 R=3
            0xF0, 0xE0, 0xD0, 0x00,   // entry 1: B=F0 G=E0 R=D0
        ]
        let row0: [UInt8] = [0, 1, 0x00, 0x00]     // 2 indices + 2 padding
        let row1: [UInt8] = [1, 0, 0x00, 0x00]
        let bits = row0 + row1
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi + palette, bits: bits
        ))
        let d = try #require(Self.dib(from: payload))
        #expect(d.bitCount == 8)
        guard case .pixels(let bytes, let stride, let pal) = d.content else {
            Issue.record("expected .pixels, got \(d.content)")
            return
        }
        #expect(stride == 4)
        #expect(bytes.count == 8)
        #expect(pal.count == 2)
        // Reversed order relative to ColorRef: quad byte 0 is Blue, not Red.
        #expect(pal[0] == RGBQuad(blue: 0x01, green: 0x02, red: 0x03, reserved: 0))
        #expect(pal[1] == RGBQuad(blue: 0xF0, green: 0xE0, red: 0xD0, reserved: 0))
    }

    @Test("STRETCHDIBITS 8-bit with ColorUsed 0 → 256-entry palette")
    func stretch8DefaultPalette() throws {
        let bmi = Self.bitmapInfoHeader(width: 1, height: 1, bitCount: 8, colorUsed: 0)
        let palette = [UInt8](repeating: 0x7F, count: 256 * 4)  // 256 quads
        let bits: [UInt8] = [0, 0, 0, 0]           // width 1 → stride 4
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            bounds: RectL(left: 0, top: 0, right: 1, bottom: 1),
            destSize: SizeL(cx: 1, cy: 1), srcSize: SizeL(cx: 1, cy: 1),
            bmi: bmi + palette, bits: bits
        ))
        let d = try #require(Self.dib(from: payload))
        guard case .pixels(_, _, let pal) = d.content else {
            Issue.record("expected .pixels, got \(d.content)")
            return
        }
        #expect(pal.count == 256)                  // 0 means 256 entries
    }

    // MARK: - Negative height (top-down)

    @Test("STRETCHDIBITS negative height → top-down flag, still decoded")
    func stretchTopDown() throws {
        let bmi = Self.bitmapInfoHeader(width: 2, height: -2, bitCount: 24)
        let bits = [UInt8](repeating: 0, count: 16)  // stride 8 × |height| 2
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: bits
        ))
        let d = try #require(Self.dib(from: payload))
        #expect(d.height == -2)                    // sign carried
        #expect(d.isTopDown == true)
        guard case .pixels(_, let stride, _) = d.content else {
            Issue.record("expected .pixels")
            return
        }
        #expect(stride == 8)                       // |height| used for the size
    }

    // MARK: - Unsupported (valid, not malformed)

    @Test("STRETCHDIBITS BI_RLE8 → .unsupported(compression), not malformed")
    func stretchRLE8Unsupported() throws {
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 8, compression: 1) // BI_RLE8
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: [0, 0, 0, 0]
        ))
        #expect(payload.malformedReason == nil)    // VALID payload
        let d = try #require(Self.dib(from: payload))
        #expect(d.content == .unsupported(.compression(.rle8)))
    }

    @Test("STRETCHDIBITS 1-bit → .unsupported(bitCount), not malformed")
    func stretch1BitUnsupported() throws {
        let bmi = Self.bitmapInfoHeader(width: 8, height: 1, bitCount: 1)
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            bounds: RectL(left: 0, top: 0, right: 8, bottom: 1),
            destSize: SizeL(cx: 8, cy: 1), srcSize: SizeL(cx: 8, cy: 1),
            bmi: bmi, bits: [0, 0, 0, 0]
        ))
        #expect(payload.malformedReason == nil)
        let d = try #require(Self.dib(from: payload))
        #expect(d.content == .unsupported(.bitCount(1)))
    }

    // MARK: - Malformed (hostile)

    @Test("STRETCHDIBITS lying cbBitsSrc (required > available) → malformed")
    func stretchLyingCbBits() throws {
        // A valid 2×2 24-bit DIB needs 16 bytes; claim only 8 in cbBitsSrc.
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        let bits = [UInt8](repeating: 0, count: 16)
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: bits,
            cbBitsOverride: 8              // LIES: required (16) > available (8)
        ))
        #expect(payload.malformedReason != nil)
    }

    @Test("STRETCHDIBITS absurd Width → malformed (dimension cap), walk unaffected")
    func stretchAbsurdWidth() throws {
        let bmi = Self.bitmapInfoHeader(width: 1_000_000, height: 1, bitCount: 24)
        let (file, record) = try parseWithSingleRecord(Self.stretchDIBitsRecord(
            bmi: bmi, bits: [0, 0, 0, 0]
        ))
        #expect(file.diagnostics.isEmpty)          // walk untouched
        let payload = file.payload(of: record)
        guard case .malformed(let type, let reason) = payload else {
            Issue.record("expected .malformed, got \(payload)")
            return
        }
        #expect(type == 81)
        #expect(reason == .badBitmapDimensions(width: 1_000_000, height: 1))
    }

    @Test("STRETCHDIBITS over the 4 MP decode budget is refused before reading pixel bytes")
    func stretchOverDecodeBudget() throws {
        // This is below the former 100 MP cap but exceeds the strict 4 MP
        // output budget. The intentionally tiny bits range proves the decoder
        // rejects dimensions before it tries to materialise source pixels.
        let bmi = Self.bitmapInfoHeader(width: 4_096, height: 1_025, bitCount: 32)
        let (file, record) = try parseWithSingleRecord(Self.stretchDIBitsRecord(
            bmi: bmi, bits: [0, 0, 0, 0]
        ))
        #expect(file.diagnostics.isEmpty)          // walk remains best-effort

        let payload = file.payload(of: record)
        #expect(payload == .malformed(
            type: 81,
            reason: .badBitmapDimensions(width: 4_096, height: 1_025)
        ))
    }

    // MARK: - Sourceless (cbBmiSrc == 0) — valid, dib nil (not malformed)

    @Test("STRETCHDIBITS sourceless (cbBmiSrc == 0) → dib nil, not malformed")
    func stretchDIBitsSourcelessDecodes() throws {
        // A rop-only STRETCHDIBITS with all four off/cb DIB fields 0. Before the
        // fix this decoded DIB unconditionally and became .malformed(.tooSmall);
        // it must now decode to a .stretchDIBits payload whose dib is nil.
        let payload = try decodeSingle(Self.stretchDIBitsSourceless(
            dest: PointL(x: 1, y: 2),
            destSize: SizeL(cx: 10, cy: 10),
            rasterOperation: 0x0000_0042   // BLACKNESS
        ))
        guard case .stretchDIBits(let p) = payload else {
            Issue.record("expected .stretchDIBits, got \(payload)")
            return
        }
        #expect(p.dib == nil)
        #expect(p.rasterOperation == 0x0000_0042)
        #expect(p.dest == PointL(x: 1, y: 2))
        #expect(p.destSize == SizeL(cx: 10, cy: 10))
    }

    @Test("SETDIBITSTODEVICE sourceless (cbBmiSrc == 0) → dib nil, not malformed")
    func setDIBitsToDeviceSourcelessDecodes() throws {
        let payload = try decodeSingle(Self.setDIBitsToDeviceSourceless(
            dest: PointL(x: 3, y: 4),
            srcSize: SizeL(cx: 8, cy: 8)
        ))
        guard case .setDIBitsToDevice(let p) = payload else {
            Issue.record("expected .setDIBitsToDevice, got \(payload)")
            return
        }
        #expect(p.dib == nil)
        #expect(p.dest == PointL(x: 3, y: 4))
        #expect(p.srcSize == SizeL(cx: 8, cy: 8))
    }

    // MARK: - BITBLT sourceless

    @Test("BITBLT sourceless golden: rop carried, no DIB")
    func bitBltSourceless() throws {
        // A rop-only BITBLT (cbBmiSrc == 0): 100-byte fixed part, no bitmap.
        var payload = FixtureBuilder()  // record offset 8
        payload.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 10, bottom: 10))) // Bounds@8
        payload.appendInt32(1)          // xDest@24
        payload.appendInt32(2)          // yDest@28
        payload.appendInt32(10)         // cxDest@32
        payload.appendInt32(10)         // cyDest@36
        payload.appendUInt32(0x00000042) // BitBltRasterOperation@40 (BLACKNESS)
        payload.appendInt32(0)          // xSrc@44
        payload.appendInt32(0)          // ySrc@48
        // XformSrc@52 (24 bytes) — identity.
        payload.appendFloat(1); payload.appendFloat(0)
        payload.appendFloat(0); payload.appendFloat(1)
        payload.appendFloat(0); payload.appendFloat(0)
        payload.appendBytes([0x11, 0x22, 0x33, 0x00]) // BkColorSrc@76
        payload.appendUInt32(0)         // UsageSrc@80
        payload.appendUInt32(0)         // offBmiSrc@84
        payload.appendUInt32(0)         // cbBmiSrc@88 == 0 → sourceless
        payload.appendUInt32(0)         // offBitsSrc@92
        payload.appendUInt32(0)         // cbBitsSrc@96
        // Record = 8 + 92 = 100 bytes.
        let record = FixtureBuilder.record(type: 76, payload: payload.bytes)
        let decoded = try decodeSingle(record)
        guard case .bitBlt(let blt) = decoded else {
            Issue.record("expected .bitBlt, got \(decoded)")
            return
        }
        #expect(blt.hasSource == false)
        #expect(blt.dib == nil)
        #expect(blt.rasterOperation == 0x00000042)
        #expect(blt.dest == PointL(x: 1, y: 2))
        #expect(blt.destSize == SizeL(cx: 10, cy: 10))
        #expect(blt.bkColorSrc == ColorRef(red: 0x11, green: 0x22, blue: 0x33, reserved: 0))
        #expect(blt.srcSize == nil)     // BITBLT has no source size
        #expect(blt.xformSrc == XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 0, dy: 0))
    }

    @Test("BITBLT non-finite XformSrc → malformed")
    func bitBltNonFiniteXform() throws {
        var payload = FixtureBuilder()
        payload.appendBytes(FixtureBuilder.rectBytes(RectL(left: 0, top: 0, right: 1, bottom: 1)))
        payload.appendInt32(0); payload.appendInt32(0)  // dest
        payload.appendInt32(1); payload.appendInt32(1)  // destSize
        payload.appendUInt32(0x00CC0020)                // rop
        payload.appendInt32(0); payload.appendInt32(0)  // src
        payload.appendFloat(.nan); payload.appendFloat(0) // XformSrc — NaN
        payload.appendFloat(0); payload.appendFloat(1)
        payload.appendFloat(0); payload.appendFloat(0)
        payload.appendBytes([0, 0, 0, 0])               // BkColorSrc
        payload.appendUInt32(0)                          // UsageSrc
        payload.appendUInt32(0); payload.appendUInt32(0) // offBmi/cbBmi
        payload.appendUInt32(0); payload.appendUInt32(0) // offBits/cbBits
        let record = FixtureBuilder.record(type: 76, payload: payload.bytes)
        #expect(try decodeSingle(record) == .malformed(type: 76, reason: .nonFiniteTransform))
    }

    // MARK: - SETDIBITSTODEVICE with a real source DIB

    @Test("SETDIBITSTODEVICE with source DIB: fields + non-nil dib")
    func setDIBitsToDeviceSourced() throws {
        // A 2×2 24-bit BI_RGB DIB (stride 8, 16 bytes) carried by the record.
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        let bits = [UInt8](repeating: 0x33, count: 16)
        let payload = try decodeSingle(Self.setDIBitsToDeviceRecord(
            dest: PointL(x: 3, y: 4),
            src: PointL(x: 1, y: 0),
            srcSize: SizeL(cx: 2, cy: 2),
            startScan: 1,
            scanCount: 2,
            bmi: bmi, bits: bits
        ))
        guard case .setDIBitsToDevice(let p) = payload else {
            Issue.record("expected .setDIBitsToDevice, got \(payload)")
            return
        }
        #expect(p.dest == PointL(x: 3, y: 4))
        #expect(p.src == PointL(x: 1, y: 0))
        #expect(p.srcSize == SizeL(cx: 2, cy: 2))
        #expect(p.startScan == 1)
        #expect(p.scanCount == 2)
        let d = try #require(p.dib, "sourced SETDIBITSTODEVICE must decode a DIB")
        #expect(d.width == 2)
        #expect(d.height == 2)
        #expect(d.bitCount == 24)
        guard case .pixels(let bytes, let stride, _) = d.content else {
            Issue.record("expected .pixels, got \(d.content)")
            return
        }
        #expect(stride == 8)
        #expect(Array(bytes) == bits)
    }

    // MARK: - STRETCHBLT with a real source DIB (stretch / srcSize branch)

    @Test("STRETCHBLT with source DIB: srcSize set, non-nil dib, stretch branch")
    func stretchBltSourced() throws {
        // Source DIB is 4×4 24-bit (stride 12, 48 bytes); dest is 8×8, so the
        // blit stretches — exercising decodeBitBlt's stretch:true srcSize read
        // at offsets 100/104 that BITBLT lacks.
        let bmi = Self.bitmapInfoHeader(width: 4, height: 4, bitCount: 24)
        let bits = [UInt8](repeating: 0x7A, count: 12 * 4)
        let payload = try decodeSingle(Self.stretchBltRecord(
            dest: PointL(x: 2, y: 2),
            destSize: SizeL(cx: 8, cy: 8),
            src: PointL(x: 0, y: 0),
            srcSize: SizeL(cx: 4, cy: 4),
            bmi: bmi, bits: bits
        ))
        guard case .stretchBlt(let blt) = payload else {
            Issue.record("expected .stretchBlt, got \(payload)")
            return
        }
        #expect(blt.hasSource == true)
        #expect(blt.srcSize == SizeL(cx: 4, cy: 4))   // STRETCHBLT carries it (BITBLT nil)
        #expect(blt.dest == PointL(x: 2, y: 2))
        #expect(blt.destSize == SizeL(cx: 8, cy: 8))
        #expect(blt.rasterOperation == 0x00CC0020)
        let d = try #require(blt.dib, "sourced STRETCHBLT must decode a DIB")
        #expect(d.width == 4)
        #expect(d.height == 4)
        #expect(d.bitCount == 24)
    }

    // MARK: - Bad / unsupported DIB header size and out-of-bounds offsets

    @Test("DIB with BITMAPCOREHEADER size (biSize 12, not 40) → badBitmapHeader")
    func dibBadHeaderSize() throws {
        // cbBmiSrc is a valid 40 bytes (so the header prefix is present and the
        // record is walk-valid), but the header's own biSize field says 12
        // (BITMAPCOREHEADER) — below the 40-byte BITMAPINFOHEADER minimum. The
        // decoder must reject with badBitmapHeader, not misparse a V-something.
        var bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        bmi[0] = 12; bmi[1] = 0; bmi[2] = 0; bmi[3] = 0   // biSize = 12
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: [UInt8](repeating: 0, count: 16)
        ))
        #expect(payload == .malformed(type: 81, reason: .badBitmapHeader(headerSize: 12)))
    }

    @Test("DIB offBitsSrc pointing outside the record → rangeOutOfBounds")
    func dibOffBitsOutOfBounds() throws {
        // offBitsSrc lies far past nSize: the bits range fails its bounds check
        // against the record's own size before any pixel byte is read (§8).
        let bmi = Self.bitmapInfoHeader(width: 2, height: 2, bitCount: 24)
        let bits = [UInt8](repeating: 0, count: 16)
        let payload = try decodeSingle(Self.stretchDIBitsRecord(
            destSize: SizeL(cx: 2, cy: 2), srcSize: SizeL(cx: 2, cy: 2),
            bmi: bmi, bits: bits,
            offBitsOverride: 100_000
        ))
        guard case .malformed(let type, let reason) = payload else {
            Issue.record("expected .malformed, got \(payload)")
            return
        }
        #expect(type == 81)
        guard case .rangeOutOfBounds(let offset, let length, _) = reason else {
            Issue.record("expected .rangeOutOfBounds, got \(reason)")
            return
        }
        #expect(offset == 100_000)
        #expect(length == 16)          // cbBitsSrc (real bits length) carried as the length
    }
}
