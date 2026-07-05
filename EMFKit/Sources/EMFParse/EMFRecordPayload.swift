import Foundation

/// Why a record's payload failed its own validation. Carried by
/// `EMFRecordPayload.malformed`; never thrown, never fatal to the file.
public enum EMFPayloadIssue: Sendable, Equatable {
    /// The record's `nSize` is below the fixed minimum for its type.
    case tooSmall(minimumSize: Int, actualSize: Int)
    /// A declared element count does not fit in the record's own bytes
    /// (a lying count — the classic overallocation attack).
    case countTooLarge(declared: Int, maxFitting: Int)
    /// A poly-poly record whose per-polygon counts do not sum to its
    /// declared total point count.
    case countMismatch(declaredTotal: Int, sumOfCounts: Int)
    /// An XForm contained NaN or infinity ([MS-EMF] §2.2.28 FLOAT fields;
    /// hostile floats are rejected at the decode boundary).
    case nonFiniteTransform
    /// A RegionDataHeader ([MS-EMF] §2.2.25) whose `Size` or `Type` field is
    /// not the required constant (Size MUST be 0x20, Type MUST be
    /// RDH_RECTANGLES = 0x01). Carries the offending values as read.
    case badRegionHeader(size: UInt32, type: UInt32)
    /// An EmrText or DIB byte range (offString / offDx / offBmiSrc / offBitsSrc
    /// and its length) did not fit inside the record's own `nSize`. Carries the
    /// offending offset and length as read.
    case rangeOutOfBounds(offset: Int, length: Int, recordSize: Int)
    /// A DIB's declared pixel dimensions were non-positive, exceeded the
    /// per-side or total-area caps, or the required pixel bytes were larger
    /// than the bytes actually present. Carries width and height as read.
    case badBitmapDimensions(width: Int, height: Int)
    /// A BitmapInfoHeader whose HeaderSize field is below the 40-byte minimum
    /// ([MS-WMF] §2.2.2.3). Carries the value as read.
    case badBitmapHeader(headerSize: UInt32)
}

/// Common payload of the single-polygon 32-bit geometry records
/// (EMR_POLYBEZIER/POLYGON/POLYLINE/POLYBEZIERTO/POLYLINETO,
/// [MS-EMF] §2.3.5.16/.22/.24/.18/.26): a bounding rectangle, a 32-bit
/// point count, then `Count` PointL values.
public struct PolyPointsPayload: Sendable, Equatable {
    /// Bounding rectangle in logical units.
    public var bounds: RectL
    /// The record's points, in logical units.
    public var points: [PointL]

    public init(bounds: RectL, points: [PointL]) {
        self.bounds = bounds
        self.points = points
    }
}

/// Common payload of the single-polygon 16-bit geometry records
/// (EMR_POLYBEZIER16/POLYGON16/POLYLINE16/POLYBEZIERTO16/POLYLINETO16,
/// [MS-EMF] §2.3.5.17/.23/.25/.19/.27): same shape as the 32-bit family but
/// with PointS (2×Int16, 4 bytes) elements.
public struct Poly16PointsPayload: Sendable, Equatable {
    public var bounds: RectL
    public var points: [PointS]

    public init(bounds: RectL, points: [PointS]) {
        self.bounds = bounds
        self.points = points
    }
}

/// Payload of EMR_POLYPOLYLINE16 / EMR_POLYPOLYGON16 ([MS-EMF]
/// §2.3.5.31 / §2.3.5.29): Bounds, NumberOfPolys (u32), Count (u32, total
/// points), a NumberOfPolys-length u32 count array, then Count PointS values.
/// Decoding guarantees `pointCounts` sums exactly to `points.count`.
public struct PolyPoly16Payload: Sendable, Equatable {
    public var bounds: RectL
    /// Points per sub-polyline/polygon, in file order.
    public var pointCounts: [UInt32]
    /// All points, concatenated in sub-polygon order.
    public var points: [PointS]

    public init(bounds: RectL, pointCounts: [UInt32], points: [PointS]) {
        self.bounds = bounds
        self.pointCounts = pointCounts
        self.points = points
    }
}

/// Payload of EMR_ROUNDRECT ([MS-EMF] §2.3.5.35): the inclusive-inclusive
/// box and the width/height of the corner-rounding ellipse.
public struct RoundRectPayload: Sendable, Equatable {
    public var box: RectL
    public var corner: SizeL

    public init(box: RectL, corner: SizeL) {
        self.box = box
        self.corner = corner
    }
}

/// Payload of EMR_ARC ([MS-EMF] §2.3.5.2): the inclusive-inclusive bounding
/// box of the ellipse plus the radial endpoints defining the arc's start
/// and end.
public struct ArcPayload: Sendable, Equatable {
    public var box: RectL
    public var start: PointL
    public var end: PointL

    public init(box: RectL, start: PointL, end: PointL) {
        self.box = box
        self.start = start
        self.end = end
    }
}

/// Payload of EMR_MODIFYWORLDTRANSFORM ([MS-EMF] §2.3.12.1): an XForm
/// followed by the ModifyWorldTransformMode saying how to combine it with
/// the current transform.
public struct ModifyWorldTransformPayload: Sendable, Equatable {
    public var transform: XForm
    public var mode: ModifyWorldTransformMode

    public init(transform: XForm, mode: ModifyWorldTransformMode) {
        self.transform = transform
        self.mode = mode
    }
}

/// Payload of EMR_CREATEPEN ([MS-EMF] §2.3.7.7): the object-table index and
/// the LogPen object ([MS-EMF] §2.2.19). Per the spec, only `width.x` is
/// meaningful — `width.y` MUST be ignored.
public struct CreatePenPayload: Sendable, Equatable {
    /// Object-table index this pen is assigned to.
    public var ihPen: UInt32
    /// PenStyle enumeration bits ([MS-EMF] §2.1.25).
    public var style: UInt32
    /// Pen width; only the x field is used ([MS-EMF] §2.2.19).
    public var width: PointL
    public var color: ColorRef

    public init(ihPen: UInt32, style: UInt32, width: PointL, color: ColorRef) {
        self.ihPen = ihPen
        self.style = style
        self.width = width
        self.color = color
    }
}

/// Payload of EMR_EXTCREATEPEN ([MS-EMF] §2.3.7.9): the object-table index,
/// the optional-DIB bookkeeping fields, and the LogPenEx object
/// ([MS-EMF] §2.2.20) including its user-style array.
///
/// The DIB fields (`offBmi`/`cbBmi`/`offBits`/`cbBits`) are carried raw and
/// NOT dereferenced in phase 2 — pattern-brush DIB decoding is phase 4.
/// Only the style-entry array, which this decoder allocates, is validated
/// against the record size.
public struct ExtCreatePenPayload: Sendable, Equatable {
    public var ihPen: UInt32
    /// Offset from record start to the DIB header, 0 if none. Not decoded.
    public var offBmi: UInt32
    /// Size of the DIB header, 0 if none. Not decoded.
    public var cbBmi: UInt32
    /// Offset from record start to the DIB bits, 0 if none. Not decoded.
    public var offBits: UInt32
    /// Size of the DIB bits, 0 if none. Not decoded.
    public var cbBits: UInt32
    /// PenStyle enumeration bits ([MS-EMF] §2.1.25).
    public var style: UInt32
    /// Width as a single unsigned value ([MS-EMF] §2.2.20 — unlike LogPen's
    /// PointL width).
    public var width: UInt32
    /// BrushStyle enumeration ([MS-WMF] §2.1.1.4).
    public var brushStyle: UInt32
    public var color: ColorRef
    /// Interpretation depends on `brushStyle` ([MS-EMF] §2.2.20).
    public var brushHatch: UInt32
    /// PS_USERSTYLE dash/gap lengths; empty unless the pen uses a style array.
    public var styleEntries: [UInt32]

    public init(
        ihPen: UInt32,
        offBmi: UInt32,
        cbBmi: UInt32,
        offBits: UInt32,
        cbBits: UInt32,
        style: UInt32,
        width: UInt32,
        brushStyle: UInt32,
        color: ColorRef,
        brushHatch: UInt32,
        styleEntries: [UInt32]
    ) {
        self.ihPen = ihPen
        self.offBmi = offBmi
        self.cbBmi = cbBmi
        self.offBits = offBits
        self.cbBits = cbBits
        self.style = style
        self.width = width
        self.brushStyle = brushStyle
        self.color = color
        self.brushHatch = brushHatch
        self.styleEntries = styleEntries
    }
}

/// Payload of EMR_CREATEBRUSHINDIRECT ([MS-EMF] §2.3.7.1): the object-table
/// index and the LogBrushEx object ([MS-EMF] §2.2.12).
public struct CreateBrushPayload: Sendable, Equatable {
    public var ihBrush: UInt32
    /// BrushStyle enumeration ([MS-WMF] §2.1.1.4); BS_SOLID, BS_HATCHED, or
    /// BS_NULL per §2.3.7.1.
    public var style: UInt32
    public var color: ColorRef
    /// Interpretation depends on `style` ([MS-EMF] §2.2.12).
    public var hatch: UInt32

    public init(ihBrush: UInt32, style: UInt32, color: ColorRef, hatch: UInt32) {
        self.ihBrush = ihBrush
        self.style = style
        self.color = color
        self.hatch = hatch
    }
}

/// Payload of EMR_EXTSELECTCLIPRGN ([MS-EMF] §2.3.2.2): the combination
/// mode and the region's rectangles, decoded from the RegionData object
/// ([MS-EMF] §2.2.24) that follows the RgnDataSize/RegionMode fields.
///
/// Two valid shapes:
/// - Normal: `mode` combines with the current clip and `rects` holds the
///   region's `CountRects` rectangles (validated to fit both `RgnDataSize`
///   and the record's own `nSize` before allocation); `bounds` is the
///   RegionDataHeader's bounding rectangle.
/// - Reset: `mode == .copy` with `RgnDataSize == 0` and no region data. Per
///   §2.3.2.2, this resets the clip to the default region; it decodes to an
///   empty `rects` array and a `nil` `bounds` — a VALID payload, not malformed.
public struct ExtSelectClipRgnPayload: Sendable, Equatable {
    /// How the region combines with the current clipping region.
    public var mode: RegionMode
    /// The RegionDataHeader bounds ([MS-EMF] §2.2.25); `nil` for the RGN_COPY
    /// reset form, which carries no region data.
    public var bounds: RectL?
    /// The region's rectangles ([MS-WMF] §2.2.2.19); empty for the reset form.
    public var rects: [RectL]

    public init(mode: RegionMode, bounds: RectL?, rects: [RectL]) {
        self.mode = mode
        self.bounds = bounds
        self.rects = rects
    }
}

/// Payload of EMR_EXTCREATEFONTINDIRECTW ([MS-EMF] §2.3.7.8): the object-table
/// index and the LogFont prefix of the record's `elw` font object.
///
/// The `elw` field is a LogFont (92 bytes), LogFontEx (348), LogFontExDv
/// (>348), or LogFontPanose (320) — the spec picks the type from `elw`'s size
/// (§2.3.7.8). All of them begin with the same 92-byte LogFont, so that prefix
/// is always decoded; `hasExtendedData` records whether more than a plain
/// LogFont followed (fullName/style/script + design vector), which phase 4
/// does not need and carries opaque.
public struct ExtCreateFontPayload: Sendable, Equatable {
    /// Object-table index this font is assigned to.
    public var ihFonts: UInt32
    /// The 92-byte LogFont prefix, common to every `elw` variant.
    public var logFont: LogFont
    /// True when `elw` was larger than a plain 92-byte LogFont — i.e. a
    /// LogFontEx / LogFontExDv / LogFontPanose whose extra fields are not
    /// decoded in phase 4.
    public var hasExtendedData: Bool

    public init(ihFonts: UInt32, logFont: LogFont, hasExtendedData: Bool) {
        self.ihFonts = ihFonts
        self.logFont = logFont
        self.hasExtendedData = hasExtendedData
    }
}

/// Payload of EMR_EXTTEXTOUTW ([MS-EMF] §2.3.5.8) with its EmrText object
/// (§2.2.5): where and how to draw a UTF-16LE string with the current font.
///
/// `string` is decoded from `Chars` UTF-16 code units at the record-relative
/// `offString`; lone surrogates decode losslessly (never fail the payload).
/// `dx` is present only when the record's `offDx` was non-zero — `Chars`
/// advances, or `2 × Chars` when ETO_PDY is set. All offsets and lengths were
/// validated against the record's `nSize` before this value existed.
public struct ExtTextPayload: Sendable, Equatable {
    /// The GraphicsMode value ([MS-EMF] §2.1.16); GM_COMPATIBLE (1) makes the
    /// scale factors meaningful.
    public var graphicsMode: UInt32
    /// X page→.01mm scale factor (finite; used only in GM_COMPATIBLE).
    public var exScale: Float
    /// Y page→.01mm scale factor (finite; used only in GM_COMPATIBLE).
    public var eyScale: Float
    /// EmrText.Reference — the text reference point, logical units.
    public var reference: PointL
    /// EmrText.Rectangle — clipping/opaquing rectangle, logical units.
    public var rectangle: RectL
    /// The decoded output string.
    public var string: String
    /// ExtTextOut option flags ([MS-EMF] §2.1.11).
    public var options: ExtTextOutOptions
    /// The intercharacter spacing array, logical units; `nil` when the record
    /// carried none (offDx == 0). When ETO_PDY is set it holds two values per
    /// character (dx, dy in that order).
    public var dx: [UInt32]?

    public init(
        graphicsMode: UInt32,
        exScale: Float,
        eyScale: Float,
        reference: PointL,
        rectangle: RectL,
        string: String,
        options: ExtTextOutOptions,
        dx: [UInt32]?
    ) {
        self.graphicsMode = graphicsMode
        self.exScale = exScale
        self.eyScale = eyScale
        self.reference = reference
        self.rectangle = rectangle
        self.string = string
        self.options = options
        self.dx = dx
    }
}

/// Payload of EMR_STRETCHDIBITS ([MS-EMF] §2.3.1.7): a stretched block
/// transfer of a source DIB into a destination rectangle under a raster op.
public struct StretchDIBitsPayload: Sendable, Equatable {
    public var bounds: RectL
    /// Destination upper-left, logical units.
    public var dest: PointL
    /// Destination size, logical units.
    public var destSize: SizeL
    /// Source upper-left, source pixels.
    public var src: PointL
    /// Source size, source pixels.
    public var srcSize: SizeL
    /// DIBColors usage ([MS-EMF] §2.1.9) for the color table.
    public var usageSrc: UInt32
    /// Ternary raster operation ([MS-WMF] §2.1.1.31); SRCCOPY is 0x00CC0020.
    public var rasterOperation: UInt32
    /// The source bitmap; `nil` exactly when the record declared none
    /// (cbBmiSrc == 0) — the valid rop-only (sourceless) form. Rare for
    /// STRETCHDIBITS but legal (§2.3.1.7), so a nil `dib` is never malformed.
    public var dib: DIB?

    public init(
        bounds: RectL,
        dest: PointL,
        destSize: SizeL,
        src: PointL,
        srcSize: SizeL,
        usageSrc: UInt32,
        rasterOperation: UInt32,
        dib: DIB?
    ) {
        self.bounds = bounds
        self.dest = dest
        self.destSize = destSize
        self.src = src
        self.srcSize = srcSize
        self.usageSrc = usageSrc
        self.rasterOperation = rasterOperation
        self.dib = dib
    }
}

/// Payload of EMR_SETDIBITSTODEVICE ([MS-EMF] §2.3.1.5): an unconditional
/// (no raster op) transfer of scanlines from a source DIB to the device.
public struct SetDIBitsToDevicePayload: Sendable, Equatable {
    public var bounds: RectL
    /// Destination upper-left, logical units.
    public var dest: PointL
    /// Source upper-left, source pixels.
    public var src: PointL
    /// Source size, source pixels.
    public var srcSize: SizeL
    /// DIBColors usage ([MS-EMF] §2.1.9).
    public var usageSrc: UInt32
    /// First scan line in the array.
    public var startScan: UInt32
    /// Number of scan lines.
    public var scanCount: UInt32
    /// The source bitmap; `nil` exactly when the record declared none
    /// (cbBmiSrc == 0). SETDIBITSTODEVICE has no raster op, so a nil `dib`
    /// leaves nothing to draw; it is a valid payload, never malformed.
    public var dib: DIB?

    public init(
        bounds: RectL,
        dest: PointL,
        src: PointL,
        srcSize: SizeL,
        usageSrc: UInt32,
        startScan: UInt32,
        scanCount: UInt32,
        dib: DIB?
    ) {
        self.bounds = bounds
        self.dest = dest
        self.src = src
        self.srcSize = srcSize
        self.usageSrc = usageSrc
        self.startScan = startScan
        self.scanCount = scanCount
        self.dib = dib
    }
}

/// Payload of EMR_BITBLT ([MS-EMF] §2.3.1.2) and EMR_STRETCHBLT
/// (§2.3.1.6): a (possibly stretched) block transfer under a raster op, with
/// a source-bitmap transform and background color.
///
/// Both records share this payload; STRETCHBLT additionally carries a source
/// size (`srcSize`), which is `nil` for BITBLT (whose source and destination
/// share the destination size). Per the spec, if the raster op needs no
/// source the DIB is omitted (`dib == nil`, `hasSource == false`) — a VALID
/// rop-only variant, not malformed.
public struct BitBltPayload: Sendable, Equatable {
    public var bounds: RectL
    /// Destination upper-left, logical units.
    public var dest: PointL
    /// Destination size, logical units.
    public var destSize: SizeL
    /// Ternary raster operation ([MS-WMF] §2.1.1.31).
    public var rasterOperation: UInt32
    /// Source upper-left, logical units.
    public var src: PointL
    /// World→page transform for the source bitmap ([MS-EMF] §2.2.28); finite.
    public var xformSrc: XForm
    /// Source-bitmap background color.
    public var bkColorSrc: ColorRef
    /// DIBColors usage ([MS-EMF] §2.1.9).
    public var usageSrc: UInt32
    /// Source size, logical units — STRETCHBLT only; `nil` for BITBLT.
    public var srcSize: SizeL?
    /// The source bitmap; `nil` when the record declared none (cbBmiSrc == 0),
    /// which is the valid rop-only (sourceless) form.
    public var dib: DIB?

    /// True when the record carried a source DIB (cbBmiSrc != 0). Distinguishes
    /// a sourceless rop-only blit from a source-carrying one.
    public var hasSource: Bool { dib != nil }

    public init(
        bounds: RectL,
        dest: PointL,
        destSize: SizeL,
        rasterOperation: UInt32,
        src: PointL,
        xformSrc: XForm,
        bkColorSrc: ColorRef,
        usageSrc: UInt32,
        srcSize: SizeL?,
        dib: DIB?
    ) {
        self.bounds = bounds
        self.dest = dest
        self.destSize = destSize
        self.rasterOperation = rasterOperation
        self.src = src
        self.xformSrc = xformSrc
        self.bkColorSrc = bkColorSrc
        self.usageSrc = usageSrc
        self.srcSize = srcSize
        self.dib = dib
    }
}

/// A decoded record payload — one case per decoded record type (phases 2–3),
/// plus `.unimplemented` for everything not yet decoded and `.malformed` for
/// payloads that fail their own validation.
///
/// Section references are [MS-EMF] v20240423. Every decoder validates its
/// counts and offsets against the record's own `nSize` before reading or
/// allocating (primer §8).
public enum EMFRecordPayload: Sendable, Equatable {
    // MARK: State ([MS-EMF] §2.3.11, §2.3.2.3)

    /// EMR_SETWINDOWEXTEX (9), §2.3.11.30. Window extent, logical units.
    case setWindowExtEx(extent: SizeL)
    /// EMR_SETWINDOWORGEX (10), §2.3.11.31. Window origin.
    case setWindowOrgEx(origin: PointL)
    /// EMR_SETVIEWPORTEXTEX (11), §2.3.11.28. Viewport extent, device units.
    case setViewportExtEx(extent: SizeL)
    /// EMR_SETVIEWPORTORGEX (12), §2.3.11.29. Viewport origin, device units.
    case setViewportOrgEx(origin: PointL)
    /// EMR_SETMAPMODE (17), §2.3.11.19.
    case setMapMode(MapMode)
    /// EMR_SETBKMODE (18), §2.3.11.11.
    case setBkMode(BackgroundMode)
    /// EMR_SETPOLYFILLMODE (19), §2.3.11.22.
    case setPolyFillMode(PolygonFillMode)
    /// EMR_SETROP2 (20), §2.3.11.23. Raw mode from the [MS-WMF] §2.1.1.2
    /// BinaryRasterOperation enumeration; R2_COPYPEN (0x0D) is the only mode
    /// the phase-2 renderer supports (primer D5) — exposure is raw so the
    /// renderer can log-and-skip the rest.
    case setROP2(rawMode: UInt32)
    /// EMR_SAVEDC (33), §2.3.11 (no parameters).
    case saveDC
    /// EMR_RESTOREDC (34), §2.3.11.6. Signed; MUST be negative per the spec
    /// (-1 = most recently saved state). Carried as decoded.
    case restoreDC(savedDC: Int32)
    /// EMR_SETWORLDTRANSFORM (35), §2.3.12.2.
    case setWorldTransform(XForm)
    /// EMR_MODIFYWORLDTRANSFORM (36), §2.3.12.1.
    case modifyWorldTransform(ModifyWorldTransformPayload)
    /// EMR_SETMITERLIMIT (58), §2.3.11.21. The spec defines MiterLimit as an
    /// UNSIGNED INTEGER — not the FLOAT that the GDI SetMiterLimit API takes.
    /// Decoded spec-literally as UInt32.
    case setMiterLimit(miterLimit: UInt32)
    /// EMR_INTERSECTCLIPRECT (30), §2.3.2.3. Decode-only in phase 2; the
    /// renderer defers clipping to phase 3.
    case intersectClipRect(clip: RectL)

    // MARK: Object creation / manipulation ([MS-EMF] §2.3.7, §2.3.8)

    /// EMR_CREATEPEN (38), §2.3.7.7.
    case createPen(CreatePenPayload)
    /// EMR_EXTCREATEPEN (95), §2.3.7.9.
    case extCreatePen(ExtCreatePenPayload)
    /// EMR_CREATEBRUSHINDIRECT (39), §2.3.7.1.
    case createBrushIndirect(CreateBrushPayload)
    /// EMR_SELECTOBJECT (37), §2.3.8.5.
    case selectObject(ObjectHandle)
    /// EMR_DELETEOBJECT (40), §2.3.8.3.
    case deleteObject(ObjectHandle)

    // MARK: Paths and clipping ([MS-EMF] §2.3.5, §2.3.2)

    /// EMR_BEGINPATH (59), §2.3.5.4 (listing) — opens a path bracket. No
    /// parameters (8-byte record).
    case beginPath
    /// EMR_ENDPATH (60) — closes the path bracket. No parameters.
    case endPath
    /// EMR_CLOSEFIGURE (61) — closes the open figure in the path bracket. No
    /// parameters.
    case closeFigure
    /// EMR_FILLPATH (62), §2.3.5.9. Fills the current path; `bounds` is the
    /// path's bounding rectangle in logical units.
    case fillPath(bounds: RectL)
    /// EMR_STROKEANDFILLPATH (63), §2.3.5.38.
    case strokeAndFillPath(bounds: RectL)
    /// EMR_STROKEPATH (64), §2.3.5.39.
    case strokePath(bounds: RectL)
    /// EMR_SELECTCLIPPATH (67), §2.3.2.5. Combines the current path bracket
    /// with the current clipping region using this mode.
    case selectClipPath(RegionMode)
    /// EMR_EXTSELECTCLIPRGN (75), §2.3.2.2.
    case extSelectClipRgn(ExtSelectClipRgnPayload)

    // MARK: 32-bit geometry ([MS-EMF] §2.3.5, §2.3.11.4)

    /// EMR_POLYBEZIER (2), §2.3.5.16.
    case polyBezier(PolyPointsPayload)
    /// EMR_POLYGON (3), §2.3.5.22.
    case polygon(PolyPointsPayload)
    /// EMR_POLYLINE (4), §2.3.5.24.
    case polyline(PolyPointsPayload)
    /// EMR_POLYBEZIERTO (5), §2.3.5.18.
    case polyBezierTo(PolyPointsPayload)
    /// EMR_POLYLINETO (6), §2.3.5.26.
    case polylineTo(PolyPointsPayload)
    /// EMR_MOVETOEX (27), §2.3.11.4. New current position, logical units.
    case moveToEx(point: PointL)
    /// EMR_ELLIPSE (42), §2.3.5.5. Inclusive-inclusive bounding box.
    case ellipse(box: RectL)
    /// EMR_RECTANGLE (43), §2.3.5.34. Inclusive-inclusive box.
    case rectangle(box: RectL)
    /// EMR_ROUNDRECT (44), §2.3.5.35.
    case roundRect(RoundRectPayload)
    /// EMR_ARC (45), §2.3.5.2.
    case arc(ArcPayload)
    /// EMR_LINETO (54), §2.3.5.13. Line endpoint, logical units.
    case lineTo(point: PointL)

    // MARK: 16-bit geometry ([MS-EMF] §2.3.5)

    /// EMR_POLYBEZIER16 (85), §2.3.5.17.
    case polyBezier16(Poly16PointsPayload)
    /// EMR_POLYGON16 (86), §2.3.5.23.
    case polygon16(Poly16PointsPayload)
    /// EMR_POLYLINE16 (87), §2.3.5.25.
    case polyline16(Poly16PointsPayload)
    /// EMR_POLYBEZIERTO16 (88), §2.3.5.19.
    case polyBezierTo16(Poly16PointsPayload)
    /// EMR_POLYLINETO16 (89), §2.3.5.27.
    case polylineTo16(Poly16PointsPayload)
    /// EMR_POLYPOLYLINE16 (90), §2.3.5.31.
    case polyPolyline16(PolyPoly16Payload)
    /// EMR_POLYPOLYGON16 (91), §2.3.5.29.
    case polyPolygon16(PolyPoly16Payload)

    // MARK: Text ([MS-EMF] §2.3.11, §2.3.5.8, §2.3.7.8)

    /// EMR_SETTEXTALIGN (22), §2.3.11.25. Text alignment mask.
    case setTextAlign(TextAlign)
    /// EMR_SETTEXTCOLOR (24), §2.3.11.26. Text foreground color.
    case setTextColor(ColorRef)
    /// EMR_SETBKCOLOR (25), §2.3.11.10. Background color for text/hatch.
    case setBkColor(ColorRef)
    /// EMR_EXTCREATEFONTINDIRECTW (82), §2.3.7.8.
    case extCreateFontIndirectW(ExtCreateFontPayload)
    /// EMR_EXTTEXTOUTW (84), §2.3.5.8.
    case extTextOutW(ExtTextPayload)

    // MARK: Bitmaps ([MS-EMF] §2.3.1)

    /// EMR_STRETCHDIBITS (81), §2.3.1.7.
    case stretchDIBits(StretchDIBitsPayload)
    /// EMR_BITBLT (76), §2.3.1.2.
    case bitBlt(BitBltPayload)
    /// EMR_STRETCHBLT (77), §2.3.1.6. Shares BitBltPayload; `srcSize` is set.
    case stretchBlt(BitBltPayload)
    /// EMR_SETDIBITSTODEVICE (80), §2.3.1.5.
    case setDIBitsToDevice(SetDIBitsToDevicePayload)

    // MARK: Fallbacks

    /// Any record type outside the current decode set (including EMR_HEADER,
    /// which is decoded separately as `EMFFile.header`, and EMR_EOF).
    /// Log-and-skip: unknown is a verdict, not an error.
    case unimplemented(type: UInt32)
    /// The record's payload failed validation against its own `nSize` or
    /// carried a rejected value. The walk and all other records are
    /// unaffected.
    case malformed(type: UInt32, reason: EMFPayloadIssue)
}
