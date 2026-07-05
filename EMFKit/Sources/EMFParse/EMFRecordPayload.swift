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

/// A decoded record payload — one case per phase-2 record type, plus
/// `.unimplemented` for everything not yet decoded and `.malformed` for
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

    // MARK: Fallbacks

    /// Any record type outside the phase-2 decode set (including EMR_HEADER,
    /// which is decoded separately as `EMFFile.header`, and EMR_EOF).
    /// Log-and-skip: unknown is a verdict, not an error.
    case unimplemented(type: UInt32)
    /// The record's payload failed validation against its own `nSize` or
    /// carried a rejected value. The walk and all other records are
    /// unaffected.
    case malformed(type: UInt32, reason: EMFPayloadIssue)
}
