import Foundation

// MARK: - WMF record inspector one-line summaries (P3)
//
// The WMF counterpart to EMFParse's `EMFRecordSummary`: a pure, bounds-checked
// formatter that turns a WMF record's `rdParam` payload into a short, human
// PARAMETER summary for the record inspector — e.g. "(0,0)–(100,80)" for a
// META_RECTANGLE. It is the record NAME's companion (`WMFRecordType.name`), so
// the name is deliberately NOT repeated here.
//
// Every read goes through `WMFByteReader`, which bounds-checks each access and
// returns nil on overrun (never traps, never force-unwraps) — a hostile or
// truncated record yields a short, possibly empty, summary rather than a crash
// (§8). Field orders and offsets are read STRICTLY from [MS-WMF] §2.3; many
// records store coordinates Y-then-X, and rectangles Bottom/Right/Top/Left —
// the sections are cited where that matters.

public enum WMFRecordSummary {

    /// The maximum number of characters of a decoded text string shown inline.
    public static let maxStringLength = 48

    /// A one-line parameter summary for `record`, read from its `payload` (the
    /// `rdParam` bytes after the 6-byte RecordSize/RecordFunction header). Pure
    /// and non-trapping; returns "" for records with no parameters worth showing
    /// (META_SAVEDC, META_EOF, …) or an unrecognised function.
    public static func line(for record: WMFRawRecord, payload: Data) -> String {
        let body = WMFByteReader(payload)

        switch record.function {
        // MARK: State / mapping
        case 0x020B: return reversedPoint(body)                      // META_SETWINDOWORG (§2.3.5.31)
        case 0x020C: return reversedSize(body)                       // META_SETWINDOWEXT (§2.3.5.30)
        case 0x020D: return reversedPoint(body)                      // META_SETVIEWPORTORG (§2.3.5.29)
        case 0x020E: return reversedSize(body)                       // META_SETVIEWPORTEXT (§2.3.5.28)
        case 0x020F: return reversedPoint(body)                      // META_OFFSETWINDOWORG (§2.3.5.9)
        case 0x0211: return reversedPoint(body)                      // META_OFFSETVIEWPORTORG (§2.3.5.8)
        case 0x0410: return scalePair(body)                          // META_SCALEWINDOWEXT (§2.3.5.13)
        case 0x0412: return scalePair(body)                          // META_SCALEVIEWPORTEXT (§2.3.5.12)
        case 0x0220: return reversedPoint(body)                      // META_OFFSETCLIPRGN (§2.3.5.5)
        case 0x0103: return mapModeName(body.readUInt16(at: 0))      // META_SETMAPMODE (§2.3.5.17)
        case 0x0102: return bkModeName(body.readUInt16(at: 0))       // META_SETBKMODE (§2.3.5.14)
        case 0x0104: return hex16(body.readUInt16(at: 0))            // META_SETROP2 (§2.3.5.22)
        case 0x0106: return polyFillName(body.readUInt16(at: 0))     // META_SETPOLYFILLMODE (§2.3.5.20)
        case 0x0107: return stretchBltModeName(body.readUInt16(at: 0)) // META_SETSTRETCHBLTMODE (§2.3.5.23)
        case 0x012E: return hex16(body.readUInt16(at: 0))            // META_SETTEXTALIGN (§2.3.5.24)
        case 0x0108: return int16Text(body.readInt16(at: 0))         // META_SETTEXTCHAREXTRA (§2.3.5.25)
        case 0x0209: return color(body, at: 0)                       // META_SETTEXTCOLOR (§2.3.5.26)
        case 0x0201: return color(body, at: 0)                       // META_SETBKCOLOR (§2.3.5.15)
        case 0x0127: return int16Text(body.readInt16(at: 0))         // META_RESTOREDC (§2.3.5.10)

        // MARK: Objects
        case 0x02FA: return createPen(body)                          // META_CREATEPENINDIRECT (§2.3.4.5)
        case 0x02FC: return createBrush(body)                        // META_CREATEBRUSHINDIRECT (§2.3.4.1)
        case 0x02FB: return createFont(body)                         // META_CREATEFONTINDIRECT (§2.3.4.2)
        case 0x012D: return objectIndex(body.readUInt16(at: 0))      // META_SELECTOBJECT (§2.3.4.10)
        case 0x01F0: return objectIndex(body.readUInt16(at: 0))      // META_DELETEOBJECT (§2.3.4.7)
        case 0x012C: return objectIndex(body.readUInt16(at: 0))      // META_SELECTCLIPREGION (§2.3.4.9)

        // MARK: Geometry
        case 0x0214: return reversedPoint(body)                      // META_MOVETO (§2.3.3.4)
        case 0x0213: return "→ " + reversedPoint(body)               // META_LINETO (§2.3.3.10)
        case 0x041B: return reversedRect(body)                       // META_RECTANGLE (§2.3.3.17)
        case 0x0418: return reversedRect(body)                       // META_ELLIPSE (§2.3.3.3)
        case 0x0416: return reversedRect(body)                       // META_INTERSECTCLIPRECT (§2.3.5.3)
        case 0x0415: return reversedRect(body)                       // META_EXCLUDECLIPRECT (§2.3.5.2)
        case 0x061C: return roundRect(body)                          // META_ROUNDRECT (§2.3.3.18)
        case 0x0817, 0x081A, 0x0830: return arc(body)                // META_ARC/PIE/CHORD (§2.3.3.1/.13/.2)
        case 0x0324: return poly16(body, "point")                    // META_POLYGON (§2.3.3.15)
        case 0x0325: return poly16(body, "point")                    // META_POLYLINE (§2.3.3.14)
        case 0x0538: return polyPolygon(body)                        // META_POLYPOLYGON (§2.3.3.16)
        case 0x041F: return setPixel(body)                           // META_SETPIXEL (§2.3.3.19)
        case 0x061D: return patBlt(body)                             // META_PATBLT (§2.3.3.12)

        // MARK: Text
        case 0x0521: return textOut(body)                            // META_TEXTOUT (§2.3.3.20)
        case 0x0A32: return extTextOut(body)                         // META_EXTTEXTOUT (§2.3.3.5)

        // MARK: Bitmaps
        case 0x0F43: return stretchDIB(body)                         // META_STRETCHDIB (§2.3.1.6)
        case 0x0B41: return dibStretchBlt(body, record: record)      // META_DIBSTRETCHBLT (§2.3.1.3)
        case 0x0940: return dibBitBlt(body, record: record)          // META_DIBBITBLT (§2.3.1.2)
        case 0x0D33: return setDIBToDev(body)                        // META_SETDIBTODEV (§2.3.1.4)

        default: return ""
        }
    }

    // MARK: - Field formatters (reversed orders per [MS-WMF] §2.3)

    /// A point stored Y-then-X ([MS-WMF] §2.3.3.4 et al.): "(x,y)".
    private static func reversedPoint(_ body: WMFByteReader) -> String {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2) else { return "" }
        return "(\(x),\(y))"
    }

    /// A size stored Y-then-X ([MS-WMF] §2.3.5.30): "cx×cy".
    private static func reversedSize(_ body: WMFByteReader) -> String {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2) else { return "" }
        return "\(x)×\(y)"
    }

    /// A rectangle stored Bottom, Right, Top, Left ([MS-WMF] §2.3.3.17):
    /// "(left,top)–(right,bottom)".
    private static func reversedRect(_ body: WMFByteReader) -> String {
        guard let bottom = body.readInt16(at: 0), let right = body.readInt16(at: 2),
              let top = body.readInt16(at: 4), let left = body.readInt16(at: 6) else { return "" }
        return "(\(left),\(top))–(\(right),\(bottom))"
    }

    /// META_ROUNDRECT ([MS-WMF] §2.3.3.18): Height, Width, Bottom, Right, Top, Left.
    private static func roundRect(_ body: WMFByteReader) -> String {
        guard let height = body.readInt16(at: 0), let width = body.readInt16(at: 2),
              let bottom = body.readInt16(at: 4), let right = body.readInt16(at: 6),
              let top = body.readInt16(at: 8), let left = body.readInt16(at: 10) else { return "" }
        return "(\(left),\(top))–(\(right),\(bottom)) corner \(width)×\(height)"
    }

    /// META_ARC/PIE/CHORD ([MS-WMF] §2.3.3.1/.13/.2): yEnd, xEnd, yStart, xStart,
    /// Bottom, Right, Top, Left.
    private static func arc(_ body: WMFByteReader) -> String {
        guard let yEnd = body.readInt16(at: 0), let xEnd = body.readInt16(at: 2),
              let yStart = body.readInt16(at: 4), let xStart = body.readInt16(at: 6),
              let bottom = body.readInt16(at: 8), let right = body.readInt16(at: 10),
              let top = body.readInt16(at: 12), let left = body.readInt16(at: 14) else { return "" }
        return "(\(left),\(top))–(\(right),\(bottom)) (\(xStart),\(yStart))→(\(xEnd),\(yEnd))"
    }

    /// META_POLYGON / META_POLYLINE ([MS-WMF] §2.3.3.15/.14): NumberOfPoints (Int16).
    private static func poly16(_ body: WMFByteReader, _ noun: String) -> String {
        guard let count = body.readInt16(at: 0), count >= 0 else { return "" }
        return countNoun(Int(count), noun)
    }

    /// META_POLYPOLYGON ([MS-WMF] §2.3.3.16): NumberOfPolygons (UInt16) then the
    /// per-polygon point counts (UInt16 each), both validated against the payload.
    private static func polyPolygon(_ body: WMFByteReader) -> String {
        guard let polyCount = body.readUInt16(at: 0) else { return "" }
        let polys = Int(polyCount)
        guard 2 + polys * 2 <= body.count else { return countNoun(polys, "poly") }
        var points = 0
        for i in 0 ..< polys {
            guard let c = body.readUInt16(at: 2 + i * 2) else { break }
            points += Int(c)
        }
        return "\(countNoun(polys, "poly")), \(countNoun(points, "point"))"
    }

    /// META_SETPIXEL ([MS-WMF] §2.3.3.19): ColorRef(0), Y(4), X(6).
    private static func setPixel(_ body: WMFByteReader) -> String {
        guard !color(body, at: 0).isEmpty,
              let y = body.readInt16(at: 4), let x = body.readInt16(at: 6) else { return "" }
        return "(\(x),\(y)) \(color(body, at: 0))"
    }

    /// META_PATBLT ([MS-WMF] §2.3.3.12): RasterOperation(4 bytes @0), Height, Width,
    /// YLeft, XLeft. The rectangle is (XLeft,YLeft) extended by Width × Height.
    private static func patBlt(_ body: WMFByteReader) -> String {
        guard let rop = body.readUInt32(at: 0),
              let height = body.readInt16(at: 4), let width = body.readInt16(at: 6),
              let yLeft = body.readInt16(at: 8), let xLeft = body.readInt16(at: 10) else { return "" }
        let left = Int32(xLeft), top = Int32(yLeft)
        return "(\(left),\(top))–(\(left + Int32(width)),\(top + Int32(height))) \(hex32(rop))"
    }

    /// META_SCALEWINDOWEXT / META_SCALEVIEWPORTEXT ([MS-WMF] §2.3.5.13/.12):
    /// yDenom, yNum, xDenom, xNum.
    private static func scalePair(_ body: WMFByteReader) -> String {
        guard let yDenom = body.readInt16(at: 0), let yNum = body.readInt16(at: 2),
              let xDenom = body.readInt16(at: 4), let xNum = body.readInt16(at: 6) else { return "" }
        return "x ×\(xNum)/\(xDenom), y ×\(yNum)/\(yDenom)"
    }

    // MARK: Objects

    /// Pen Object ([MS-WMF] §2.2.1.4): PenStyle(2), Width PointS (x used), ColorRef(4).
    private static func createPen(_ body: WMFByteReader) -> String {
        guard let style = body.readUInt16(at: 0), let widthX = body.readInt16(at: 2),
              !color(body, at: 6).isEmpty else { return "" }
        return "style \(hex16(style)) w=\(widthX) \(color(body, at: 6))"
    }

    /// LogBrush Object ([MS-WMF] §2.2.2.10): BrushStyle(2), ColorRef(4), BrushHatch(2).
    private static func createBrush(_ body: WMFByteReader) -> String {
        guard let style = body.readUInt16(at: 0), !color(body, at: 2).isEmpty else { return "" }
        return "style \(hex16(style)) \(color(body, at: 2))"
    }

    /// Font Object ([MS-WMF] §2.2.1.2): Height(Int16) @0, Width(2), Escapement(2),
    /// Orientation(2), Weight(Int16) @8, Italic(UInt8) @10, Underline, StrikeOut,
    /// CharSet, …, then a NUL-terminated Latin-1 Facename of up to 32 bytes at
    /// offset 18. The summary shows the face, height, weight and italic.
    private static func createFont(_ body: WMFByteReader) -> String {
        guard let height = body.readInt16(at: 0) else { return "" }
        let weight = body.readInt16(at: 8) ?? 0
        let italic = (body.readUInt8(at: 10) ?? 0) != 0
        var text = "\(quoted(faceName(body))) h=\(height) w=\(weight)"
        if italic { text += " italic" }
        return text
    }

    private static func faceName(_ body: WMFByteReader) -> String {
        var units: [UInt8] = []
        for i in 0 ..< 32 {
            guard let byte = body.readUInt8(at: 18 + i), byte != 0 else { break }
            units.append(byte)
        }
        return String(bytes: units, encoding: .isoLatin1) ?? ""
    }

    /// A selected/deleted object index ([MS-WMF] §2.3.4.10): a stock object when
    /// the high bit is set, otherwise the 0-based table slot.
    private static func objectIndex(_ raw: UInt16?) -> String {
        guard let raw else { return "" }
        if raw & 0x8000 != 0 { return "stock \(hex16(raw & 0x7FFF))" }
        return "#\(raw)"
    }

    // MARK: Text

    /// META_TEXTOUT ([MS-WMF] §2.3.3.20): StringLength(Int16), the even-padded
    /// 8-bit String, then YStart, XStart.
    private static func textOut(_ body: WMFByteReader) -> String {
        guard let rawLength = body.readInt16(at: 0), rawLength >= 0 else { return "" }
        let length = Int(rawLength)
        let padded = (length + 1) & ~1
        guard let stringData = body.data(at: 2, length: length) else { return "" }
        let text = quoted(latin1(stringData))
        if let y = body.readInt16(at: 2 + padded), let x = body.readInt16(at: 2 + padded + 2) {
            return "\(text) @ (\(x),\(y))"
        }
        return text
    }

    /// META_EXTTEXTOUT ([MS-WMF] §2.3.3.5): Y(0), X(2), StringLength(4), fwOpts(6),
    /// an optional Rectangle (present only when ETO_OPAQUE/ETO_CLIPPED is set), then
    /// the even-padded 8-bit String.
    private static func extTextOut(_ body: WMFByteReader) -> String {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2),
              let rawLength = body.readInt16(at: 4), rawLength >= 0,
              let fwOpts = body.readUInt16(at: 6) else { return "" }
        let length = Int(rawLength)
        // ETO_OPAQUE (0x0002) / ETO_CLIPPED (0x0004) each add an 8-byte Rectangle.
        let stringOffset = (fwOpts & 0x0006) != 0 ? 16 : 8
        guard let stringData = body.data(at: stringOffset, length: length) else {
            return "@ (\(x),\(y))"
        }
        return "\(quoted(latin1(stringData))) @ (\(x),\(y))"
    }

    // MARK: Bitmaps

    /// META_STRETCHDIB ([MS-WMF] §2.3.1.6): RasterOperation(4) @0, ColorUsage(4),
    /// SrcHeight(6), SrcWidth(8), YSrc, XSrc, DestHeight(14), DestWidth(16), YDest,
    /// XDest. The DIB tail follows at offset 22.
    private static func stretchDIB(_ body: WMFByteReader) -> String {
        guard let srcH = body.readInt16(at: 6), let srcW = body.readInt16(at: 8),
              let destH = body.readInt16(at: 14), let destW = body.readInt16(at: 16),
              let yDst = body.readInt16(at: 18), let xDst = body.readInt16(at: 20) else { return "" }
        return "\(srcW)×\(srcH) → (\(xDst),\(yDst)) \(destW)×\(destH)"
    }

    /// META_DIBSTRETCHBLT ([MS-WMF] §2.3.1.3): RasterOperation(4) @0, then (with a
    /// source bitmap) SrcHeight(4), SrcWidth(6), YSrc, XSrc, DestHeight(12),
    /// DestWidth(14), YDest, XDest. A sourceless form inserts a Reserved WORD before
    /// the destination, shifting those four by one WORD ([MS-WMF] §2.3.1.3).
    private static func dibStretchBlt(_ body: WMFByteReader, record: WMFRawRecord) -> String {
        guard let srcH = body.readInt16(at: 4), let srcW = body.readInt16(at: 6) else { return "" }
        let d = isSourceless(record) ? 14 : 12
        guard let destH = body.readInt16(at: d), let destW = body.readInt16(at: d + 2),
              let yDst = body.readInt16(at: d + 4), let xDst = body.readInt16(at: d + 6) else { return "" }
        return "\(srcW)×\(srcH) → (\(xDst),\(yDst)) \(destW)×\(destH)"
    }

    /// META_DIBBITBLT ([MS-WMF] §2.3.1.2): RasterOperation(4) @0, then (with a
    /// source bitmap) YSrc(4), XSrc(6), Height(8), Width(10), YDest(12), XDest(14).
    /// A sourceless form inserts a Reserved WORD before the source, shifting the
    /// rest by one WORD.
    private static func dibBitBlt(_ body: WMFByteReader, record: WMFRawRecord) -> String {
        let s = isSourceless(record) ? 6 : 4
        guard let height = body.readInt16(at: s + 4), let width = body.readInt16(at: s + 6),
              let yDest = body.readInt16(at: s + 8), let xDest = body.readInt16(at: s + 10) else { return "" }
        return "→ (\(xDest),\(yDest)) \(width)×\(height)"
    }

    /// META_SETDIBTODEV ([MS-WMF] §2.3.1.4): ColorUsage(0), ScanCount(2),
    /// StartScan(4), yDib(6), xDib(8), Height(10), Width(12), YDest(14), XDest(16).
    private static func setDIBToDev(_ body: WMFByteReader) -> String {
        guard let height = body.readUInt16(at: 10), let width = body.readUInt16(at: 12),
              let yDest = body.readUInt16(at: 14), let xDest = body.readUInt16(at: 16) else { return "" }
        return "\(width)×\(height) → (\(xDest),\(yDest))"
    }

    /// The without-source-bitmap test for the blt records ([MS-WMF] §2.3.1.2/.3):
    /// a source bitmap is absent when `RecordSize == (RecordFunction >> 8) + 3`.
    private static func isSourceless(_ record: WMFRawRecord) -> Bool {
        record.sizeWords == UInt32(record.function >> 8) + 3
    }

    // MARK: - Primitive formatters

    /// A ColorRef ([MS-WMF] §2.2.2.8): the low byte of the little-endian word is
    /// Red. "" when the 4-byte window is out of range.
    private static func color(_ body: WMFByteReader, at offset: Int) -> String {
        guard let raw = body.readUInt32(at: offset) else { return "" }
        return String(format: "#%02X%02X%02X", raw & 0xFF, (raw >> 8) & 0xFF, (raw >> 16) & 0xFF)
    }

    private static func hex16(_ value: UInt16?) -> String {
        guard let value else { return "" }
        return String(format: "0x%04X", value)
    }

    private static func hex16(_ value: UInt16) -> String { String(format: "0x%04X", value) }

    private static func hex32(_ value: UInt32) -> String { String(format: "0x%08X", value) }

    private static func int16Text(_ value: Int16?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func countNoun(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Enum names

    /// MapMode ([MS-WMF] §2.1.1.16).
    private static func mapModeName(_ mode: UInt16?) -> String {
        switch mode {
        case 0x0001: return "MM_TEXT"
        case 0x0002: return "MM_LOMETRIC"
        case 0x0003: return "MM_HIMETRIC"
        case 0x0004: return "MM_LOENGLISH"
        case 0x0005: return "MM_HIENGLISH"
        case 0x0006: return "MM_TWIPS"
        case 0x0007: return "MM_ISOTROPIC"
        case 0x0008: return "MM_ANISOTROPIC"
        case let other?: return hex16(other)
        case nil: return ""
        }
    }

    /// MixMode / background mode ([MS-WMF] §2.1.1.20).
    private static func bkModeName(_ mode: UInt16?) -> String {
        switch mode {
        case 0x0001: return "TRANSPARENT"
        case 0x0002: return "OPAQUE"
        case let other?: return hex16(other)
        case nil: return ""
        }
    }

    /// PolyFillMode ([MS-WMF] §2.1.1.25).
    private static func polyFillName(_ mode: UInt16?) -> String {
        switch mode {
        case 0x0001: return "ALTERNATE"
        case 0x0002: return "WINDING"
        case let other?: return hex16(other)
        case nil: return ""
        }
    }

    /// StretchMode ([MS-WMF] §2.1.1.30).
    private static func stretchBltModeName(_ mode: UInt16?) -> String {
        switch mode {
        case 0x0001: return "BLACKONWHITE"
        case 0x0002: return "WHITEONBLACK"
        case 0x0003: return "COLORONCOLOR"
        case 0x0004: return "HALFTONE"
        case let other?: return hex16(other)
        case nil: return ""
        }
    }

    /// A lossless Latin-1 reading of a decoded run for the inline preview (every
    /// byte maps). The rendered text uses the font's real codepage; a summary only
    /// needs a readable, non-trapping one-liner.
    private static func latin1(_ bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    /// A quoted, single-line, length-capped rendering of a string.
    private static func quoted(_ raw: String) -> String {
        var flattened = ""
        flattened.reserveCapacity(min(raw.count, maxStringLength + 1))
        var count = 0
        for character in raw {
            if count >= maxStringLength { flattened += "…"; break }
            if character == "\n" || character == "\r" || character == "\t" {
                flattened.append(" ")
            } else {
                flattened.append(character)
            }
            count += 1
        }
        return "\"\(flattened)\""
    }
}
