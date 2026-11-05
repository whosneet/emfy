import Foundation
import Testing
import EMFParse
import EMFWrite

/// Per-record round-trip: a canonical EMF record decodes to its payload and
/// re-encodes byte-identically. Covers every EMF-decoder-produced payload case
/// except the bitmaps (BitmapRoundTripTests) and the WMF-sourced primitives,
/// which the EMF decoder never produces (WMFSourcedEncodeTests).
@Suite("Per-record round-trip (decode → encode is byte-identical)")
struct RecordRoundTripTests {

    // Shared fixture fragments.
    static func rect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] {
        var w = LE(); w.i32(l); w.i32(t); w.i32(r); w.i32(b); return w.bytes
    }
    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ x: UInt8 = 0) -> [UInt8] {
        [r, g, b, x]
    }

    // MARK: State

    @Test func setWindowExtEx() throws {
        try assertRoundTrip(LE.record(9, { var b = LE(); b.i32(640); b.i32(480); return b.bytes }())) {
            if case .setWindowExtEx(let s) = $0 { return s == SizeL(cx: 640, cy: 480) }; return false
        }
    }
    @Test func setWindowOrgEx() throws {
        try assertRoundTrip(LE.record(10, { var b = LE(); b.i32(-3); b.i32(7); return b.bytes }())) {
            if case .setWindowOrgEx(let p) = $0 { return p == PointL(x: -3, y: 7) }; return false
        }
    }
    @Test func setViewportExtEx() throws {
        try assertRoundTrip(LE.record(11, { var b = LE(); b.i32(1); b.i32(2); return b.bytes }())) {
            if case .setViewportExtEx = $0 { return true }; return false
        }
    }
    @Test func setViewportOrgEx() throws {
        try assertRoundTrip(LE.record(12, { var b = LE(); b.i32(0); b.i32(0); return b.bytes }())) {
            if case .setViewportOrgEx = $0 { return true }; return false
        }
    }
    @Test func setMapMode() throws {
        try assertRoundTrip(LE.record(17, { var b = LE(); b.u32(8); return b.bytes }())) {   // MM_ANISOTROPIC
            if case .setMapMode(.anisotropic) = $0 { return true }; return false
        }
    }
    @Test func setMapModeUnknownRaw() throws {
        try assertRoundTrip(LE.record(17, { var b = LE(); b.u32(99); return b.bytes }())) {
            if case .setMapMode(.unknown(99)) = $0 { return true }; return false
        }
    }
    @Test func setBkMode() throws {
        try assertRoundTrip(LE.record(18, { var b = LE(); b.u32(1); return b.bytes }())) {
            if case .setBkMode(.transparent) = $0 { return true }; return false
        }
    }
    @Test func setPolyFillMode() throws {
        try assertRoundTrip(LE.record(19, { var b = LE(); b.u32(2); return b.bytes }())) {
            if case .setPolyFillMode(.winding) = $0 { return true }; return false
        }
    }
    @Test func setROP2() throws {
        try assertRoundTrip(LE.record(20, { var b = LE(); b.u32(0x0D); return b.bytes }())) {
            if case .setROP2(0x0D) = $0 { return true }; return false
        }
    }
    @Test func saveDC() throws {
        try assertRoundTrip(LE.record(33, [])) { if case .saveDC = $0 { return true }; return false }
    }
    @Test func restoreDC() throws {
        try assertRoundTrip(LE.record(34, { var b = LE(); b.i32(-1); return b.bytes }())) {
            if case .restoreDC(-1) = $0 { return true }; return false
        }
    }
    @Test func setWorldTransform() throws {
        let body: [UInt8] = { var b = LE()
            b.f32(2.0); b.f32(0.0); b.f32(0.0); b.f32(0.5); b.f32(10.0); b.f32(-5.0); return b.bytes }()
        try assertRoundTrip(LE.record(35, body)) {
            if case .setWorldTransform(let x) = $0 {
                return x == XForm(m11: 2, m12: 0, m21: 0, m22: 0.5, dx: 10, dy: -5)
            }; return false
        }
    }
    @Test func modifyWorldTransform() throws {
        let body: [UInt8] = { var b = LE()
            b.f32(1); b.f32(0); b.f32(0); b.f32(1); b.f32(3); b.f32(4); b.u32(2); return b.bytes }()
        try assertRoundTrip(LE.record(36, body)) {
            if case .modifyWorldTransform(let p) = $0 { return p.mode == .leftMultiply }; return false
        }
    }
    @Test func setMiterLimit() throws {
        try assertRoundTrip(LE.record(58, { var b = LE(); b.u32(10); return b.bytes }())) {
            if case .setMiterLimit(10) = $0 { return true }; return false
        }
    }
    @Test func intersectClipRect() throws {
        try assertRoundTrip(LE.record(30, Self.rect(1, 2, 3, 4))) {
            if case .intersectClipRect = $0 { return true }; return false
        }
    }

    // MARK: Objects

    @Test func createPen() throws {
        let body: [UInt8] = { var b = LE()
            b.u32(1); b.u32(0); b.i32(2); b.i32(0); b.raw(Self.color(0, 0, 255)); return b.bytes }()
        try assertRoundTrip(LE.record(38, body)) {
            if case .createPen(let p) = $0 { return p.ihPen == 1 && p.width == PointL(x: 2, y: 0) }
            return false
        }
    }
    @Test func createBrushIndirect() throws {
        let body: [UInt8] = { var b = LE()
            b.u32(1); b.u32(0); b.raw(Self.color(0, 128, 0)); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(39, body)) {
            if case .createBrushIndirect(let p) = $0 { return p.ihBrush == 1 }; return false
        }
    }
    @Test func extCreatePenNoStyles() throws {
        let body: [UInt8] = { var b = LE()
            b.u32(2)                         // ihPen
            b.u32(0); b.u32(0); b.u32(0); b.u32(0)   // DIB fields (none)
            b.u32(0x10000)                   // style
            b.u32(3)                         // width
            b.u32(0)                         // brushStyle
            b.raw(Self.color(255, 0, 0))     // color
            b.u32(0)                         // brushHatch
            b.u32(0)                         // numStyleEntries
            return b.bytes }()
        try assertRoundTrip(LE.record(95, body)) {
            if case .extCreatePen(let p) = $0 { return p.ihPen == 2 && p.styleEntries.isEmpty }
            return false
        }
    }
    @Test func extCreatePenWithStyles() throws {
        let body: [UInt8] = { var b = LE()
            b.u32(3)
            b.u32(0); b.u32(0); b.u32(0); b.u32(0)
            b.u32(7); b.u32(1); b.u32(0)
            b.raw(Self.color(10, 20, 30))
            b.u32(0)
            b.u32(2)                         // numStyleEntries
            b.u32(4); b.u32(2)               // the two entries
            return b.bytes }()
        try assertRoundTrip(LE.record(95, body)) {
            if case .extCreatePen(let p) = $0 { return p.styleEntries == [4, 2] }; return false
        }
    }
    @Test func selectObjectTable() throws {
        try assertRoundTrip(LE.record(37, { var b = LE(); b.u32(1); return b.bytes }())) {
            if case .selectObject(.table(1)) = $0 { return true }; return false
        }
    }
    @Test func selectObjectStock() throws {
        try assertRoundTrip(LE.record(37, { var b = LE(); b.u32(0x8000_0005); return b.bytes }())) {
            if case .selectObject(.stock(.nullBrush)) = $0 { return true }; return false
        }
    }
    @Test func deleteObject() throws {
        try assertRoundTrip(LE.record(40, { var b = LE(); b.u32(2); return b.bytes }())) {
            if case .deleteObject(.table(2)) = $0 { return true }; return false
        }
    }

    // MARK: Paths and clipping

    @Test func beginPath() throws {
        try assertRoundTrip(LE.record(59, [])) { if case .beginPath = $0 { return true }; return false }
    }
    @Test func endPath() throws {
        try assertRoundTrip(LE.record(60, [])) { if case .endPath = $0 { return true }; return false }
    }
    @Test func closeFigure() throws {
        try assertRoundTrip(LE.record(61, [])) { if case .closeFigure = $0 { return true }; return false }
    }
    @Test func fillPath() throws {
        try assertRoundTrip(LE.record(62, Self.rect(0, 0, 10, 10))) {
            if case .fillPath = $0 { return true }; return false
        }
    }
    @Test func strokeAndFillPath() throws {
        try assertRoundTrip(LE.record(63, Self.rect(0, 0, 10, 10))) {
            if case .strokeAndFillPath = $0 { return true }; return false
        }
    }
    @Test func strokePath() throws {
        try assertRoundTrip(LE.record(64, Self.rect(0, 0, 10, 10))) {
            if case .strokePath = $0 { return true }; return false
        }
    }
    @Test func selectClipPath() throws {
        try assertRoundTrip(LE.record(67, { var b = LE(); b.u32(1); return b.bytes }())) {
            if case .selectClipPath(.and) = $0 { return true }; return false
        }
    }
    @Test func extSelectClipRgnReset() throws {
        // RGN_COPY with no region data: the reset form.
        let body: [UInt8] = { var b = LE(); b.u32(0); b.u32(5); return b.bytes }()
        try assertRoundTrip(LE.record(75, body)) {
            if case .extSelectClipRgn(let p) = $0 { return p.bounds == nil && p.rects.isEmpty }
            return false
        }
    }
    @Test func extSelectClipRgnRects() throws {
        let body: [UInt8] = { var b = LE()
            b.u32(64)                        // RgnDataSize = 32 + 2*16
            b.u32(1)                         // RegionMode = RGN_AND
            b.u32(0x20); b.u32(0x01)         // Size, Type
            b.u32(2)                         // CountRects
            b.u32(32)                        // RgnSize = 2*16
            b.raw(Self.rect(0, 0, 50, 50))   // Bounds
            b.raw(Self.rect(0, 0, 25, 25))
            b.raw(Self.rect(25, 25, 50, 50))
            return b.bytes }()
        try assertRoundTrip(LE.record(75, body)) {
            if case .extSelectClipRgn(let p) = $0 { return p.rects.count == 2 && p.mode == .and }
            return false
        }
    }

    // MARK: 32-bit geometry (0 / 1 / many points)

    @Test func polylineEmpty() throws {
        let body = Self.rect(0, 0, 100, 100) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(4, body)) {
            if case .polyline(let p) = $0 { return p.points.isEmpty }; return false
        }
    }
    @Test func polylineOne() throws {
        let body = Self.rect(0, 0, 100, 100) + { var b = LE(); b.u32(1); b.i32(10); b.i32(10); return b.bytes }()
        try assertRoundTrip(LE.record(4, body)) {
            if case .polyline(let p) = $0 { return p.points == [PointL(x: 10, y: 10)] }; return false
        }
    }
    @Test func polygonMany() throws {
        let body = Self.rect(0, 0, 100, 100) + { var b = LE()
            b.u32(3); b.i32(0); b.i32(0); b.i32(50); b.i32(0); b.i32(25); b.i32(50); return b.bytes }()
        try assertRoundTrip(LE.record(3, body)) {
            if case .polygon(let p) = $0 { return p.points.count == 3 }; return false
        }
    }
    @Test func polyBezier() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(2, body)) {
            if case .polyBezier = $0 { return true }; return false
        }
    }
    @Test func polyBezierTo() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(5, body)) {
            if case .polyBezierTo = $0 { return true }; return false
        }
    }
    @Test func polylineTo() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(6, body)) {
            if case .polylineTo = $0 { return true }; return false
        }
    }
    @Test func moveToEx() throws {
        try assertRoundTrip(LE.record(27, { var b = LE(); b.i32(5); b.i32(6); return b.bytes }())) {
            if case .moveToEx(PointL(x: 5, y: 6)) = $0 { return true }; return false
        }
    }
    @Test func lineTo() throws {
        try assertRoundTrip(LE.record(54, { var b = LE(); b.i32(5); b.i32(6); return b.bytes }())) {
            if case .lineTo = $0 { return true }; return false
        }
    }
    @Test func ellipse() throws {
        try assertRoundTrip(LE.record(42, Self.rect(0, 0, 20, 10))) {
            if case .ellipse = $0 { return true }; return false
        }
    }
    @Test func rectangle() throws {
        try assertRoundTrip(LE.record(43, Self.rect(0, 0, 20, 10))) {
            if case .rectangle = $0 { return true }; return false
        }
    }
    @Test func roundRect() throws {
        let body = Self.rect(0, 0, 20, 10) + { var b = LE(); b.i32(4); b.i32(4); return b.bytes }()
        try assertRoundTrip(LE.record(44, body)) {
            if case .roundRect(let p) = $0 { return p.corner == SizeL(cx: 4, cy: 4) }; return false
        }
    }
    @Test func arc() throws {
        let body = Self.rect(0, 0, 20, 20) + { var b = LE()
            b.i32(20); b.i32(10); b.i32(0); b.i32(10); return b.bytes }()
        try assertRoundTrip(LE.record(45, body)) {
            if case .arc = $0 { return true }; return false
        }
    }

    // MARK: 16-bit geometry

    @Test func polyline16Empty() throws {
        let body = Self.rect(0, 0, 100, 100) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(87, body)) {
            if case .polyline16(let p) = $0 { return p.points.isEmpty }; return false
        }
    }
    @Test func polygon16Many() throws {
        let body = Self.rect(0, 0, 100, 100) + { var b = LE()
            b.u32(3); b.i16(0); b.i16(0); b.i16(50); b.i16(0); b.i16(25); b.i16(50); return b.bytes }()
        try assertRoundTrip(LE.record(86, body)) {
            if case .polygon16(let p) = $0 { return p.points.count == 3 }; return false
        }
    }
    @Test func polyBezier16() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(1); b.i16(1); b.i16(2); return b.bytes }()
        try assertRoundTrip(LE.record(85, body)) {
            if case .polyBezier16 = $0 { return true }; return false
        }
    }
    @Test func polyBezierTo16() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(88, body)) {
            if case .polyBezierTo16 = $0 { return true }; return false
        }
    }
    @Test func polylineTo16() throws {
        let body = Self.rect(0, 0, 9, 9) + { var b = LE(); b.u32(0); return b.bytes }()
        try assertRoundTrip(LE.record(89, body)) {
            if case .polylineTo16 = $0 { return true }; return false
        }
    }
    @Test func polyPolyline16() throws {
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 100, 100))
            b.u32(2)                         // NumberOfPolys
            b.u32(5)                         // total points
            b.u32(2); b.u32(3)               // per-poly counts
            b.i16(0); b.i16(0); b.i16(1); b.i16(1)                 // poly 0 (2 pts)
            b.i16(2); b.i16(2); b.i16(3); b.i16(3); b.i16(4); b.i16(4)  // poly 1 (3 pts)
            return b.bytes }()
        try assertRoundTrip(LE.record(90, body)) {
            if case .polyPolyline16(let p) = $0 { return p.pointCounts == [2, 3] && p.points.count == 5 }
            return false
        }
    }
    @Test func polyPolygon16() throws {
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 100, 100))
            b.u32(1); b.u32(3)
            b.u32(3)
            b.i16(0); b.i16(0); b.i16(5); b.i16(0); b.i16(2); b.i16(5)
            return b.bytes }()
        try assertRoundTrip(LE.record(91, body)) {
            if case .polyPolygon16(let p) = $0 { return p.points.count == 3 }; return false
        }
    }

    // MARK: Text

    @Test func setTextAlign() throws {
        try assertRoundTrip(LE.record(22, { var b = LE(); b.u32(0x18); return b.bytes }())) {
            if case .setTextAlign(let a) = $0 { return a.rawValue == 0x18 }; return false
        }
    }
    @Test func setTextColor() throws {
        try assertRoundTrip(LE.record(24, Self.color(1, 2, 3))) {
            if case .setTextColor = $0 { return true }; return false
        }
    }
    @Test func setBkColor() throws {
        try assertRoundTrip(LE.record(25, Self.color(9, 8, 7))) {
            if case .setBkColor = $0 { return true }; return false
        }
    }
    @Test func extCreateFontIndirectW() throws {
        let logFont: [UInt8] = { var b = LE()
            b.i32(-24); b.i32(0); b.i32(0); b.i32(0); b.i32(400)   // height..weight
            b.u8(0); b.u8(0); b.u8(0); b.u8(0)                     // italic, underline, strikeOut, charSet
            b.u8(0); b.u8(0); b.u8(0); b.u8(0)                     // outPrec, clipPrec, quality, pitch
            b.utf16("Arial"); b.zeros(64 - 10)                     // FaceName: 32 units
            return b.bytes }()
        let body: [UInt8] = { var b = LE(); b.u32(1); b.raw(logFont); return b.bytes }()
        try assertRoundTrip(LE.record(82, body)) {
            if case .extCreateFontIndirectW(let p) = $0 {
                return p.logFont.faceName == "Arial" && !p.hasExtendedData
            }; return false
        }
    }
    @Test func extTextOutWNoDx() throws {
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 0, 0))     // Bounds (ignored, written zero)
            b.u32(1)                         // iGraphicsMode
            b.f32(1.0); b.f32(1.0)           // exScale, eyScale
            b.i32(10); b.i32(20)             // Reference
            b.u32(2)                         // Chars
            b.u32(76)                        // offString
            b.u32(0)                         // Options
            b.raw(Self.rect(0, 0, 100, 50))  // Rectangle
            b.u32(0)                         // offDx
            b.utf16("Hi")                    // string at offset 76
            return b.bytes }()
        try assertRoundTrip(LE.record(84, body)) {
            if case .extTextOutW(let p) = $0 { return p.string == "Hi" && p.dx == nil }; return false
        }
    }
    @Test func extTextOutWWithDxAligned() throws {
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 0, 0))
            b.u32(1); b.f32(1.0); b.f32(1.0)
            b.i32(0); b.i32(0)
            b.u32(2)                         // Chars = 2
            b.u32(76)                        // offString
            b.u32(0)                         // Options (no PDY)
            b.raw(Self.rect(0, 0, 10, 10))
            b.u32(80)                        // offDx (76 + 4 string, already 4-aligned)
            b.utf16("Hi")                    // 4 bytes
            b.u32(5); b.u32(7)               // Dx, 2 entries
            return b.bytes }()
        try assertRoundTrip(LE.record(84, body)) {
            if case .extTextOutW(let p) = $0 { return p.dx == [5, 7] }; return false
        }
    }
    @Test func extTextOutWWithDxPadded() throws {
        // Odd string byte length forces 2 pad bytes before the 4-aligned Dx.
        let body: [UInt8] = { var b = LE()
            b.raw(Self.rect(0, 0, 0, 0))
            b.u32(1); b.f32(1.0); b.f32(1.0)
            b.i32(0); b.i32(0)
            b.u32(1)                         // Chars = 1
            b.u32(76)                        // offString
            b.u32(0)                         // Options
            b.raw(Self.rect(0, 0, 10, 10))
            b.u32(80)                        // offDx = 76 + 2 (string) + 2 (pad)
            b.utf16("X")                     // 2 bytes
            b.zeros(2)                        // alignment pad
            b.u32(9)                         // Dx, 1 entry
            return b.bytes }()
        try assertRoundTrip(LE.record(84, body)) {
            if case .extTextOutW(let p) = $0 { return p.string == "X" && p.dx == [9] }; return false
        }
    }
}
