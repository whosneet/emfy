import Foundation
import EMFParse

/// Serialises one decoded `EMFRecordPayload` back to its exact on-disk record
/// bytes (the 8-byte `Type`/`Size` header plus the body), inverting
/// `EMFFile.payload(of:)`. Every field offset below is record-start-relative and
/// counts the 8-byte header, matching the [MS-EMF] §2.3 field tables and the
/// decoder in EMFParse.PayloadDecoder; the spec section is cited on each case.
///
/// Faithfulness contract: for a payload the decoder produced, `encode` yields a
/// record that re-parses to an EQUAL payload (a decode→encode→decode fixed
/// point) and renders identically. It is additionally byte-identical to the
/// original record whenever that record was already in the canonical form this
/// encoder emits (fixed-length records, and variable-length records with no
/// slack — extra padding, non-canonical field offsets, or decoder-dropped
/// fields such as EMR_EXTTEXTOUTW's ignored Bounds are the only sources of a
/// byte difference). Payloads the decoder CANNOT round-trip losslessly —
/// `.unsupported` DIBs (pixel bytes not retained), extended LogFont data, and
/// pattern-DIB pens — are reported by `isFaithfullyEncodable` so the document
/// writer re-emits their original bytes instead (primer §8, log-and-skip's
/// write-side analogue).
public enum EMFRecordEncoder {

    /// Encodes `payload` to its full record bytes. Throws only for payloads that
    /// have no EMF record form here (`.unimplemented`/`.malformed`, which the
    /// document writer passes through instead, and the WMF-only `.patBlt`) or a
    /// length that overflows a size field.
    public static func encode(_ payload: EMFRecordPayload) throws(EMFWriteError) -> Data {
        switch payload {
        // MARK: State ([MS-EMF] §2.3.11, §2.3.2.3)
        case .setWindowExtEx(let extent):
            return try sizeLRecord(9, extent)                       // §2.3.11.30
        case .setWindowOrgEx(let origin):
            return try pointLRecord(10, origin)                     // §2.3.11.31
        case .setViewportExtEx(let extent):
            return try sizeLRecord(11, extent)                      // §2.3.11.28
        case .setViewportOrgEx(let origin):
            return try pointLRecord(12, origin)                     // §2.3.11.29
        case .setMapMode(let mode):
            return try u32Record(17, mapModeRaw(mode))              // §2.3.11.19
        case .setBkMode(let mode):
            return try u32Record(18, backgroundModeRaw(mode))       // §2.3.11.11
        case .setPolyFillMode(let mode):
            return try u32Record(19, polyFillModeRaw(mode))         // §2.3.11.22
        case .setROP2(let rawMode):
            return try u32Record(20, rawMode)                       // §2.3.11.23
        case .setStretchBltMode(let mode):
            return try u32Record(21, stretchBltModeRaw(mode))       // §2.3.11.24
        case .saveDC:
            return try emptyRecord(33)                              // §2.3.11.7
        case .restoreDC(let savedDC):
            return try u32Record(34, UInt32(bitPattern: savedDC))   // §2.3.11.6
        case .setWorldTransform(let xform):
            return try xformRecord(35, xform)                       // §2.3.12.2
        case .modifyWorldTransform(let p):
            return try modifyWorldTransformRecord(p)                // §2.3.12.1
        case .setMiterLimit(let miterLimit):
            return try u32Record(58, miterLimit)                    // §2.3.11.21
        case .intersectClipRect(let clip):
            return try rectLRecord(30, clip)                        // §2.3.2.3

        // MARK: Object creation / manipulation ([MS-EMF] §2.3.7, §2.3.8)
        case .createPen(let p):
            return try createPenRecord(p)                           // §2.3.7.7
        case .extCreatePen(let p):
            return try extCreatePenRecord(p)                        // §2.3.7.9
        case .createBrushIndirect(let p):
            return try createBrushRecord(p)                         // §2.3.7.1
        case .selectObject(let handle):
            return try u32Record(37, objectHandleRaw(handle))       // §2.3.8.5
        case .deleteObject(let handle):
            return try u32Record(40, objectHandleRaw(handle))       // §2.3.8.3

        // MARK: Paths and clipping ([MS-EMF] §2.3.5, §2.3.2)
        case .beginPath:
            return try emptyRecord(59)                              // §2.3.5.4
        case .endPath:
            return try emptyRecord(60)                              // §2.3.5.6
        case .closeFigure:
            return try emptyRecord(61)                              // §2.3.5.5
        case .abortPath:
            return try emptyRecord(68)                              // §2.3.10.1
        case .fillPath(let bounds):
            return try rectLRecord(62, bounds)                      // §2.3.5.9
        case .strokeAndFillPath(let bounds):
            return try rectLRecord(63, bounds)                      // §2.3.5.38
        case .strokePath(let bounds):
            return try rectLRecord(64, bounds)                      // §2.3.5.39
        case .selectClipPath(let mode):
            return try u32Record(67, regionModeRaw(mode))           // §2.3.2.5
        case .extSelectClipRgn(let p):
            return try extSelectClipRgnRecord(p)                    // §2.3.2.2

        // MARK: 32-bit geometry ([MS-EMF] §2.3.5, §2.3.11.4)
        case .polyBezier(let p):
            return try poly32Record(2, p)                           // §2.3.5.16
        case .polygon(let p):
            return try poly32Record(3, p)                           // §2.3.5.22
        case .polyline(let p):
            return try poly32Record(4, p)                           // §2.3.5.24
        case .polyBezierTo(let p):
            return try poly32Record(5, p)                           // §2.3.5.18
        case .polylineTo(let p):
            return try poly32Record(6, p)                           // §2.3.5.26
        case .polyPolyline(let p):
            return try polyPoly32Record(7, p)                       // §2.3.5.30
        case .polyPolygon(let p):
            return try polyPoly32Record(8, p)                       // §2.3.5.28
        case .moveToEx(let point):
            return try pointLRecord(27, point)                      // §2.3.11.4
        case .ellipse(let box):
            return try rectLRecord(42, box)                         // §2.3.5.5
        case .rectangle(let box):
            return try rectLRecord(43, box)                         // §2.3.5.34
        case .roundRect(let p):
            return try roundRectRecord(p)                           // §2.3.5.35
        case .arc(let p):
            return try arcRecord(45, p)                             // §2.3.5.2
        case .arcTo(let p):
            return try arcRecord(55, p)                             // §2.3.5.3 (ARC layout)
        case .setArcDirection(let direction):
            return try u32Record(57, arcDirectionRaw(direction))   // §2.3.11.1
        case .lineTo(let point):
            return try pointLRecord(54, point)                      // §2.3.5.13

        // MARK: 16-bit geometry ([MS-EMF] §2.3.5)
        case .polyBezier16(let p):
            return try poly16Record(85, p)                          // §2.3.5.17
        case .polygon16(let p):
            return try poly16Record(86, p)                          // §2.3.5.23
        case .polyline16(let p):
            return try poly16Record(87, p)                          // §2.3.5.25
        case .polyBezierTo16(let p):
            return try poly16Record(88, p)                          // §2.3.5.19
        case .polylineTo16(let p):
            return try poly16Record(89, p)                          // §2.3.5.27
        case .polyPolyline16(let p):
            return try polyPoly16Record(90, p)                      // §2.3.5.31
        case .polyPolygon16(let p):
            return try polyPoly16Record(91, p)                      // §2.3.5.29

        // MARK: Text ([MS-EMF] §2.3.11, §2.3.5.8, §2.3.7.8)
        case .setTextAlign(let align):
            return try u32Record(22, align.rawValue)                // §2.3.11.25
        case .setTextColor(let color):
            return try colorRecord(24, color)                       // §2.3.11.26
        case .setBkColor(let color):
            return try colorRecord(25, color)                       // §2.3.11.10
        case .extCreateFontIndirectW(let p):
            return try extCreateFontRecord(p)                       // §2.3.7.8
        case .extTextOutW(let p):
            return try extTextOutWRecord(p)                         // §2.3.5.8

        // MARK: WMF-sourced primitives ([MS-WMF] §2.3.3, §2.3.5)
        // The EMF decoder never produces these — they arrive only from the WMF
        // translator (EMFRecordPayload comment). Four lower to real EMF records
        // (EMR_PIE 47 / EMR_CHORD 46 / EMR_SETPIXELV 15 / EMR_EXCLUDECLIPRECT
        // 29) so an E1 scene or a future WMF→EMF path can emit them; EMR_PIE and
        // EMR_CHORD share EMR_ARC's layout (§2.3.5.2). PatBlt has no single EMF
        // record and belongs to the WMF writer (E0c).
        case .pie(let p):
            return try arcRecord(47, p)                             // §2.3.5 (ARC layout)
        case .chord(let p):
            return try arcRecord(46, p)                             // §2.3.5 (ARC layout)
        case .setPixel(let point, let color):
            return try setPixelRecord(point: point, color: color)   // §2.3.5.30
        case .excludeClipRect(let clip):
            return try rectLRecord(29, clip)                        // §2.3.2.1
        case .patBlt:
            throw .unsupportedPayload(label: "patBlt (WMF primitive — use the WMF writer, E0c)")

        // MARK: Bitmaps ([MS-EMF] §2.3.1)
        case .stretchDIBits(let p):
            return try stretchDIBitsRecord(p)                       // §2.3.1.7
        case .bitBlt(let p):
            return try bitBltRecord(p, type: 76, stretch: false)    // §2.3.1.2
        case .stretchBlt(let p):
            return try bitBltRecord(p, type: 77, stretch: true)     // §2.3.1.6
        case .setDIBitsToDevice(let p):
            return try setDIBitsToDeviceRecord(p)                   // §2.3.1.5

        // MARK: Fallbacks
        case .unimplemented(let type):
            throw .unsupportedPayload(label: "unimplemented(type: \(type))")
        case .malformed(let type, _):
            throw .unsupportedPayload(label: "malformed(type: \(type))")
        }
    }

    /// Whether `encode` reproduces `payload` faithfully — a decode→encode→decode
    /// fixed point that renders identically. False for payloads the decoder
    /// lowered lossily: `.unimplemented`/`.malformed` (never decoded),
    /// `.unsupported`-content DIBs (pixel bytes not retained), extended LogFont
    /// data, pattern-DIB pens (DIB bytes not retained), and `.patBlt` (no EMF
    /// form). The document writer re-emits those from their original bytes.
    public static func isFaithfullyEncodable(_ payload: EMFRecordPayload) -> Bool {
        switch payload {
        case .unimplemented, .malformed, .patBlt:
            return false
        case .extCreateFontIndirectW(let p):
            return !p.hasExtendedData
        case .extCreatePen(let p):
            // A pattern/DIB pen carries bitmap bytes this payload does not retain.
            return p.cbBmi == 0 && p.cbBits == 0 && p.offBmi == 0 && p.offBits == 0
        case .stretchDIBits(let p):
            return dibIsRetained(p.dib)
        case .bitBlt(let p), .stretchBlt(let p):
            return dibIsRetained(p.dib)
        case .setDIBitsToDevice(let p):
            return dibIsRetained(p.dib)
        default:
            return true
        }
    }

    /// A DIB whose pixel bytes survived decode (nil = sourceless, which re-emits
    /// faithfully; `.pixels` = retained; `.unsupported` = bytes dropped).
    private static func dibIsRetained(_ dib: DIB?) -> Bool {
        guard let dib else { return true }
        if case .unsupported = dib.content { return false }
        return true
    }

    // MARK: - Record framing

    /// Wraps a body in the 8-byte `Type`/`Size` header, 4-padding the whole
    /// record ([MS-EMF] §2.3: `nSize` is a multiple of 4). All fixed-shape
    /// bodies are already 4-aligned; the pad is belt-and-braces plus the one
    /// real user — EMR_EXTTEXTOUTW's variable tail.
    private static func wrap(_ type: UInt32, _ body: ByteWriter) throws(EMFWriteError) -> Data {
        var padded = body
        padded.padTo4()
        let total = 8 + padded.count
        guard total <= Int(UInt32.max) else {
            throw .recordTooLarge(recordType: type, byteLength: total)
        }
        var out = ByteWriter(capacity: total)
        out.appendUInt32(type)
        out.appendUInt32(UInt32(total))
        out.appendBytes(padded.bytes)
        return out.data
    }

    // MARK: - Fixed-shape helpers

    private static func emptyRecord(_ type: UInt32) throws(EMFWriteError) -> Data {
        try wrap(type, ByteWriter())
    }

    private static func u32Record(_ type: UInt32, _ value: UInt32) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendUInt32(value)
        return try wrap(type, b)
    }

    private static func pointLRecord(_ type: UInt32, _ point: PointL) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendPointL(point)
        return try wrap(type, b)
    }

    private static func sizeLRecord(_ type: UInt32, _ size: SizeL) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendSizeL(size)
        return try wrap(type, b)
    }

    private static func rectLRecord(_ type: UInt32, _ rect: RectL) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(rect)
        return try wrap(type, b)
    }

    private static func colorRecord(_ type: UInt32, _ color: ColorRef) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendColorRef(color)
        return try wrap(type, b)
    }

    private static func xformRecord(_ type: UInt32, _ xform: XForm) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendXForm(xform)
        return try wrap(type, b)
    }

    /// EMR_MODIFYWORLDTRANSFORM §2.3.12.1: XForm at 8, Mode u32 at 32. The
    /// XForm is written even for MWT_IDENTITY (the record carries it; the
    /// renderer ignores it), so the payload is a fixed point.
    private static func modifyWorldTransformRecord(
        _ p: ModifyWorldTransformPayload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendXForm(p.transform)
        b.appendUInt32(modifyModeRaw(p.mode))
        return try wrap(36, b)
    }

    /// EMR_ROUNDRECT §2.3.5.35: Box RectL at 8, Corner SizeL at 24.
    private static func roundRectRecord(_ p: RoundRectPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.box)
        b.appendSizeL(p.corner)
        return try wrap(44, b)
    }

    /// EMR_ARC §2.3.5.2 (and the structurally identical EMR_PIE 47 / EMR_CHORD
    /// 46): Box RectL at 8, Start PointL at 24, End PointL at 32.
    private static func arcRecord(_ type: UInt32, _ p: ArcPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.box)
        b.appendPointL(p.start)
        b.appendPointL(p.end)
        return try wrap(type, b)
    }

    /// EMR_SETPIXELV §2.3.5.30: Pixel PointL at 8, Color ColorRef at 16.
    private static func setPixelRecord(point: PointL, color: ColorRef) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendPointL(point)
        b.appendColorRef(color)
        return try wrap(15, b)
    }

    /// EMR_CREATEPEN §2.3.7.7: ihPen at 8, PenStyle at 12, Width PointL at 16,
    /// ColorRef at 24.
    private static func createPenRecord(_ p: CreatePenPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendUInt32(p.ihPen)
        b.appendUInt32(p.style)
        b.appendPointL(p.width)
        b.appendColorRef(p.color)
        return try wrap(38, b)
    }

    /// EMR_CREATEBRUSHINDIRECT §2.3.7.1: ihBrush at 8, BrushStyle at 12,
    /// ColorRef at 16, BrushHatch at 20.
    private static func createBrushRecord(_ p: CreateBrushPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendUInt32(p.ihBrush)
        b.appendUInt32(p.style)
        b.appendColorRef(p.color)
        b.appendUInt32(p.hatch)
        return try wrap(39, b)
    }

    /// EMR_EXTCREATEPEN §2.3.7.9: ihPen at 8; the DIB bookkeeping
    /// offBmi/cbBmi/offBits/cbBits at 12–28 (written back verbatim — a
    /// pattern-DIB pen re-emits via passthrough, see `isFaithfullyEncodable`);
    /// LogPenEx §2.2.20 at 28 (PenStyle, Width u32, BrushStyle, ColorRef,
    /// BrushHatch, NumStyleEntries) then the style array at 52.
    private static func extCreatePenRecord(_ p: ExtCreatePenPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendUInt32(p.ihPen)
        b.appendUInt32(p.offBmi)
        b.appendUInt32(p.cbBmi)
        b.appendUInt32(p.offBits)
        b.appendUInt32(p.cbBits)
        b.appendUInt32(p.style)
        b.appendUInt32(p.width)
        b.appendUInt32(p.brushStyle)
        b.appendColorRef(p.color)
        b.appendUInt32(p.brushHatch)
        b.appendUInt32(UInt32(clamping: p.styleEntries.count))
        for entry in p.styleEntries {
            b.appendUInt32(entry)
        }
        return try wrap(95, b)
    }

    // MARK: - Clipping region

    /// EMR_EXTSELECTCLIPRGN §2.3.2.2: RgnDataSize u32 at 8, RegionMode u32 at
    /// 12, then the RegionData (§2.2.24). The RGN_COPY reset form (bounds nil,
    /// no rects) writes RgnDataSize 0 and no region data; otherwise a 32-byte
    /// RegionDataHeader (§2.2.25: Size 0x20, Type RDH_RECTANGLES 0x01,
    /// CountRects, RgnSize = CountRects×16, Bounds) followed by the rectangles.
    private static func extSelectClipRgnRecord(
        _ p: ExtSelectClipRgnPayload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        guard let bounds = p.bounds else {
            // Reset form: no region data at all.
            b.appendUInt32(0)                               // RgnDataSize
            b.appendUInt32(regionModeRaw(p.mode))           // RegionMode
            return try wrap(75, b)
        }
        let countRects = p.rects.count
        let rgnDataSize = 32 + countRects * 16
        b.appendUInt32(UInt32(clamping: rgnDataSize))       // @8  RgnDataSize
        b.appendUInt32(regionModeRaw(p.mode))               // @12 RegionMode
        b.appendUInt32(0x20)                                // @16 Header Size
        b.appendUInt32(0x01)                                // @20 Type RDH_RECTANGLES
        b.appendUInt32(UInt32(clamping: countRects))        // @24 CountRects
        b.appendUInt32(UInt32(clamping: countRects * 16))   // @28 RgnSize (rects only)
        b.appendRectL(bounds)                               // @32 Bounds
        for rect in p.rects {                               // @48 rectangles
            b.appendRectL(rect)
        }
        return try wrap(75, b)
    }

    // MARK: - Geometry arrays

    /// EMR_POLY* 32-bit (§2.3.5.16/.18/.22/.24/.26): Bounds RectL at 8, Count
    /// u32 at 24, then Count PointL values at 28.
    private static func poly32Record(
        _ type: UInt32,
        _ p: PolyPointsPayload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.bounds)
        b.appendUInt32(UInt32(clamping: p.points.count))
        for point in p.points {
            b.appendPointL(point)
        }
        return try wrap(type, b)
    }

    /// EMR_POLY*16 (§2.3.5.17/.19/.23/.25/.27): as the 32-bit family but with
    /// 4-byte PointS elements.
    private static func poly16Record(
        _ type: UInt32,
        _ p: Poly16PointsPayload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.bounds)
        b.appendUInt32(UInt32(clamping: p.points.count))
        for point in p.points {
            b.appendPointS(point)
        }
        return try wrap(type, b)
    }

    /// EMR_POLYPOLYLINE16 §2.3.5.31 / EMR_POLYPOLYGON16 §2.3.5.29: Bounds at 8,
    /// NumberOfPolys u32 at 24, Count u32 (total points) at 28, the per-poly
    /// u32 count array at 32, then the PointS values.
    private static func polyPoly16Record(
        _ type: UInt32,
        _ p: PolyPoly16Payload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.bounds)
        b.appendUInt32(UInt32(clamping: p.pointCounts.count))
        b.appendUInt32(UInt32(clamping: p.points.count))
        for count in p.pointCounts {
            b.appendUInt32(count)
        }
        for point in p.points {
            b.appendPointS(point)
        }
        return try wrap(type, b)
    }

    /// EMR_POLYPOLYLINE §2.3.5.30 / EMR_POLYPOLYGON §2.3.5.28 — the 32-bit
    /// analogue: Bounds, NumberOfPolys, total Count, the u32 count array, then
    /// the PointL (8-byte) values.
    private static func polyPoly32Record(
        _ type: UInt32,
        _ p: PolyPoly32Payload
    ) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendRectL(p.bounds)
        b.appendUInt32(UInt32(clamping: p.pointCounts.count))
        b.appendUInt32(UInt32(clamping: p.points.count))
        for count in p.pointCounts {
            b.appendUInt32(count)
        }
        for point in p.points {
            b.appendPointL(point)
        }
        return try wrap(type, b)
    }

    // MARK: - Text

    /// EMR_EXTCREATEFONTINDIRECTW §2.3.7.8: ihFonts u32 at 8, then a 92-byte
    /// LogFont (§2.2.13) at 12 — the common prefix of every `elw` variant. Only
    /// the plain LogFont is retained by the decoder, so the record is a fixed
    /// 104 bytes; a font whose original `elw` carried extended data re-emits via
    /// passthrough (see `isFaithfullyEncodable`).
    private static func extCreateFontRecord(_ p: ExtCreateFontPayload) throws(EMFWriteError) -> Data {
        var b = ByteWriter()
        b.appendUInt32(p.ihFonts)
        try appendLogFont(&b, p.logFont)
        return try wrap(82, b)
    }

    /// The 92-byte LogFont ([MS-EMF] §2.2.13): five i32s, eight u8s, then a
    /// 64-byte (32 UTF-16LE code unit) FaceName. A name shorter than 32 units is
    /// NUL-terminated then zero-padded; a 32-unit name fills the field with no
    /// terminator (§2.2.13).
    private static func appendLogFont(_ b: inout ByteWriter, _ font: LogFont) throws(EMFWriteError) {
        b.appendInt32(font.height)
        b.appendInt32(font.width)
        b.appendInt32(font.escapement)
        b.appendInt32(font.orientation)
        b.appendInt32(font.weight)
        b.appendUInt8(font.italic)
        b.appendUInt8(font.underline)
        b.appendUInt8(font.strikeOut)
        b.appendUInt8(font.charSet)
        b.appendUInt8(font.outPrecision)
        b.appendUInt8(font.clipPrecision)
        b.appendUInt8(font.quality)
        b.appendUInt8(font.pitchAndFamily)
        appendFaceName(&b, font.faceName, codeUnits: 32)
    }

    /// Writes exactly `codeUnits` UTF-16LE units (2×`codeUnits` bytes) of a
    /// NUL-terminable name: the name's units (clamped to the field), a NUL when
    /// there is room, then zero padding.
    private static func appendFaceName(_ b: inout ByteWriter, _ name: String, codeUnits: Int) {
        let units = Array(name.utf16.prefix(codeUnits))
        for unit in units {
            b.appendUInt16(unit)
        }
        // Remaining units are the terminator/padding (all zero).
        let remaining = codeUnits - units.count
        if remaining > 0 {
            b.appendZeros(remaining * 2)
        }
    }

    /// EMR_EXTTEXTOUTW §2.3.5.8: Bounds RectL at 8 (ignored on receipt, written
    /// as zero), iGraphicsMode at 24, exScale/eyScale at 28/32, then the EmrText
    /// object (§2.2.5): Reference at 36, Chars at 44, offString at 48, Options
    /// at 52, Rectangle at 56, offDx at 72. The string is placed at the
    /// canonical offString = 76, and the Dx array (if any) 4-aligned after it.
    private static func extTextOutWRecord(_ p: ExtTextPayload) throws(EMFWriteError) -> Data {
        let units = Array(p.string.utf16)
        let chars = units.count
        let stringBytes = chars * 2   // Int (64-bit): chars is an array count, no overflow

        // Canonical layout: fixed part ends at record offset 76; the string
        // sits there, then the Dx array (4-aligned) if present.
        let offString = 76
        let padAfterString = (4 - (stringBytes % 4)) % 4
        let hasDx = p.dx != nil
        let offDx = hasDx ? offString + stringBytes + padAfterString : 0
        let dxBytes = (p.dx?.count ?? 0) * 4
        // Guard the record's full extent before any UInt32 field (Chars,
        // offString, offDx) is written — bounds stringBytes (hence Chars) and
        // offDx so none of the conversions can trap (§8).
        let maxExtent = offString + stringBytes + (hasDx ? padAfterString + dxBytes : 0)
        guard maxExtent <= Int(UInt32.max) else {
            throw .stringTooLong(recordType: 84, codeUnits: chars)
        }

        var b = ByteWriter()
        b.appendRectL(RectL(left: 0, top: 0, right: 0, bottom: 0))  // @8  Bounds (ignored)
        b.appendUInt32(p.graphicsMode)                              // @24 iGraphicsMode
        b.appendFloat(p.exScale)                                    // @28 exScale
        b.appendFloat(p.eyScale)                                    // @32 eyScale
        b.appendPointL(p.reference)                                 // @36 Reference
        b.appendUInt32(UInt32(chars))                              // @44 Chars
        b.appendUInt32(UInt32(offString))                          // @48 offString
        b.appendUInt32(p.options.rawValue)                         // @52 Options
        b.appendRectL(p.rectangle)                                 // @56 Rectangle
        b.appendUInt32(UInt32(offDx))                             // @72 offDx
        // @76 the string, then any Dx array.
        for unit in units {
            b.appendUInt16(unit)
        }
        if let dx = p.dx {
            b.appendZeros(padAfterString)
            for value in dx {
                b.appendUInt32(value)
            }
        }
        return try wrap(84, b)
    }

    // MARK: - Bitmaps

    /// EMR_STRETCHDIBITS §2.3.1.7: fixed part 80 bytes, then the DIB (BMI at
    /// offBmi = 80, bits right after). A sourceless (`dib == nil`) record writes
    /// zero DIB offsets/sizes and ends at 80.
    private static func stretchDIBitsRecord(_ p: StretchDIBitsPayload) throws(EMFWriteError) -> Data {
        let serial = p.dib.flatMap(serializeDIB)
        let bmi = serial?.bmi ?? []
        let bits = serial?.bits ?? []
        let hasDIB = serial != nil
        let offBmi: UInt32 = hasDIB ? 80 : 0
        let offBits: UInt32 = hasDIB ? UInt32(clamping: 80 + bmi.count) : 0

        var b = ByteWriter()
        b.appendRectL(p.bounds)                        // @8
        b.appendInt32(p.dest.x)                        // @24 xDest
        b.appendInt32(p.dest.y)                        // @28 yDest
        b.appendInt32(p.src.x)                         // @32 xSrc
        b.appendInt32(p.src.y)                         // @36 ySrc
        b.appendInt32(p.srcSize.cx)                    // @40 cxSrc
        b.appendInt32(p.srcSize.cy)                    // @44 cySrc
        b.appendUInt32(offBmi)                         // @48 offBmiSrc
        b.appendUInt32(UInt32(clamping: bmi.count))    // @52 cbBmiSrc
        b.appendUInt32(offBits)                        // @56 offBitsSrc
        b.appendUInt32(UInt32(clamping: bits.count))   // @60 cbBitsSrc
        b.appendUInt32(p.usageSrc)                     // @64 UsageSrc
        b.appendUInt32(p.rasterOperation)              // @68 BitBltRasterOperation
        b.appendInt32(p.destSize.cx)                   // @72 cxDest
        b.appendInt32(p.destSize.cy)                   // @76 cyDest
        b.appendBytes(bmi)                             // @80 DIB header
        b.appendBytes(bits)                            // DIB bits
        return try wrap(81, b)
    }

    /// EMR_SETDIBITSTODEVICE §2.3.1.5: fixed part 76 bytes, then the DIB (BMI at
    /// offBmi = 76). No raster op, no source transform.
    private static func setDIBitsToDeviceRecord(_ p: SetDIBitsToDevicePayload) throws(EMFWriteError) -> Data {
        let serial = p.dib.flatMap(serializeDIB)
        let bmi = serial?.bmi ?? []
        let bits = serial?.bits ?? []
        let hasDIB = serial != nil
        let offBmi: UInt32 = hasDIB ? 76 : 0
        let offBits: UInt32 = hasDIB ? UInt32(clamping: 76 + bmi.count) : 0

        var b = ByteWriter()
        b.appendRectL(p.bounds)                        // @8
        b.appendInt32(p.dest.x)                        // @24 xDest
        b.appendInt32(p.dest.y)                        // @28 yDest
        b.appendInt32(p.src.x)                         // @32 xSrc
        b.appendInt32(p.src.y)                         // @36 ySrc
        b.appendInt32(p.srcSize.cx)                    // @40 cxSrc
        b.appendInt32(p.srcSize.cy)                    // @44 cySrc
        b.appendUInt32(offBmi)                         // @48 offBmiSrc
        b.appendUInt32(UInt32(clamping: bmi.count))    // @52 cbBmiSrc
        b.appendUInt32(offBits)                        // @56 offBitsSrc
        b.appendUInt32(UInt32(clamping: bits.count))   // @60 cbBitsSrc
        b.appendUInt32(p.usageSrc)                     // @64 UsageSrc
        b.appendUInt32(p.startScan)                    // @68 iStartScan
        b.appendUInt32(p.scanCount)                    // @72 cScans
        b.appendBytes(bmi)                             // @76 DIB header
        b.appendBytes(bits)                            // DIB bits
        return try wrap(80, b)
    }

    /// EMR_BITBLT §2.3.1.2 (fixed 100) and EMR_STRETCHBLT §2.3.1.6 (fixed 108 =
    /// BITBLT + cxSrc/cySrc). The DIB (if any) follows the fixed part.
    private static func bitBltRecord(
        _ p: BitBltPayload,
        type: UInt32,
        stretch: Bool
    ) throws(EMFWriteError) -> Data {
        let fixedSize = stretch ? 108 : 100
        let serial = p.dib.flatMap(serializeDIB)
        let bmi = serial?.bmi ?? []
        let bits = serial?.bits ?? []
        let hasDIB = serial != nil
        let offBmi: UInt32 = hasDIB ? UInt32(fixedSize) : 0
        let offBits: UInt32 = hasDIB ? UInt32(clamping: fixedSize + bmi.count) : 0

        var b = ByteWriter()
        b.appendRectL(p.bounds)                        // @8
        b.appendInt32(p.dest.x)                        // @24 xDest
        b.appendInt32(p.dest.y)                        // @28 yDest
        b.appendInt32(p.destSize.cx)                   // @32 cxDest
        b.appendInt32(p.destSize.cy)                   // @36 cyDest
        b.appendUInt32(p.rasterOperation)              // @40 BitBltRasterOperation
        b.appendInt32(p.src.x)                         // @44 xSrc
        b.appendInt32(p.src.y)                         // @48 ySrc
        b.appendXForm(p.xformSrc)                      // @52 XformSrc (24 bytes)
        b.appendColorRef(p.bkColorSrc)                 // @76 BkColorSrc
        b.appendUInt32(p.usageSrc)                     // @80 UsageSrc
        b.appendUInt32(offBmi)                         // @84 offBmiSrc
        b.appendUInt32(UInt32(clamping: bmi.count))    // @88 cbBmiSrc
        b.appendUInt32(offBits)                        // @92 offBitsSrc
        b.appendUInt32(UInt32(clamping: bits.count))   // @96 cbBitsSrc
        if stretch {
            let srcSize = p.srcSize ?? SizeL(cx: 0, cy: 0)
            b.appendInt32(srcSize.cx)                  // @100 cxSrc
            b.appendInt32(srcSize.cy)                  // @104 cySrc
        }
        b.appendBytes(bmi)                             // DIB header
        b.appendBytes(bits)                            // DIB bits
        return try wrap(type, b)
    }

    /// Serialises a `.pixels` DIB to a canonical 40-byte BITMAPINFOHEADER
    /// ([MS-WMF] §2.2.2.3) plus its color table and pixel bytes. Returns nil for
    /// `.unsupported` content (pixel bytes were never retained; the caller
    /// re-emits the original record instead). The decoder reads Width/Height/
    /// BitCount/Compression and sizes the palette and pixel block from these, so
    /// this header makes the DIB a decode fixed point. Planes = 1,
    /// XPelsPerMeter/YPelsPerMeter = 0, ClrUsed = palette count, ClrImportant = 0.
    /// Internal (not private) so the WMF STRETCHDIB encoder reuses the identical
    /// packed-DIB form — EMR_STRETCHDIBITS and META_STRETCHDIB carry the same
    /// DeviceIndependentBitmap object ([MS-WMF] §2.2.2.9).
    static func serializeDIB(_ dib: DIB) -> (bmi: [UInt8], bits: [UInt8])? {
        guard case .pixels(let pixelBytes, _, let palette) = dib.content else {
            return nil
        }
        var bmi = ByteWriter()
        bmi.appendUInt32(40)                                   // HeaderSize
        bmi.appendInt32(dib.width)                             // Width
        bmi.appendInt32(dib.height)                            // Height (signed)
        bmi.appendUInt16(1)                                    // Planes
        bmi.appendUInt16(dib.bitCount)                         // BitCount
        bmi.appendUInt32(compressionRaw(dib.compression))     // Compression
        bmi.appendUInt32(UInt32(clamping: pixelBytes.count))  // SizeImage
        bmi.appendInt32(0)                                     // XPelsPerMeter
        bmi.appendInt32(0)                                     // YPelsPerMeter
        bmi.appendUInt32(UInt32(clamping: palette.count))     // ClrUsed
        bmi.appendUInt32(0)                                    // ClrImportant
        for quad in palette {                                 // RGBQuad: B,G,R,X
            bmi.appendUInt8(quad.blue)
            bmi.appendUInt8(quad.green)
            bmi.appendUInt8(quad.red)
            bmi.appendUInt8(quad.reserved)
        }
        return (bmi.bytes, [UInt8](pixelBytes))
    }

    // MARK: - Enum → raw inversions
    //
    // These invert the `init(_ raw:)` mappings in PayloadTypes.swift. `.unknown`
    // / `.unknownStock` carry the original raw value and round-trip it exactly.

    private static func mapModeRaw(_ mode: MapMode) -> UInt32 {
        switch mode {
        case .text: return 0x01
        case .loMetric: return 0x02
        case .hiMetric: return 0x03
        case .loEnglish: return 0x04
        case .hiEnglish: return 0x05
        case .twips: return 0x06
        case .isotropic: return 0x07
        case .anisotropic: return 0x08
        case .unknown(let raw): return raw
        }
    }

    private static func backgroundModeRaw(_ mode: BackgroundMode) -> UInt32 {
        switch mode {
        case .transparent: return 0x0001
        case .opaque: return 0x0002
        case .unknown(let raw): return raw
        }
    }

    private static func polyFillModeRaw(_ mode: PolygonFillMode) -> UInt32 {
        switch mode {
        case .alternate: return 0x01
        case .winding: return 0x02
        case .unknown(let raw): return raw
        }
    }

    private static func stretchBltModeRaw(_ mode: StretchBltMode) -> UInt32 {
        switch mode {
        case .blackOnWhite: return 0x01
        case .whiteOnBlack: return 0x02
        case .colorOnColor: return 0x03
        case .halftone: return 0x04
        case .unknown(let raw): return raw
        }
    }

    private static func arcDirectionRaw(_ direction: ArcDirection) -> UInt32 {
        switch direction {
        case .counterclockwise: return 0x0000_0001
        case .clockwise: return 0x0000_0002
        case .unknown(let raw): return raw
        }
    }

    private static func modifyModeRaw(_ mode: ModifyWorldTransformMode) -> UInt32 {
        switch mode {
        case .identity: return 0x01
        case .leftMultiply: return 0x02
        case .rightMultiply: return 0x03
        case .set: return 0x04
        case .unknown(let raw): return raw
        }
    }

    private static func regionModeRaw(_ mode: RegionMode) -> UInt32 {
        switch mode {
        case .and: return 0x01
        case .or: return 0x02
        case .xor: return 0x03
        case .diff: return 0x04
        case .copy: return 0x05
        case .unknown(let raw): return raw
        }
    }

    private static func objectHandleRaw(_ handle: ObjectHandle) -> UInt32 {
        switch handle {
        case .table(let index): return index
        case .stock(let stock): return stockObjectRaw(stock)
        }
    }

    private static func stockObjectRaw(_ stock: StockObject) -> UInt32 {
        switch stock {
        case .whiteBrush: return 0x8000_0000
        case .ltGrayBrush: return 0x8000_0001
        case .grayBrush: return 0x8000_0002
        case .dkGrayBrush: return 0x8000_0003
        case .blackBrush: return 0x8000_0004
        case .nullBrush: return 0x8000_0005
        case .whitePen: return 0x8000_0006
        case .blackPen: return 0x8000_0007
        case .nullPen: return 0x8000_0008
        case .oemFixedFont: return 0x8000_000A
        case .ansiFixedFont: return 0x8000_000B
        case .ansiVarFont: return 0x8000_000C
        case .systemFont: return 0x8000_000D
        case .deviceDefaultFont: return 0x8000_000E
        case .defaultPalette: return 0x8000_000F
        case .systemFixedFont: return 0x8000_0010
        case .defaultGuiFont: return 0x8000_0011
        case .dcBrush: return 0x8000_0012
        case .dcPen: return 0x8000_0013
        case .unknownStock(let raw): return raw
        }
    }

    private static func compressionRaw(_ compression: BitmapCompression) -> UInt32 {
        switch compression {
        case .rgb: return 0x0000
        case .rle8: return 0x0001
        case .rle4: return 0x0002
        case .bitfields: return 0x0003
        case .jpeg: return 0x0004
        case .png: return 0x0005
        case .other(let raw): return raw
        }
    }
}
