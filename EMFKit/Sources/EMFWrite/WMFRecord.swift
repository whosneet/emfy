import Foundation
import EMFParse

/// One typed WMF record an editor can emit — the write-side analogue of
/// EMFParse's `EMFRecordPayload`, but in WMF terms. Coordinates are carried in
/// the shared 32-bit logical types (`PointL`, `RectL`, `SizeL`) and narrowed to
/// the record's 16-bit on-disk fields by `WMFRecordEncoder`, which is the single
/// place every 16-bit narrowing is range-checked (primer §8). Colours are the
/// shared `ColorRef`; a font is the shared `LogFont`.
///
/// This enum covers exactly the records v3 plan §11.1's "WMF and WMZ writing"
/// needs an editor to produce. It is NOT a general WMF model: unknown or
/// unsupported records never reach here — a re-emit passes those through from the
/// source bytes (`WMFDocumentWriter.reEmit`). Each case cites its [MS-WMF]
/// section on the encoder; the record functions are [MS-WMF] §2.1.1.1.
public enum WMFRecord: Sendable, Equatable {
    // MARK: State (playback device-context settings)
    /// META_SAVEDC ([MS-WMF] §2.3.5.9).
    case saveDC
    /// META_RESTOREDC ([MS-WMF] §2.3.5.10): `savedDC` is the saved-instance
    /// selector (negative = relative, positive = absolute).
    case restoreDC(savedDC: Int16)
    /// META_SETBKMODE ([MS-WMF] §2.3.5.20): a MixMode value.
    case setBkMode(UInt16)
    /// META_SETMAPMODE ([MS-WMF] §2.3.5.17): a MapMode value.
    case setMapMode(UInt16)
    /// META_SETBKCOLOR ([MS-WMF] §2.3.5.14).
    case setBkColor(ColorRef)
    /// META_SETTEXTCOLOR ([MS-WMF] §2.3.5.26).
    case setTextColor(ColorRef)
    /// META_SETTEXTALIGN ([MS-WMF] §2.3.5.24): a TextAlignmentMode mask.
    case setTextAlign(UInt16)
    /// META_SETPOLYFILLMODE ([MS-WMF] §2.3.5.22): ALTERNATE (1) or WINDING (2).
    case setPolyFillMode(UInt16)
    /// META_SETROP2 ([MS-WMF] §2.3.5.23): a binary raster operation.
    case setROP2(UInt16)
    /// META_SETWINDOWORG ([MS-WMF] §2.3.5.31). Stored Y then X on disk.
    case setWindowOrg(PointL)
    /// META_SETWINDOWEXT ([MS-WMF] §2.3.5.30). Stored height then width on disk.
    case setWindowExt(SizeL)
    /// META_SETVIEWPORTORG ([MS-WMF] §2.3.5.29). Stored Y then X on disk.
    case setViewportOrg(PointL)
    /// META_SETVIEWPORTEXT ([MS-WMF] §2.3.5.28). Stored height then width on disk.
    case setViewportExt(SizeL)

    // MARK: Objects (the object table carries no index; slots are positional)
    /// META_CREATEPENINDIRECT ([MS-WMF] §2.3.4.5): a Pen Object (§2.2.1.4).
    /// `width` is the pen width (Pen.Width.x); `style` a PenStyle.
    case createPenIndirect(style: UInt16, width: Int32, color: ColorRef)
    /// META_CREATEBRUSHINDIRECT ([MS-WMF] §2.3.4.1): a LogBrush Object (§2.2.2.10).
    case createBrushIndirect(style: UInt16, color: ColorRef, hatch: UInt16)
    /// META_CREATEFONTINDIRECT ([MS-WMF] §2.3.4.2): a Font Object (§2.2.1.2). The
    /// shared `LogFont`'s 32-bit metrics narrow to the Font Object's Int16 fields.
    case createFontIndirect(LogFont)
    /// META_SELECTOBJECT ([MS-WMF] §2.3.4.10): selects the 0-based table slot, or
    /// a stock object when `index` has the 0x8000 bit set.
    case selectObject(index: UInt16)
    /// META_DELETEOBJECT ([MS-WMF] §2.3.4.7): frees the 0-based table slot.
    case deleteObject(index: UInt16)

    // MARK: Geometry
    /// META_MOVETO ([MS-WMF] §2.3.3.4). Stored Y then X on disk.
    case moveTo(PointL)
    /// META_LINETO ([MS-WMF] §2.3.3.10). Stored Y then X on disk.
    case lineTo(PointL)
    /// META_POLYLINE ([MS-WMF] §2.3.3.14): an open polyline.
    case polyline([PointL])
    /// META_POLYGON ([MS-WMF] §2.3.3.15): a closed, fillable polygon.
    case polygon([PointL])
    /// META_POLYPOLYGON ([MS-WMF] §2.3.3.16): one entry per polygon.
    case polyPolygon([[PointL]])
    /// META_RECTANGLE ([MS-WMF] §2.3.3.17). Stored Bottom, Right, Top, Left.
    case rectangle(RectL)
    /// META_ROUNDRECT ([MS-WMF] §2.3.3.18): `corner` is the full width/height of
    /// the rounding ellipse. Stored Height, Width, Bottom, Right, Top, Left.
    case roundRect(box: RectL, corner: SizeL)
    /// META_ELLIPSE ([MS-WMF] §2.3.3.3). Stored Bottom, Right, Top, Left.
    case ellipse(RectL)
    /// META_ARC ([MS-WMF] §2.3.3.1). Stored end, start, then the box (reversed).
    case arc(box: RectL, start: PointL, end: PointL)
    /// META_PIE ([MS-WMF] §2.3.3.13).
    case pie(box: RectL, start: PointL, end: PointL)
    /// META_CHORD ([MS-WMF] §2.3.3.2).
    case chord(box: RectL, start: PointL, end: PointL)

    // MARK: Text
    /// META_TEXTOUT ([MS-WMF] §2.3.3.20): an 8-bit string drawn at `point`. The
    /// string is encoded Latin-1 (lossy for code points above U+00FF).
    case textOut(point: PointL, string: String)
    /// META_EXTTEXTOUT ([MS-WMF] §2.3.3.5): an 8-bit string with optional
    /// opaque/clip `rectangle` (written when `options` sets ETO_OPAQUE 0x0002 or
    /// ETO_CLIPPED 0x0004) and an optional per-character advance array `dx`.
    case extTextOut(point: PointL, rectangle: RectL?, options: UInt16, string: String, dx: [Int16]?)

    // MARK: Bitmaps
    /// META_STRETCHDIB ([MS-WMF] §2.3.1.6): a stretched blit of a packed DIB.
    /// `colorUsage` is a ColorUsage value; `rop` a ternary raster operation.
    case stretchDIB(
        rop: UInt32,
        colorUsage: UInt16,
        src: PointL,
        srcSize: SizeL,
        dest: PointL,
        destSize: SizeL,
        dib: DIB
    )

    // MARK: Clipping
    /// META_INTERSECTCLIPRECT ([MS-WMF] §2.3.5.3). Stored Bottom, Right, Top, Left.
    case intersectClipRect(RectL)
    /// META_EXCLUDECLIPRECT ([MS-WMF] §2.3.5.2). Stored Bottom, Right, Top, Left.
    case excludeClipRect(RectL)

    // MARK: Escape
    /// META_ESCAPE ([MS-WMF] §2.3.6.1): a raw escape carrying `data` under
    /// `escapeFunction` (a MetafileEscapes value, §2.1.1.17).
    case escape(escapeFunction: UInt16, data: [UInt8])

    // MARK: Control
    /// META_EOF ([MS-WMF] §2.3.2.1): the trailing end-of-file record. The builder
    /// emits this itself; callers rarely need it.
    case eof
}
