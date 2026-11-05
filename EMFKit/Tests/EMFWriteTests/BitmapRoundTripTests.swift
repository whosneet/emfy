import Foundation
import Testing
import EMFParse
import EMFWrite

/// Per-record round-trip for the four bitmap records, exercising a 24-bit
/// BI_RGB DIB, an 8-bit palettised DIB, a sourceless (rop-only) blit, and the
/// STRETCHBLT 108-byte fixed part. Each fixture is built in the canonical form
/// the encoder emits (40-byte BITMAPINFOHEADER, Planes 1, ClrUsed = palette
/// count), so decode → encode is byte-identical.
@Suite("Bitmap record round-trip")
struct BitmapRoundTripTests {

    static func rect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] {
        var w = LE(); w.i32(l); w.i32(t); w.i32(r); w.i32(b); return w.bytes
    }

    /// A canonical 40-byte BITMAPINFOHEADER plus palette.
    static func bmi(width: Int32, height: Int32, bitCount: UInt16, sizeImage: UInt32, palette: [[UInt8]]) -> [UInt8] {
        var b = LE()
        b.u32(40)                                 // HeaderSize
        b.i32(width); b.i32(height)               // Width, Height
        b.u16(1); b.u16(bitCount)                 // Planes, BitCount
        b.u32(0)                                  // Compression = BI_RGB
        b.u32(sizeImage)                          // SizeImage
        b.i32(0); b.i32(0)                        // XPels, YPels
        b.u32(UInt32(palette.count)); b.u32(0)    // ClrUsed, ClrImportant
        for quad in palette { b.raw(quad) }       // RGBQuad: B,G,R,X
        return b.bytes
    }

    @Test func stretchDIBits24bit() throws {
        let bits: [UInt8] = Array(0 ..< 16)       // 2×2, stride 8, 16 bytes
        let dib = Self.bmi(width: 2, height: 2, bitCount: 24, sizeImage: 16, palette: [])
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 2, 2))          // Bounds
            b.i32(0); b.i32(0)                    // xDest, yDest
            b.i32(0); b.i32(0)                    // xSrc, ySrc
            b.i32(2); b.i32(2)                    // cxSrc, cySrc
            b.u32(80); b.u32(40)                  // offBmiSrc, cbBmiSrc
            b.u32(120); b.u32(16)                 // offBitsSrc, cbBitsSrc
            b.u32(0)                              // UsageSrc
            b.u32(0x00CC_0020)                    // SRCCOPY
            b.i32(2); b.i32(2)                    // cxDest, cyDest
            b.raw(dib); b.raw(bits)
            return b.bytes }()
        try assertRoundTrip(LE.record(81, body)) {
            if case .stretchDIBits(let p) = $0, let d = p.dib, case .pixels = d.content {
                return d.bitCount == 24 && d.width == 2 && d.height == 2
            }; return false
        }
    }

    @Test func setDIBitsToDevice8bitPalette() throws {
        let palette: [[UInt8]] = [[0, 0, 0, 0], [255, 255, 255, 0], [0, 0, 255, 0], [0, 255, 0, 0]]
        let bits: [UInt8] = Array(0 ..< 8)        // 2×2, 8-bit, stride 4, 8 bytes
        let dib = Self.bmi(width: 2, height: 2, bitCount: 8, sizeImage: 8, palette: palette)
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 2, 2))
            b.i32(0); b.i32(0)                    // xDest, yDest
            b.i32(0); b.i32(0)                    // xSrc, ySrc
            b.i32(2); b.i32(2)                    // cxSrc, cySrc
            b.u32(76); b.u32(56)                  // offBmiSrc (76), cbBmiSrc (40 + 4*4)
            b.u32(132); b.u32(8)                  // offBitsSrc, cbBitsSrc
            b.u32(0)                              // UsageSrc
            b.u32(0); b.u32(2)                    // iStartScan, cScans
            b.raw(dib); b.raw(bits)
            return b.bytes }()
        try assertRoundTrip(LE.record(80, body)) {
            if case .setDIBitsToDevice(let p) = $0, let d = p.dib,
               case .pixels(_, _, let pal) = d.content {
                return d.bitCount == 8 && pal.count == 4
            }; return false
        }
    }

    @Test func bitBltSourceless() throws {
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 10, 10))        // Bounds
            b.i32(0); b.i32(0)                    // xDest, yDest
            b.i32(10); b.i32(10)                  // cxDest, cyDest
            b.u32(0x00F0_0021)                    // PATCOPY rop
            b.i32(0); b.i32(0)                    // xSrc, ySrc
            b.f32(1); b.f32(0); b.f32(0); b.f32(1); b.f32(0); b.f32(0)  // XformSrc (identity)
            b.u8(0); b.u8(0); b.u8(0); b.u8(0)    // BkColorSrc
            b.u32(0)                              // UsageSrc
            b.u32(0); b.u32(0); b.u32(0); b.u32(0)  // offBmi/cbBmi/offBits/cbBits = none
            return b.bytes }()
        try assertRoundTrip(LE.record(76, body)) {
            if case .bitBlt(let p) = $0 { return p.dib == nil && p.srcSize == nil }; return false
        }
    }

    @Test func stretchBlt24bitSource() throws {
        let bits: [UInt8] = Array(0 ..< 16)
        let dib = Self.bmi(width: 2, height: 2, bitCount: 24, sizeImage: 16, palette: [])
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 4, 4))          // Bounds
            b.i32(0); b.i32(0)                    // xDest, yDest
            b.i32(4); b.i32(4)                    // cxDest, cyDest
            b.u32(0x00CC_0020)                    // SRCCOPY
            b.i32(0); b.i32(0)                    // xSrc, ySrc
            b.f32(1); b.f32(0); b.f32(0); b.f32(1); b.f32(0); b.f32(0)  // XformSrc
            b.u8(0); b.u8(0); b.u8(0); b.u8(0)    // BkColorSrc
            b.u32(0)                              // UsageSrc
            b.u32(108); b.u32(40)                 // offBmiSrc, cbBmiSrc
            b.u32(148); b.u32(16)                 // offBitsSrc, cbBitsSrc
            b.i32(2); b.i32(2)                    // cxSrc, cySrc
            b.raw(dib); b.raw(bits)
            return b.bytes }()
        try assertRoundTrip(LE.record(77, body)) {
            if case .stretchBlt(let p) = $0 { return p.srcSize == SizeL(cx: 2, cy: 2) && p.dib != nil }
            return false
        }
    }
}
