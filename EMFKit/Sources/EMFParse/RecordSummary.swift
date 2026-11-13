import Foundation

// MARK: - Record inspector one-line summaries (F5)
//
// A pure, allocation-bounded formatter that turns a decoded record payload into
// a short, human-readable PARAMETER summary for the record inspector — e.g.
// "(10,10)–(200,120)" for an EMR_RECTANGLE. It is the record NAME's companion:
// the inspector shows `EMFRecordType.name(for:)` (the EMR_* name) in its own
// column and this string beside it, so the name is deliberately NOT repeated
// here.
//
// Every value comes from the already-decoded `EMFRecordPayload`, whose decoder
// is itself §8-bounded (counts/offsets validated against the record's own
// nSize before any allocation), so a summary can never trap on a hostile file:
// point arrays are already capped, strings already length-validated. The only
// extra guards here are cosmetic — truncating a very long string or a very long
// point count so the inspector row stays one line.

/// Pure formatting of a decoded EMF record payload into a one-line parameter
/// summary for the record inspector. Returns "" for records with no parameters
/// worth showing (EMR_SAVEDC, EMR_BEGINPATH, EMR_EOF, …).
public enum EMFRecordSummary {

    /// The maximum number of characters of a decoded text string shown inline;
    /// longer strings are truncated with an ellipsis so the inspector row stays
    /// one line (the full string is never needed for a structural summary).
    public static let maxStringLength = 48

    /// A one-line parameter summary for `payload`. Pure and non-trapping.
    public static func line(for payload: EMFRecordPayload) -> String {
        switch payload {
        // MARK: State
        case .setWindowExtEx(let extent): return size(extent)
        case .setWindowOrgEx(let origin): return point(origin)
        case .setViewportExtEx(let extent): return size(extent)
        case .setViewportOrgEx(let origin): return point(origin)
        case .setMapMode(let mode): return mapModeName(mode)
        case .setBkMode(let mode): return bkModeName(mode)
        case .setPolyFillMode(let mode): return polyFillName(mode)
        case .setROP2(let raw): return hex32(raw)
        case .saveDC: return ""
        case .restoreDC(let saved): return String(saved)
        case .setWorldTransform(let xform): return matrix(xform)
        case .modifyWorldTransform(let p): return "\(modifyModeName(p.mode)) \(matrix(p.transform))"
        case .setMiterLimit(let limit): return String(limit)
        case .setArcDirection(let direction): return arcDirectionName(direction)
        case .setStretchBltMode(let mode): return stretchBltModeName(mode)
        case .setBrushOrgEx(let origin): return point(origin)
        case .intersectClipRect(let clip): return rect(clip)

        // MARK: Objects
        case .createPen(let p): return "#\(p.ihPen) \(color(p.color))"
        case .extCreatePen(let p): return "#\(p.ihPen) \(color(p.color)) w=\(p.width)"
        case .createBrushIndirect(let p): return "#\(p.ihBrush) \(color(p.color))"
        case .createDIBPatternBrushPT(let p), .createMonoBrush(let p):
            return "#\(p.ihBrush) \(dibSize(p.dib))"
        case .selectObject(let handle): return handleName(handle)
        case .deleteObject(let handle): return handleName(handle)

        // MARK: Paths and clipping
        case .beginPath, .endPath, .closeFigure, .abortPath: return ""
        case .fillPath(let b), .strokeAndFillPath(let b), .strokePath(let b): return rect(b)
        case .selectClipPath(let mode): return regionModeName(mode)
        case .extSelectClipRgn(let p):
            return "\(regionModeName(p.mode)), \(countNoun(p.rects.count, "rect"))"

        // MARK: 32-bit geometry
        case .polyBezier(let p), .polygon(let p), .polyline(let p),
             .polyBezierTo(let p), .polylineTo(let p):
            return countNoun(p.points.count, "point")
        case .polyPolyline(let p), .polyPolygon(let p):
            return "\(countNoun(p.pointCounts.count, "poly")), \(countNoun(p.points.count, "point"))"
        case .moveToEx(let point): return self.point(point)
        case .ellipse(let box): return rect(box)
        case .rectangle(let box): return rect(box)
        case .roundRect(let p): return "\(rect(p.box)) corner \(size(p.corner))"
        case .arc(let a): return "\(rect(a.box)) \(point(a.start))→\(point(a.end))"
        case .arcTo(let a): return "\(rect(a.box)) \(point(a.start))→\(point(a.end))"
        case .lineTo(let point): return "→ \(self.point(point))"

        // MARK: 16-bit geometry
        case .polyBezier16(let p), .polygon16(let p), .polyline16(let p),
             .polyBezierTo16(let p), .polylineTo16(let p):
            return countNoun(p.points.count, "point")
        case .polyPolyline16(let p), .polyPolygon16(let p):
            return "\(countNoun(p.pointCounts.count, "poly")), \(countNoun(p.points.count, "point"))"

        // MARK: Text
        case .setTextAlign(let align): return textAlignName(align)
        case .setTextColor(let c): return color(c)
        case .setBkColor(let c): return color(c)
        case .extCreateFontIndirectW(let p):
            let face = quoted(p.logFont.faceName)
            return "#\(p.ihFonts) \(face) h=\(p.logFont.height)"
        case .extTextOutA(let t), .extTextOutW(let t), .smallTextOut(let t):
            return "\(quoted(t.string)) @ \(point(t.reference))"

        // MARK: WMF-sourced primitives
        case .pie(let a), .chord(let a):
            return "\(rect(a.box)) \(point(a.start))→\(point(a.end))"
        case .setPixel(let point, let color): return "\(self.point(point)) \(self.color(color))"
        case .patBlt(let bounds, let rop): return "\(rect(bounds)) \(hex32(rop))"
        case .excludeClipRect(let clip): return rect(clip)
        case .gradientFill(let p):
            let primitives: Int
            switch p.mesh {
            case .rectangles(let r): primitives = r.count
            case .triangles(let t): primitives = t.count
            }
            return "\(gradientModeName(p.mode)), \(p.vertices.count) vert, \(primitives) prim"

        // MARK: Bitmaps
        case .stretchDIBits(let p):
            return "\(dibSize(p.dib)) → \(point(p.dest)) \(size(p.destSize))"
        case .bitBlt(let p):
            return "\(dibSize(p.dib)) → \(point(p.dest)) \(size(p.destSize))"
        case .stretchBlt(let p):
            return "\(dibSize(p.dib)) → \(point(p.dest)) \(size(p.destSize))"
        case .setDIBitsToDevice(let p):
            return "\(dibSize(p.dib)) → \(point(p.dest))"

        // MARK: Fallbacks
        case .unimplemented: return ""
        case .malformed(_, let reason): return "malformed: \(issueName(reason))"
        }
    }

    // MARK: - Header summary

    /// The one-line summary for the EMR_HEADER record (`records[0]`): its
    /// device-pixel bounds. The physical frame and record counts have their own
    /// place in the inspector's header panel, so the inline summary is the
    /// bounds rectangle that drives the device canvas.
    public static func header(_ header: EMFHeader) -> String {
        rect(header.bounds)
    }

    // MARK: - Field formatters

    static func rect(_ r: RectL) -> String {
        "(\(r.left),\(r.top))–(\(r.right),\(r.bottom))"
    }

    static func point(_ p: PointL) -> String { "(\(p.x),\(p.y))" }

    static func size(_ s: SizeL) -> String { "\(s.cx)×\(s.cy)" }

    static func color(_ c: ColorRef) -> String {
        String(format: "#%02X%02X%02X", c.red, c.green, c.blue)
    }

    static func hex32(_ value: UInt32) -> String {
        String(format: "0x%08X", value)
    }

    /// A short matrix notation for an XForm: the two linear rows then the
    /// translation, each to 3 significant places and trimmed of trailing zeros.
    static func matrix(_ x: XForm) -> String {
        "[\(num(x.m11)) \(num(x.m12)) \(num(x.m21)) \(num(x.m22))] +(\(num(x.dx)),\(num(x.dy)))"
    }

    /// A compact Float rendering: integers without a decimal point, otherwise up
    /// to three fractional digits with trailing zeros trimmed. Non-finite values
    /// are shown literally rather than producing a bogus number.
    static func num(_ value: Float) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "∞" : "-∞") }
        if value == value.rounded() {
            return String(Int(value))
        }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "N noun" / "N nouns" with simple pluralisation.
    static func countNoun(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    static func dibSize(_ dib: DIB?) -> String {
        guard let dib else { return "no bitmap" }
        // `height` is signed (top-down when negative); show its magnitude.
        let h = dib.height == Int32.min ? Int(Int32.max) + 1 : abs(Int(dib.height))
        return "\(dib.width)×\(h)"
    }

    /// A quoted, single-line, length-capped rendering of a decoded string.
    /// Newlines/tabs collapse to spaces so a multi-line run stays one row.
    static func quoted(_ raw: String) -> String {
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

    // MARK: - Enum names

    static func handleName(_ handle: ObjectHandle) -> String {
        switch handle {
        case .table(let index): return "#\(index)"
        case .stock(let stock): return stockName(stock)
        }
    }

    static func stockName(_ stock: StockObject) -> String {
        switch stock {
        case .whiteBrush: return "WHITE_BRUSH"
        case .ltGrayBrush: return "LTGRAY_BRUSH"
        case .grayBrush: return "GRAY_BRUSH"
        case .dkGrayBrush: return "DKGRAY_BRUSH"
        case .blackBrush: return "BLACK_BRUSH"
        case .nullBrush: return "NULL_BRUSH"
        case .whitePen: return "WHITE_PEN"
        case .blackPen: return "BLACK_PEN"
        case .nullPen: return "NULL_PEN"
        case .oemFixedFont: return "OEM_FIXED_FONT"
        case .ansiFixedFont: return "ANSI_FIXED_FONT"
        case .ansiVarFont: return "ANSI_VAR_FONT"
        case .systemFont: return "SYSTEM_FONT"
        case .deviceDefaultFont: return "DEVICE_DEFAULT_FONT"
        case .defaultPalette: return "DEFAULT_PALETTE"
        case .systemFixedFont: return "SYSTEM_FIXED_FONT"
        case .defaultGuiFont: return "DEFAULT_GUI_FONT"
        case .dcBrush: return "DC_BRUSH"
        case .dcPen: return "DC_PEN"
        case .unknownStock(let raw): return "stock \(hex32(raw))"
        }
    }

    static func mapModeName(_ mode: MapMode) -> String {
        switch mode {
        case .text: return "MM_TEXT"
        case .loMetric: return "MM_LOMETRIC"
        case .hiMetric: return "MM_HIMETRIC"
        case .loEnglish: return "MM_LOENGLISH"
        case .hiEnglish: return "MM_HIENGLISH"
        case .twips: return "MM_TWIPS"
        case .isotropic: return "MM_ISOTROPIC"
        case .anisotropic: return "MM_ANISOTROPIC"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func bkModeName(_ mode: BackgroundMode) -> String {
        switch mode {
        case .transparent: return "TRANSPARENT"
        case .opaque: return "OPAQUE"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func polyFillName(_ mode: PolygonFillMode) -> String {
        switch mode {
        case .alternate: return "ALTERNATE"
        case .winding: return "WINDING"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func arcDirectionName(_ direction: ArcDirection) -> String {
        switch direction {
        case .counterclockwise: return "AD_COUNTERCLOCKWISE"
        case .clockwise: return "AD_CLOCKWISE"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func gradientModeName(_ mode: GradientMode) -> String {
        switch mode {
        case .rectHorizontal: return "RECT_H"
        case .rectVertical: return "RECT_V"
        case .triangle: return "TRIANGLE"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func stretchBltModeName(_ mode: StretchBltMode) -> String {
        switch mode {
        case .blackOnWhite: return "BLACKONWHITE"
        case .whiteOnBlack: return "WHITEONBLACK"
        case .colorOnColor: return "COLORONCOLOR"
        case .halftone: return "HALFTONE"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func modifyModeName(_ mode: ModifyWorldTransformMode) -> String {
        switch mode {
        case .identity: return "MWT_IDENTITY"
        case .leftMultiply: return "MWT_LEFTMULTIPLY"
        case .rightMultiply: return "MWT_RIGHTMULTIPLY"
        case .set: return "MWT_SET"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func regionModeName(_ mode: RegionMode) -> String {
        switch mode {
        case .and: return "RGN_AND"
        case .or: return "RGN_OR"
        case .xor: return "RGN_XOR"
        case .diff: return "RGN_DIFF"
        case .copy: return "RGN_COPY"
        case .unknown(let raw): return hex32(raw)
        }
    }

    static func textAlignName(_ align: TextAlign) -> String {
        var parts: [String] = []
        switch align.horizontal {
        case .left: parts.append("TA_LEFT")
        case .right: parts.append("TA_RIGHT")
        case .center: parts.append("TA_CENTER")
        }
        switch align.vertical {
        case .top: parts.append("TA_TOP")
        case .bottom: parts.append("TA_BOTTOM")
        case .baseline: parts.append("TA_BASELINE")
        }
        if align.updatesCurrentPosition { parts.append("TA_UPDATECP") }
        return parts.joined(separator: " | ")
    }

    static func issueName(_ issue: EMFPayloadIssue) -> String {
        switch issue {
        case .tooSmall: return "record too small"
        case .countTooLarge: return "count too large"
        case .countMismatch: return "count mismatch"
        case .nonFiniteTransform: return "non-finite transform"
        case .badRegionHeader: return "bad region header"
        case .rangeOutOfBounds: return "range out of bounds"
        case .badBitmapDimensions: return "bad bitmap dimensions"
        case .badBitmapHeader: return "bad bitmap header"
        }
    }
}

// MARK: - EMFFile convenience

extension EMFFile {
    /// A one-line parameter summary for the record at `index` in `records`, for
    /// the record inspector. Decodes the record on demand via the §8-bounded
    /// `payload(of:)`, so it never traps on a hostile file. An out-of-range
    /// index returns "". Index 0 (EMR_HEADER) summarises the header bounds.
    public func recordSummary(at index: Int) -> String {
        guard records.indices.contains(index) else { return "" }
        if index == 0 { return EMFRecordSummary.header(header) }
        return EMFRecordSummary.line(for: payload(of: records[index]))
    }
}
