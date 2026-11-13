import Foundation
import Testing
@testable import WMFParse

// P3: one-line WMF record-inspector summaries. Each record is assembled as a raw
// rdParam payload (little-endian, per [MS-WMF] §2.3) and run through
// `WMFRecordSummary.line`, which must read it bounds-checked and never trap.

@Suite struct WMFRecordSummaryTests {

    // MARK: Byte helpers

    private func le16(_ value: Int) -> [UInt8] {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// A ColorRef ([MS-WMF] §2.2.2.8): Red, Green, Blue, Reserved.
    private func colorRef(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [r, g, b, 0] }

    /// Builds the (record, payload) pair with a correct RecordSize for the
    /// payload, so size-derived logic (the sourceless-blt test) sees a real size.
    private func make(_ function: UInt16, _ payload: [UInt8]) -> (WMFRawRecord, Data) {
        let words = UInt32((6 + payload.count + 1) / 2)
        return (WMFRawRecord(function: function, sizeWords: words, offset: 0), Data(payload))
    }

    private func summary(_ function: UInt16, _ payload: [UInt8]) -> String {
        let (record, data) = make(function, payload)
        return WMFRecordSummary.line(for: record, payload: data)
    }

    // MARK: State / mapping

    @Test func windowAndViewport() {
        #expect(summary(0x020B, le16(20) + le16(10)) == "(10,20)")   // SETWINDOWORG: Y,X
        #expect(summary(0x020C, le16(80) + le16(100)) == "100×80")   // SETWINDOWEXT: Y,X
        #expect(summary(0x020D, le16(3) + le16(7)) == "(7,3)")       // SETVIEWPORTORG
        #expect(summary(0x020E, le16(40) + le16(60)) == "60×40")     // SETVIEWPORTEXT
    }

    @Test func modesAndColours() {
        #expect(summary(0x0103, le16(8)) == "MM_ANISOTROPIC")        // SETMAPMODE
        #expect(summary(0x0102, le16(1)) == "TRANSPARENT")           // SETBKMODE
        #expect(summary(0x0106, le16(2)) == "WINDING")               // SETPOLYFILLMODE
        #expect(summary(0x0107, le16(4)) == "HALFTONE")              // SETSTRETCHBLTMODE
        #expect(summary(0x0209, colorRef(0xFF, 0x00, 0x00)) == "#FF0000")  // SETTEXTCOLOR
        #expect(summary(0x0201, colorRef(0x10, 0x20, 0x30)) == "#102030")  // SETBKCOLOR
        #expect(summary(0x0104, le16(13)) == "0x000D")               // SETROP2
    }

    @Test func scaleExtents() {
        // META_SCALEWINDOWEXT: yDenom, yNum, xDenom, xNum.
        #expect(summary(0x0410, le16(2) + le16(3) + le16(4) + le16(5)) == "x ×5/4, y ×3/2")
    }

    // MARK: Objects

    @Test func createObjects() {
        // Pen: PenStyle(2), Width PointS(4, x used), ColorRef(4).
        #expect(summary(0x02FA, le16(0) + le16(3) + le16(0) + colorRef(0xFF, 0, 0)) == "style 0x0000 w=3 #FF0000")
        // Brush: BrushStyle(2), ColorRef(4), BrushHatch(2).
        #expect(summary(0x02FC, le16(0) + colorRef(0, 0x80, 0) + le16(0)) == "style 0x0000 #008000")
        // Font: Height(2) then 16 more fixed bytes, then NUL-terminated facename @18.
        var font = le16(-12)
        font += [UInt8](repeating: 0, count: 16)
        font += Array("Arial".utf8) + [0]
        #expect(summary(0x02FB, font) == "\"Arial\" h=-12")
    }

    @Test func selectAndDelete() {
        #expect(summary(0x012D, le16(3)) == "#3")                    // SELECTOBJECT
        #expect(summary(0x01F0, le16(1)) == "#1")                    // DELETEOBJECT
        #expect(summary(0x012D, le16(0x8003)) == "stock 0x0003")     // stock handle
    }

    // MARK: Geometry

    @Test func lines() {
        #expect(summary(0x0214, le16(5) + le16(9)) == "(9,5)")       // MOVETO: Y,X
        #expect(summary(0x0213, le16(5) + le16(9)) == "→ (9,5)")     // LINETO
    }

    @Test func rectanglesAndEllipse() {
        // RECTANGLE: Bottom, Right, Top, Left.
        #expect(summary(0x041B, le16(80) + le16(100) + le16(10) + le16(5)) == "(5,10)–(100,80)")
        #expect(summary(0x0418, le16(80) + le16(100) + le16(10) + le16(5)) == "(5,10)–(100,80)")  // ELLIPSE
        // ROUNDRECT: Height, Width, Bottom, Right, Top, Left.
        #expect(summary(0x061C, le16(8) + le16(6) + le16(80) + le16(100) + le16(10) + le16(5))
                == "(5,10)–(100,80) corner 6×8")
    }

    @Test func arcFamily() {
        // ARC: yEnd, xEnd, yStart, xStart, Bottom, Right, Top, Left.
        let p = le16(40) + le16(50) + le16(20) + le16(30) + le16(80) + le16(100) + le16(10) + le16(5)
        #expect(summary(0x0817, p) == "(5,10)–(100,80) (30,20)→(50,40)")  // ARC
        #expect(summary(0x081A, p) == "(5,10)–(100,80) (30,20)→(50,40)")  // PIE
        #expect(summary(0x0830, p) == "(5,10)–(100,80) (30,20)→(50,40)")  // CHORD
    }

    @Test func polygons() {
        #expect(summary(0x0324, le16(4)) == "4 points")              // POLYGON
        #expect(summary(0x0325, le16(1)) == "1 point")               // POLYLINE (singular)
        // POLYPOLYGON: NumberOfPolygons, per-polygon counts.
        #expect(summary(0x0538, le16(2) + le16(3) + le16(4)) == "2 polys, 7 points")
    }

    @Test func pixelAndPatBlt() {
        // SETPIXEL: ColorRef(4), Y, X.
        #expect(summary(0x041F, colorRef(0, 0, 0xFF) + le16(6) + le16(5)) == "(5,6) #0000FF")
        // PATBLT: RasterOperation(4), Height, Width, YLeft, XLeft.
        #expect(summary(0x061D, le32(0x00F00021) + le16(20) + le16(30) + le16(2) + le16(1))
                == "(1,2)–(31,22) 0x00F00021")
    }

    // MARK: Text

    @Test func textRecords() {
        // TEXTOUT: StringLength, padded String, YStart, XStart.
        let hello = Array("Hello".utf8) + [0]   // length 5, padded to 6
        #expect(summary(0x0521, le16(5) + hello + le16(20) + le16(10)) == "\"Hello\" @ (10,20)")
        // EXTTEXTOUT with no options: Y, X, StringLength, fwOpts, String.
        let hi = Array("Hi".utf8)
        #expect(summary(0x0A32, le16(7) + le16(3) + le16(2) + le16(0) + hi) == "\"Hi\" @ (3,7)")
    }

    @Test func extTextOutWithOpaqueRectangle() {
        // ETO_OPAQUE (0x0002) inserts an 8-byte Rectangle before the string.
        let rect = le16(0) + le16(0) + le16(10) + le16(10)
        let txt = Array("Ok".utf8)
        #expect(summary(0x0A32, le16(5) + le16(6) + le16(2) + le16(0x0002) + rect + txt) == "\"Ok\" @ (6,5)")
    }

    // MARK: Bitmaps

    @Test func stretchDIBAndBlt() {
        // STRETCHDIB: rop(4), colorUsage(2), srcH, srcW, ySrc, xSrc, destH, destW, yDst, xDst.
        let sdib = le32(0x00CC0020) + le16(0) + le16(16) + le16(16) + le16(0) + le16(0)
            + le16(32) + le16(32) + le16(6) + le16(5)
        #expect(summary(0x0F43, sdib) == "16×16 → (5,6) 32×32")

        // DIBSTRETCHBLT with a source bitmap (RecordSize != (function>>8)+3):
        // rop(4), srcH, srcW, ySrc, xSrc, destH, destW, yDst, xDst, DIB tail.
        let blt = le32(0x00CC0020) + le16(10) + le16(10) + le16(0) + le16(0)
            + le16(20) + le16(20) + le16(2) + le16(1) + [UInt8](repeating: 0, count: 8)
        #expect(summary(0x0B41, blt) == "10×10 → (1,2) 20×20")
    }

    // MARK: Robustness

    @Test func truncatedRecordYieldsEmptyNotCrash() {
        // A RECTANGLE needs 8 payload bytes; 2 is short — every read overruns and
        // returns "", never traps (§8).
        #expect(summary(0x041B, le16(5)) == "")
        // A truncated SETWINDOWORG (1 byte) also yields "".
        #expect(summary(0x020B, [0x01]) == "")
        // A zero-length payload for a text record is safe.
        #expect(summary(0x0A32, []) == "")
    }

    @Test func unrecognisedFunctionIsEmpty() {
        #expect(summary(0x00F7, le16(1)) == "")   // CREATEPALETTE: not summarised
        #expect(summary(0x1234, le16(1)) == "")   // undefined function
    }
}
