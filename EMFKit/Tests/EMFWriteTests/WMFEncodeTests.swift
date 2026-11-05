import Foundation
import Testing
import EMFParse
import EMFWrite

/// Byte-shape tests for `WMFRecordEncoder`: each record is encoded and compared
/// against its hand-computed [MS-WMF] §2.3 layout, with the reversed field orders
/// made explicit in the expected body. Plus the typed-error paths for the 16-bit
/// overflows a WMF makes easy to hit.
@Suite("WMF record encoder (byte shape)")
struct WMFEncodeTests {

    /// Frames a hand-written body as a WMF record: RecordSize (WORDs, header
    /// included) + RecordFunction + the (WORD-aligned) body.
    static func framed(_ function: UInt16, _ body: [UInt8]) -> [UInt8] {
        var padded = body
        if padded.count % 2 != 0 { padded.append(0) }
        var b = LE()
        b.u32(UInt32((6 + padded.count) / 2))
        b.u16(function)
        b.raw(padded)
        return b.bytes
    }

    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ColorRef {
        ColorRef(red: r, green: g, blue: b)
    }

    func expect(_ record: WMFRecord, _ function: UInt16, body: [UInt8],
                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let encoded = try WMFRecordEncoder.encode(record)
        #expect(encoded == Self.framed(function, body),
                "unexpected bytes for \(record): \(encoded.map { String(format: "%02X", $0) })",
                sourceLocation: sourceLocation)
    }

    // MARK: - State

    @Test func saveRestore() throws {
        try expect(.saveDC, 0x001E, body: [])
        try expect(.restoreDC(savedDC: -1), 0x0127, body: [0xFF, 0xFF])
    }

    @Test func modes() throws {
        try expect(.setBkMode(1), 0x0102, body: [0x01, 0x00])
        try expect(.setMapMode(8), 0x0103, body: [0x08, 0x00])
        try expect(.setROP2(13), 0x0104, body: [0x0D, 0x00])
        try expect(.setPolyFillMode(2), 0x0106, body: [0x02, 0x00])
        try expect(.setTextAlign(0x0018), 0x012E, body: [0x18, 0x00])
    }

    @Test func colors() throws {
        try expect(.setBkColor(Self.color(1, 2, 3)), 0x0201, body: [0x01, 0x02, 0x03, 0x00])
        try expect(.setTextColor(Self.color(255, 0, 0)), 0x0209, body: [0xFF, 0x00, 0x00, 0x00])
    }

    @Test func window() throws {
        // §2.3.5.31 SETWINDOWORG: Y then X (reversed).
        try expect(.setWindowOrg(PointL(x: 10, y: 20)), 0x020B, body: [0x14, 0x00, 0x0A, 0x00])
        // §2.3.5.30 SETWINDOWEXT: height (cy) then width (cx) (reversed).
        try expect(.setWindowExt(SizeL(cx: 100, cy: 200)), 0x020C, body: [0xC8, 0x00, 0x64, 0x00])
    }

    // MARK: - Objects

    @Test func createPen() throws {
        // §2.2.1.4 Pen: PenStyle(2), Width PointS(x, y=0), ColorRef.
        try expect(.createPenIndirect(style: 0, width: 3, color: Self.color(255, 0, 0)), 0x02FA,
                   body: [0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00])
    }

    @Test func createBrush() throws {
        // §2.2.2.10 LogBrush: BrushStyle(2), ColorRef(4), BrushHatch(2).
        try expect(.createBrushIndirect(style: 0, color: Self.color(0, 0, 255), hatch: 0), 0x02FC,
                   body: [0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00])
    }

    @Test func createFont() throws {
        let font = LogFont(
            height: -24, width: 0, escapement: 0, orientation: 0, weight: 400,
            italic: 0, underline: 0, strikeOut: 0, charSet: 0, outPrecision: 0,
            clipPrecision: 0, quality: 0, pitchAndFamily: 0, faceName: "Arial")
        var body: [UInt8] = []
        body += [0xE8, 0xFF]   // height -24
        body += [0x00, 0x00]   // width
        body += [0x00, 0x00]   // escapement
        body += [0x00, 0x00]   // orientation
        body += [0x90, 0x01]   // weight 400
        body += [0, 0, 0, 0, 0, 0, 0, 0]   // 8 u8 flags
        var face: [UInt8] = Array("Arial".utf8)   // 5 bytes
        face += [UInt8](repeating: 0, count: 32 - face.count)   // NUL + pad to 32
        body += face
        try expect(.createFontIndirect(font), 0x02FB, body: body)
    }

    @Test func selectDelete() throws {
        try expect(.selectObject(index: 0), 0x012D, body: [0x00, 0x00])
        try expect(.deleteObject(index: 1), 0x01F0, body: [0x01, 0x00])
    }

    // MARK: - Geometry

    @Test func moveLineTo() throws {
        // §2.3.3.4/.10: Y then X (reversed).
        try expect(.moveTo(PointL(x: 5, y: 7)), 0x0214, body: [0x07, 0x00, 0x05, 0x00])
        try expect(.lineTo(PointL(x: 50, y: 60)), 0x0213, body: [0x3C, 0x00, 0x32, 0x00])
    }

    @Test func polylines() throws {
        let pts = [PointL(x: 1, y: 2), PointL(x: 3, y: 4)]
        let body: [UInt8] = [0x02, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00]
        try expect(.polyline(pts), 0x0325, body: body)
        try expect(.polygon(pts), 0x0324, body: body)
    }

    @Test func polyPolygon() throws {
        let polys = [[PointL(x: 0, y: 0), PointL(x: 1, y: 0), PointL(x: 0, y: 1)],
                     [PointL(x: 5, y: 5), PointL(x: 6, y: 5), PointL(x: 5, y: 6)]]
        var body: [UInt8] = [0x02, 0x00,              // NumberOfPolygons
                             0x03, 0x00, 0x03, 0x00]  // per-polygon counts
        body += [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]   // polygon 1
        body += [0x05, 0x00, 0x05, 0x00, 0x06, 0x00, 0x05, 0x00, 0x05, 0x00, 0x06, 0x00]   // polygon 2
        try expect(.polyPolygon(polys), 0x0538, body: body)
    }

    @Test func rectEllipse() throws {
        // §2.3.3.17/.3: Bottom, Right, Top, Left (reversed).
        let box = RectL(left: 10, top: 20, right: 110, bottom: 220)
        let body: [UInt8] = [0xDC, 0x00, 0x6E, 0x00, 0x14, 0x00, 0x0A, 0x00]
        try expect(.rectangle(box), 0x041B, body: body)
        try expect(.ellipse(box), 0x0418, body: body)
    }

    @Test func roundRect() throws {
        // §2.3.3.18: Height, Width, Bottom, Right, Top, Left.
        let box = RectL(left: 0, top: 0, right: 40, bottom: 30)
        let body: [UInt8] = [0x06, 0x00, 0x08, 0x00, 0x1E, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00]
        try expect(.roundRect(box: box, corner: SizeL(cx: 8, cy: 6)), 0x061C, body: body)
    }

    @Test func arcPieChord() throws {
        // §2.3.3.1/.13/.2: end Y/X, start Y/X, then Bottom, Right, Top, Left.
        let box = RectL(left: 0, top: 0, right: 40, bottom: 30)
        let start = PointL(x: 10, y: 0), end = PointL(x: 0, y: 10)
        let body: [UInt8] = [0x0A, 0x00, 0x00, 0x00,   // end  Y, X
                             0x00, 0x00, 0x0A, 0x00,   // start Y, X
                             0x1E, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00]   // box B,R,T,L
        try expect(.arc(box: box, start: start, end: end), 0x0817, body: body)
        try expect(.pie(box: box, start: start, end: end), 0x081A, body: body)
        try expect(.chord(box: box, start: start, end: end), 0x0830, body: body)
    }

    @Test func clip() throws {
        // §2.3.5.3/.2: Bottom, Right, Top, Left (reversed).
        let rect = RectL(left: 10, top: 20, right: 110, bottom: 220)
        let body: [UInt8] = [0xDC, 0x00, 0x6E, 0x00, 0x14, 0x00, 0x0A, 0x00]
        try expect(.intersectClipRect(rect), 0x0416, body: body)
        try expect(.excludeClipRect(rect), 0x0415, body: body)
    }

    // MARK: - Text

    @Test func textOutEven() throws {
        // §2.3.3.20: StringLength, String (padded), YStart, XStart.
        try expect(.textOut(point: PointL(x: 5, y: 9), string: "Hi"), 0x0521,
                   body: [0x02, 0x00, 0x48, 0x69, 0x09, 0x00, 0x05, 0x00])
    }

    @Test func textOutOddPads() throws {
        // Odd-length "A" pads the String to even BEFORE YStart/XStart.
        try expect(.textOut(point: PointL(x: 1, y: 2), string: "A"), 0x0521,
                   body: [0x01, 0x00, 0x41, 0x00, 0x02, 0x00, 0x01, 0x00])
    }

    @Test func extTextOutPlain() throws {
        // §2.3.3.5: Y, X, StringLength, fwOpts, String — no rect (fwOpts 0).
        try expect(.extTextOut(point: PointL(x: 3, y: 4), rectangle: nil, options: 0, string: "Hi", dx: nil),
                   0x0A32, body: [0x04, 0x00, 0x03, 0x00, 0x02, 0x00, 0x00, 0x00, 0x48, 0x69])
    }

    @Test func extTextOutWithRectAndDx() throws {
        // ETO_OPAQUE sets the Rectangle (Left, Top, Right, Bottom — NOT reversed);
        // the Dx advances follow the padded String.
        let body: [UInt8] = [0x04, 0x00, 0x03, 0x00,       // Y, X
                             0x02, 0x00, 0x02, 0x00,       // StringLength, fwOpts (ETO_OPAQUE)
                             0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,   // Rect L,T,R,B
                             0x48, 0x69,                   // "Hi"
                             0x07, 0x00, 0x08, 0x00]       // Dx
        try expect(.extTextOut(point: PointL(x: 3, y: 4),
                               rectangle: RectL(left: 1, top: 2, right: 3, bottom: 4),
                               options: 0x0002, string: "Hi", dx: [7, 8]),
                   0x0A32, body: body)
    }

    // MARK: - Escape

    @Test func escapeEven() throws {
        try expect(.escape(escapeFunction: 0x000F, data: [0xAA, 0xBB, 0xCC, 0xDD]), 0x0626,
                   body: [0x0F, 0x00, 0x04, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])
    }

    @Test func escapeOddPads() throws {
        // ByteCount is the TRUE blob length (1); the record is WORD-padded.
        try expect(.escape(escapeFunction: 0x000F, data: [0xAA]), 0x0626,
                   body: [0x0F, 0x00, 0x01, 0x00, 0xAA])
    }

    @Test func eof() throws {
        try expect(.eof, 0x0000, body: [])
    }

    // MARK: - STRETCHDIB fixed prefix

    @Test func stretchDIBPrefix() throws {
        let dib = Self.solidDIB(width: 4, height: 4, b: 0xFF, g: 0x00, r: 0xFF)
        let encoded = try WMFRecordEncoder.encode(.stretchDIB(
            rop: 0x00CC_0020, colorUsage: 0,
            src: PointL(x: 0, y: 0), srcSize: SizeL(cx: 4, cy: 4),
            dest: PointL(x: 0, y: 0), destSize: SizeL(cx: 96, cy: 96), dib: dib))
        // Record header (6) + the 22-byte fixed param block.
        let prefix = Array(encoded.prefix(28))
        var expected = LE()
        expected.u32(UInt32((encoded.count) / 2))   // RecordSize
        expected.u16(0x0F43)                        // STRETCHDIB
        expected.u32(0x00CC_0020)                   // RasterOperation
        expected.u16(0)                             // ColorUsage
        expected.i16(4); expected.i16(4)            // SrcHeight, SrcWidth
        expected.i16(0); expected.i16(0)            // YSrc, XSrc
        expected.i16(96); expected.i16(96)          // DestHeight, DestWidth
        expected.i16(0); expected.i16(0)            // YDest, XDest
        #expect(prefix == expected.bytes,
                "unexpected STRETCHDIB prefix: \(prefix.map { String(format: "%02X", $0) })")
        // The whole record re-parses and its DIB decodes back to the pixels.
        try Self.assertStretchDIBDecodes(encoded, width: 4, height: 4)
    }

    /// Parses an encoded STRETCHDIB back through WMFParse + WMFTranslator and
    /// confirms its DIB decodes to `.pixels` of the expected size.
    static func assertStretchDIBDecodes(_ record: [UInt8], width: Int, height: Int,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws {
        // The DIB object sits after the 6-byte header + 22-byte fixed block.
        let dibBytes = Data(record[28...])
        guard case .decoded(let dib) = EMFFile.decodePackedDIB(dibBytes) else {
            Issue.record("packed DIB did not decode", sourceLocation: sourceLocation); return
        }
        #expect(dib.width == Int32(width) && dib.height == Int32(height), sourceLocation: sourceLocation)
        if case .pixels = dib.content {} else {
            Issue.record("DIB content not .pixels: \(dib.content)", sourceLocation: sourceLocation)
        }
    }

    /// A bottom-up 24-bit BI_RGB DIB filled with one BGR colour.
    static func solidDIB(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) -> DIB {
        let stride = ((width * 24 + 31) / 32) * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for row in 0 ..< height {
            for x in 0 ..< width {
                let o = row * stride + x * 3
                bytes[o] = b; bytes[o + 1] = g; bytes[o + 2] = r
            }
        }
        return DIB(width: Int32(width), height: Int32(height), bitCount: 24, compression: .rgb,
                   content: .pixels(bytes: Data(bytes), stride: stride, palette: []))
    }

    // MARK: - Typed overflow errors (never a trap)

    @Test func coordinateOverflowThrows() {
        #expect(throws: WMFWriteError.coordinateOutOfRange(value: 40000)) {
            _ = try WMFRecordEncoder.encode(.rectangle(RectL(left: 0, top: 0, right: 40000, bottom: 30)))
        }
    }

    @Test func pointCountOverflowThrows() {
        let pts = [PointL](repeating: PointL(x: 0, y: 0), count: 40000)
        #expect(throws: WMFWriteError.countOutOfRange(field: "NumberOfPoints", count: 40000)) {
            _ = try WMFRecordEncoder.encode(.polygon(pts))
        }
    }

    @Test func polygonCountOverflowThrows() {
        let polys = [[PointL]](repeating: [PointL(x: 0, y: 0)], count: 70000)
        #expect(throws: WMFWriteError.countOutOfRange(field: "NumberOfPolygons", count: 70000)) {
            _ = try WMFRecordEncoder.encode(.polyPolygon(polys))
        }
    }

    @Test func stringTooLongThrows() {
        let long = String(repeating: "A", count: 40000)
        #expect(throws: WMFWriteError.stringTooLong(byteCount: 40000)) {
            _ = try WMFRecordEncoder.encode(.textOut(point: PointL(x: 0, y: 0), string: long))
        }
    }

    @Test func escapeTooLargeThrows() {
        let data = [UInt8](repeating: 0, count: 70000)
        #expect(throws: WMFWriteError.escapeDataTooLarge(byteCount: 70000)) {
            _ = try WMFRecordEncoder.encode(.escape(escapeFunction: 0, data: data))
        }
    }
}
