import Foundation
import EMFParse

/// Serialises one `WMFRecord` to its exact on-disk WMF record bytes: the 6-byte
/// `RecordSize`(u32 WORDs)/`RecordFunction`(u16) header ([MS-WMF] §2.3) then the
/// `rdParam` body. Every field layout is cited against [MS-WMF] §2.3; many WMF
/// records store their parameters in REVERSED order (a point Y-then-X, a
/// rectangle Bottom-Right-Top-Left), verified field by field against the spec and
/// against WMFParse's decoders.
///
/// This encoder is the single place every 16-bit narrowing is range-checked: the
/// shared 32-bit `PointL`/`RectL`/`SizeL` values a `WMFRecord` carries narrow to
/// the record's Int16 fields here, and a value that does not fit throws a typed
/// `WMFWriteError` rather than trapping (primer §8).
public enum WMFRecordEncoder {

    /// RecordFunction values ([MS-WMF] §2.1.1.1), the same values
    /// `WMFParse.WMFRecordType` names.
    public enum Function {
        public static let eof: UInt16 = 0x0000
        public static let saveDC: UInt16 = 0x001E
        public static let setBkMode: UInt16 = 0x0102
        public static let setMapMode: UInt16 = 0x0103
        public static let setROP2: UInt16 = 0x0104
        public static let setPolyFillMode: UInt16 = 0x0106
        public static let restoreDC: UInt16 = 0x0127
        public static let selectObject: UInt16 = 0x012D
        public static let setTextAlign: UInt16 = 0x012E
        public static let deleteObject: UInt16 = 0x01F0
        public static let setBkColor: UInt16 = 0x0201
        public static let setTextColor: UInt16 = 0x0209
        public static let setWindowOrg: UInt16 = 0x020B
        public static let setWindowExt: UInt16 = 0x020C
        public static let setViewportOrg: UInt16 = 0x020D
        public static let setViewportExt: UInt16 = 0x020E
        public static let lineTo: UInt16 = 0x0213
        public static let moveTo: UInt16 = 0x0214
        public static let excludeClipRect: UInt16 = 0x0415
        public static let intersectClipRect: UInt16 = 0x0416
        public static let ellipse: UInt16 = 0x0418
        public static let rectangle: UInt16 = 0x041B
        public static let polygon: UInt16 = 0x0324
        public static let polyline: UInt16 = 0x0325
        public static let polyPolygon: UInt16 = 0x0538
        public static let textOut: UInt16 = 0x0521
        public static let extTextOut: UInt16 = 0x0A32
        public static let stretchDIB: UInt16 = 0x0F43
        public static let roundRect: UInt16 = 0x061C
        public static let arc: UInt16 = 0x0817
        public static let pie: UInt16 = 0x081A
        public static let chord: UInt16 = 0x0830
        public static let escape: UInt16 = 0x0626
        public static let createPenIndirect: UInt16 = 0x02FA
        public static let createFontIndirect: UInt16 = 0x02FB
        public static let createBrushIndirect: UInt16 = 0x02FC
    }

    // MARK: - Entry point

    /// Encodes `record` to its full on-disk record bytes (header + body, padded
    /// so the record is a whole number of 16-bit WORDs).
    public static func encode(_ record: WMFRecord) throws(WMFWriteError) -> [UInt8] {
        switch record {
        // MARK: State
        case .saveDC:
            return try frame(Function.saveDC, [])
        case .restoreDC(let savedDC):
            var b = ByteWriter(); b.appendInt16(savedDC)
            return try frame(Function.restoreDC, b.bytes)
        case .setBkMode(let mode):
            return try u16Record(Function.setBkMode, mode)
        case .setMapMode(let mode):
            return try u16Record(Function.setMapMode, mode)
        case .setBkColor(let color):
            return try colorRecord(Function.setBkColor, color)
        case .setTextColor(let color):
            return try colorRecord(Function.setTextColor, color)
        case .setTextAlign(let mask):
            return try u16Record(Function.setTextAlign, mask)
        case .setPolyFillMode(let mode):
            return try u16Record(Function.setPolyFillMode, mode)
        case .setROP2(let mode):
            return try u16Record(Function.setROP2, mode)
        case .setWindowOrg(let origin):
            // §2.3.5.31: Y then X (reversed).
            var b = ByteWriter()
            b.appendInt16(try i16(origin.y)); b.appendInt16(try i16(origin.x))
            return try frame(Function.setWindowOrg, b.bytes)
        case .setWindowExt(let extent):
            // §2.3.5.30: height (cy) then width (cx) (reversed).
            var b = ByteWriter()
            b.appendInt16(try i16(extent.cy)); b.appendInt16(try i16(extent.cx))
            return try frame(Function.setWindowExt, b.bytes)
        case .setViewportOrg(let origin):
            // §2.3.5.29: Y then X (reversed).
            var b = ByteWriter()
            b.appendInt16(try i16(origin.y)); b.appendInt16(try i16(origin.x))
            return try frame(Function.setViewportOrg, b.bytes)
        case .setViewportExt(let extent):
            // §2.3.5.28: height (cy) then width (cx) (reversed).
            var b = ByteWriter()
            b.appendInt16(try i16(extent.cy)); b.appendInt16(try i16(extent.cx))
            return try frame(Function.setViewportExt, b.bytes)

        // MARK: Objects
        case .createPenIndirect(let style, let width, let color):
            // §2.2.1.4 Pen Object: PenStyle(2), Width PointS(4: x, y), ColorRef(4).
            // Only Width.x is used; Width.y is written 0.
            var b = ByteWriter()
            b.appendUInt16(style)
            b.appendInt16(try i16(width)); b.appendInt16(0)
            b.appendColorRef(color)
            return try frame(Function.createPenIndirect, b.bytes)
        case .createBrushIndirect(let style, let color, let hatch):
            // §2.2.2.10 LogBrush: BrushStyle(2), ColorRef(4), BrushHatch(2).
            var b = ByteWriter()
            b.appendUInt16(style); b.appendColorRef(color); b.appendUInt16(hatch)
            return try frame(Function.createBrushIndirect, b.bytes)
        case .createFontIndirect(let font):
            return try createFontRecord(font)
        case .selectObject(let index):
            return try u16Record(Function.selectObject, index)
        case .deleteObject(let index):
            return try u16Record(Function.deleteObject, index)

        // MARK: Geometry
        case .moveTo(let point):
            return try reversedPointRecord(Function.moveTo, point)
        case .lineTo(let point):
            return try reversedPointRecord(Function.lineTo, point)
        case .polyline(let points):
            return try polyRecord(Function.polyline, points)
        case .polygon(let points):
            return try polyRecord(Function.polygon, points)
        case .polyPolygon(let polygons):
            return try polyPolygonRecord(polygons)
        case .rectangle(let box):
            return try reversedRectRecord(Function.rectangle, box)
        case .roundRect(let box, let corner):
            return try roundRectRecord(box: box, corner: corner)
        case .ellipse(let box):
            return try reversedRectRecord(Function.ellipse, box)
        case .arc(let box, let start, let end):
            return try arcRecord(Function.arc, box: box, start: start, end: end)
        case .pie(let box, let start, let end):
            return try arcRecord(Function.pie, box: box, start: start, end: end)
        case .chord(let box, let start, let end):
            return try arcRecord(Function.chord, box: box, start: start, end: end)

        // MARK: Text
        case .textOut(let point, let string):
            return try textOutRecord(point: point, string: string)
        case .extTextOut(let point, let rect, let options, let string, let dx):
            return try extTextOutRecord(point: point, rectangle: rect, options: options, string: string, dx: dx)

        // MARK: Bitmaps
        case .stretchDIB(let rop, let usage, let src, let srcSize, let dest, let destSize, let dib):
            return try stretchDIBRecord(rop: rop, usage: usage, src: src, srcSize: srcSize, dest: dest, destSize: destSize, dib: dib)

        // MARK: Clipping
        case .intersectClipRect(let rect):
            return try reversedRectRecord(Function.intersectClipRect, rect)
        case .excludeClipRect(let rect):
            return try reversedRectRecord(Function.excludeClipRect, rect)

        // MARK: Escape
        case .escape(let escapeFunction, let data):
            return try escapeRecord(escapeFunction: escapeFunction, data: data)

        // MARK: Control
        case .eof:
            return try frame(Function.eof, [])
        }
    }

    /// The RecordFunction `record` encodes to ([MS-WMF] §2.1.1.1), without
    /// serialising it — used by the builder and re-emit for object-table
    /// bookkeeping.
    public static func recordFunction(of record: WMFRecord) -> UInt16 {
        switch record {
        case .saveDC: return Function.saveDC
        case .restoreDC: return Function.restoreDC
        case .setBkMode: return Function.setBkMode
        case .setMapMode: return Function.setMapMode
        case .setBkColor: return Function.setBkColor
        case .setTextColor: return Function.setTextColor
        case .setTextAlign: return Function.setTextAlign
        case .setPolyFillMode: return Function.setPolyFillMode
        case .setROP2: return Function.setROP2
        case .setWindowOrg: return Function.setWindowOrg
        case .setWindowExt: return Function.setWindowExt
        case .setViewportOrg: return Function.setViewportOrg
        case .setViewportExt: return Function.setViewportExt
        case .createPenIndirect: return Function.createPenIndirect
        case .createBrushIndirect: return Function.createBrushIndirect
        case .createFontIndirect: return Function.createFontIndirect
        case .selectObject: return Function.selectObject
        case .deleteObject: return Function.deleteObject
        case .moveTo: return Function.moveTo
        case .lineTo: return Function.lineTo
        case .polyline: return Function.polyline
        case .polygon: return Function.polygon
        case .polyPolygon: return Function.polyPolygon
        case .rectangle: return Function.rectangle
        case .roundRect: return Function.roundRect
        case .ellipse: return Function.ellipse
        case .arc: return Function.arc
        case .pie: return Function.pie
        case .chord: return Function.chord
        case .textOut: return Function.textOut
        case .extTextOut: return Function.extTextOut
        case .stretchDIB: return Function.stretchDIB
        case .intersectClipRect: return Function.intersectClipRect
        case .excludeClipRect: return Function.excludeClipRect
        case .escape: return Function.escape
        case .eof: return Function.eof
        }
    }

    // MARK: - Record framing and narrowing

    /// Frames a body as a WMF record: `RecordSize`(u32, in WORDs, header
    /// included) then `RecordFunction`(u16) then the body, padded with a zero byte
    /// so the record is a whole number of WORDs ([MS-WMF] §2.3).
    static func frame(_ function: UInt16, _ body: [UInt8]) throws(WMFWriteError) -> [UInt8] {
        var bodyBytes = body
        if bodyBytes.count % 2 != 0 { bodyBytes.append(0) }   // WORD-align
        let totalBytes = 6 + bodyBytes.count
        let words = totalBytes / 2
        guard words <= Int(UInt32.max) else {
            throw .recordTooLarge(function: function, byteCount: totalBytes)
        }
        var w = ByteWriter(capacity: totalBytes)
        w.appendUInt32(UInt32(words))
        w.appendUInt16(function)
        w.appendBytes(bodyBytes)
        return w.bytes
    }

    /// Narrows a 32-bit logical coordinate to the Int16 field a WMF record stores
    /// it in; a value outside Int16 throws rather than truncating (primer §8).
    private static func i16(_ value: Int32) throws(WMFWriteError) -> Int16 {
        guard let narrow = Int16(exactly: value) else {
            throw .coordinateOutOfRange(value: value)
        }
        return narrow
    }

    private static func count16(_ n: Int, field: String) throws(WMFWriteError) -> Int16 {
        guard let v = Int16(exactly: n) else { throw .countOutOfRange(field: field, count: n) }
        return v
    }

    private static func ucount16(_ n: Int, field: String) throws(WMFWriteError) -> UInt16 {
        guard let v = UInt16(exactly: n) else { throw .countOutOfRange(field: field, count: n) }
        return v
    }

    // MARK: - Fixed-shape helpers

    private static func u16Record(_ function: UInt16, _ value: UInt16) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter(); b.appendUInt16(value)
        return try frame(function, b.bytes)
    }

    private static func colorRecord(_ function: UInt16, _ color: ColorRef) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter(); b.appendColorRef(color)
        return try frame(function, b.bytes)
    }

    /// A point stored Y-then-X ([MS-WMF] §2.3.3.4/.10).
    private static func reversedPointRecord(_ function: UInt16, _ point: PointL) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try i16(point.y)); b.appendInt16(try i16(point.x))
        return try frame(function, b.bytes)
    }

    /// A rectangle stored Bottom, Right, Top, Left ([MS-WMF] §2.3.3.17/.3,
    /// §2.3.5.3/.2).
    private static func reversedRectRecord(_ function: UInt16, _ rect: RectL) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try i16(rect.bottom)); b.appendInt16(try i16(rect.right))
        b.appendInt16(try i16(rect.top)); b.appendInt16(try i16(rect.left))
        return try frame(function, b.bytes)
    }

    /// META_ROUNDRECT ([MS-WMF] §2.3.3.18): Height, Width, Bottom, Right, Top,
    /// Left. Height/Width are the rounding ellipse's full extent (corner.cy/cx).
    private static func roundRectRecord(box: RectL, corner: SizeL) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try i16(corner.cy)); b.appendInt16(try i16(corner.cx))
        b.appendInt16(try i16(box.bottom)); b.appendInt16(try i16(box.right))
        b.appendInt16(try i16(box.top)); b.appendInt16(try i16(box.left))
        return try frame(Function.roundRect, b.bytes)
    }

    /// META_ARC/PIE/CHORD ([MS-WMF] §2.3.3.1/.13/.2): end Y/X, start Y/X, then the
    /// box Bottom, Right, Top, Left — all reversed.
    private static func arcRecord(_ function: UInt16, box: RectL, start: PointL, end: PointL) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try i16(end.y)); b.appendInt16(try i16(end.x))
        b.appendInt16(try i16(start.y)); b.appendInt16(try i16(start.x))
        b.appendInt16(try i16(box.bottom)); b.appendInt16(try i16(box.right))
        b.appendInt16(try i16(box.top)); b.appendInt16(try i16(box.left))
        return try frame(function, b.bytes)
    }

    // MARK: - Polylines / polygons

    /// META_POLYLINE/POLYGON ([MS-WMF] §2.3.3.14/.15): NumberOfPoints(Int16) then
    /// that many PointS (x, y — NOT reversed).
    private static func polyRecord(_ function: UInt16, _ points: [PointL]) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try count16(points.count, field: "NumberOfPoints"))
        for point in points {
            b.appendInt16(try i16(point.x)); b.appendInt16(try i16(point.y))
        }
        return try frame(function, b.bytes)
    }

    /// META_POLYPOLYGON ([MS-WMF] §2.3.3.16 / §2.2.2.17): NumberOfPolygons(UInt16),
    /// a per-polygon point count (UInt16 each), then every polygon's PointS in
    /// order.
    private static func polyPolygonRecord(_ polygons: [[PointL]]) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendUInt16(try ucount16(polygons.count, field: "NumberOfPolygons"))
        for polygon in polygons {
            b.appendUInt16(try ucount16(polygon.count, field: "aPointsPerPolygon"))
        }
        for polygon in polygons {
            for point in polygon {
                b.appendInt16(try i16(point.x)); b.appendInt16(try i16(point.y))
            }
        }
        return try frame(Function.polyPolygon, b.bytes)
    }

    // MARK: - Font

    /// META_CREATEFONTINDIRECT ([MS-WMF] §2.3.4.2 / Font Object §2.2.1.2): an
    /// 18-byte fixed part then a fixed 32-byte NUL-padded Latin-1 Facename (the
    /// form GDI emits). The shared LogFont's 32-bit metrics narrow to Int16.
    private static func createFontRecord(_ font: LogFont) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendInt16(try i16(font.height))
        b.appendInt16(try i16(font.width))
        b.appendInt16(try i16(font.escapement))
        b.appendInt16(try i16(font.orientation))
        b.appendInt16(try i16(font.weight))
        b.appendUInt8(font.italic)
        b.appendUInt8(font.underline)
        b.appendUInt8(font.strikeOut)
        b.appendUInt8(font.charSet)
        b.appendUInt8(font.outPrecision)
        b.appendUInt8(font.clipPrecision)
        b.appendUInt8(font.quality)
        b.appendUInt8(font.pitchAndFamily)
        appendFaceName(&b, font.faceName, byteCount: 32)
        return try frame(Function.createFontIndirect, b.bytes)
    }

    /// Writes exactly `byteCount` bytes of a NUL-terminable Latin-1 face name: the
    /// name's bytes (clamped to the field, less one for the terminator), a NUL,
    /// then zero padding.
    private static func appendFaceName(_ b: inout ByteWriter, _ name: String, byteCount: Int) {
        let bytes = latin1Bytes(name)
        let kept = Array(bytes.prefix(max(0, byteCount - 1)))
        b.appendBytes(kept)
        b.appendZeros(byteCount - kept.count)
    }

    // MARK: - Text

    /// META_TEXTOUT ([MS-WMF] §2.3.3.20): StringLength(Int16), the even-padded
    /// 8-bit String, then YStart, XStart (reversed).
    private static func textOutRecord(point: PointL, string: String) throws(WMFWriteError) -> [UInt8] {
        let text = latin1Bytes(string)
        guard let length = Int16(exactly: text.count) else {
            throw .stringTooLong(byteCount: text.count)
        }
        var b = ByteWriter()
        b.appendInt16(length)
        b.appendBytes(text)
        if text.count % 2 != 0 { b.appendUInt8(0) }           // pad the String to even
        b.appendInt16(try i16(point.y)); b.appendInt16(try i16(point.x))
        return try frame(Function.textOut, b.bytes)
    }

    /// META_EXTTEXTOUT ([MS-WMF] §2.3.3.5): Y, X, StringLength, fwOpts, an optional
    /// opaque/clip Rectangle (Left, Top, Right, Bottom — NOT reversed; present
    /// only when fwOpts sets ETO_OPAQUE 0x0002 or ETO_CLIPPED 0x0004), the
    /// even-padded String, then an optional per-character advance array.
    private static func extTextOutRecord(
        point: PointL, rectangle: RectL?, options: UInt16, string: String, dx: [Int16]?
    ) throws(WMFWriteError) -> [UInt8] {
        let text = latin1Bytes(string)
        guard let length = Int16(exactly: text.count) else {
            throw .stringTooLong(byteCount: text.count)
        }
        var b = ByteWriter()
        b.appendInt16(try i16(point.y)); b.appendInt16(try i16(point.x))
        b.appendInt16(length)
        b.appendUInt16(options)
        if options & 0x0006 != 0 {                            // ETO_OPAQUE | ETO_CLIPPED
            let r = rectangle ?? RectL(left: 0, top: 0, right: 0, bottom: 0)
            b.appendInt16(try i16(r.left)); b.appendInt16(try i16(r.top))
            b.appendInt16(try i16(r.right)); b.appendInt16(try i16(r.bottom))
        }
        b.appendBytes(text)
        if text.count % 2 != 0 { b.appendUInt8(0) }           // pad the String to even
        if let dx {
            guard dx.count <= Int(Int16.max) else {
                throw .countOutOfRange(field: "Dx", count: dx.count)
            }
            for advance in dx { b.appendInt16(advance) }
        }
        return try frame(Function.extTextOut, b.bytes)
    }

    // MARK: - Bitmap

    /// META_STRETCHDIB ([MS-WMF] §2.3.1.6): RasterOperation(u32), ColorUsage(u16),
    /// then SrcHeight, SrcWidth, YSrc, XSrc, DestHeight, DestWidth, YDest, XDest
    /// (all Int16, height-before-width and y-before-x), then the packed DIB.
    private static func stretchDIBRecord(
        rop: UInt32, usage: UInt16, src: PointL, srcSize: SizeL, dest: PointL, destSize: SizeL, dib: DIB
    ) throws(WMFWriteError) -> [UInt8] {
        var b = ByteWriter()
        b.appendUInt32(rop)
        b.appendUInt16(usage)
        b.appendInt16(try i16(srcSize.cy)); b.appendInt16(try i16(srcSize.cx))
        b.appendInt16(try i16(src.y)); b.appendInt16(try i16(src.x))
        b.appendInt16(try i16(destSize.cy)); b.appendInt16(try i16(destSize.cx))
        b.appendInt16(try i16(dest.y)); b.appendInt16(try i16(dest.x))
        // The DIB is the shared packed-DIB form (40-byte BITMAPINFOHEADER + color
        // table + bits), exactly what WMFParse's STRETCHDIB decoder reads. An
        // `.unsupported` DIB has no retained pixels, so none is appended.
        if let serial = EMFRecordEncoder.serializeDIB(dib) {
            b.appendBytes(serial.bmi)
            b.appendBytes(serial.bits)
        }
        return try frame(Function.stretchDIB, b.bytes)
    }

    // MARK: - Escape

    /// META_ESCAPE ([MS-WMF] §2.3.6.1): EscapeFunction(u16), ByteCount(u16), then
    /// the EscapeData. `ByteCount` is the true blob length; the record is
    /// WORD-padded if that is odd.
    private static func escapeRecord(escapeFunction: UInt16, data: [UInt8]) throws(WMFWriteError) -> [UInt8] {
        guard let byteCount = UInt16(exactly: data.count) else {
            throw .escapeDataTooLarge(byteCount: data.count)
        }
        var b = ByteWriter()
        b.appendUInt16(escapeFunction)
        b.appendUInt16(byteCount)
        b.appendBytes(data)
        return try frame(Function.escape, b.bytes)
    }

    /// Latin-1 (ISO-8859-1) bytes of `string`: every code point U+0000–U+00FF maps
    /// to its byte; anything above becomes '?' (0x3F). Lossy by design — WMF text
    /// is 8-bit, and the editor surfaces a "what WMF cannot hold" warning (v3 plan
    /// §11.1).
    private static func latin1Bytes(_ string: String) -> [UInt8] {
        string.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }
    }
}
