import Foundation

/// A bounds-limited view over one record's bytes. All offsets are relative
/// to the RECORD START (matching the field tables in [MS-EMF] §2.3, which
/// count the 8-byte Type/Size header), and every read is checked against the
/// record's own extent — a decoder physically cannot read outside its record,
/// let alone the file (primer §8).
struct RecordSlice {
    private let reader: ByteReader
    /// Absolute offset of the record's first byte.
    private let base: Int
    /// Readable byte count from `base`, clamped to the buffer so even a
    /// fabricated `EMFRawRecord` cannot make reads escape the file.
    let size: Int

    init(reader: ByteReader, record: EMFRawRecord) {
        self.reader = reader
        let start = min(max(record.offset, 0), reader.count)
        self.base = start
        self.size = min(Int(record.size), reader.count - start)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= size - 4 else { return nil }
        return reader.readUInt32(at: base + offset)
    }

    func i32(_ offset: Int) -> Int32? {
        guard let raw = u32(offset) else { return nil }
        return Int32(bitPattern: raw)
    }

    func i16(_ offset: Int) -> Int16? {
        guard offset >= 0, offset <= size - 2 else { return nil }
        return reader.readInt16(at: base + offset)
    }

    /// Little-endian FLOAT via bit pattern ([MS-EMF] §2.2.28). May be
    /// non-finite; callers must check.
    func f32(_ offset: Int) -> Float? {
        guard let raw = u32(offset) else { return nil }
        return Float(bitPattern: raw)
    }

    /// ColorRef byte order per [MS-WMF] §2.2.2.8: Red, Green, Blue, Reserved.
    func colorRef(_ offset: Int) -> ColorRef? {
        guard offset >= 0, offset <= size - 4 else { return nil }
        guard let bytes = reader.data(at: base + offset, length: 4),
              bytes.count == 4
        else { return nil }
        return ColorRef(
            red: bytes[bytes.startIndex],
            green: bytes[bytes.startIndex + 1],
            blue: bytes[bytes.startIndex + 2],
            reserved: bytes[bytes.startIndex + 3]
        )
    }

    func pointL(_ offset: Int) -> PointL? {
        guard let x = i32(offset), let y = i32(offset + 4) else { return nil }
        return PointL(x: x, y: y)
    }

    func pointS(_ offset: Int) -> PointS? {
        guard let x = i16(offset), let y = i16(offset + 2) else { return nil }
        return PointS(x: x, y: y)
    }

    func sizeL(_ offset: Int) -> SizeL? {
        guard let cx = i32(offset), let cy = i32(offset + 4) else { return nil }
        return SizeL(cx: cx, cy: cy)
    }

    func rectL(_ offset: Int) -> RectL? {
        guard let left = i32(offset),
              let top = i32(offset + 4),
              let right = i32(offset + 8),
              let bottom = i32(offset + 12)
        else { return nil }
        return RectL(left: left, top: top, right: right, bottom: bottom)
    }

    /// Six FLOATs in file order M11, M12, M21, M22, Dx, Dy ([MS-EMF] §2.2.28).
    /// Returns nil on a short read; finiteness is the caller's check.
    func xform(_ offset: Int) -> XForm? {
        guard let m11 = f32(offset),
              let m12 = f32(offset + 4),
              let m21 = f32(offset + 8),
              let m22 = f32(offset + 12),
              let dx = f32(offset + 16),
              let dy = f32(offset + 20)
        else { return nil }
        return XForm(m11: m11, m12: m12, m21: m21, m22: m22, dx: dx, dy: dy)
    }

    /// Reads `count` PointL values (8 bytes each). The caller validates
    /// `count` against the record size first; this re-checks defensively and
    /// only allocates after the bounds hold.
    func pointsL(at offset: Int, count: Int) -> [PointL]? {
        guard count >= 0, offset >= 0, offset <= size,
              count <= (size - offset) / 8
        else { return nil }
        var points: [PointL] = []
        points.reserveCapacity(count)
        for index in 0 ..< count {
            guard let point = pointL(offset + index * 8) else { return nil }
            points.append(point)
        }
        return points
    }

    /// Reads `count` PointS values (4 bytes each), same contract as
    /// `pointsL(at:count:)`.
    func pointsS(at offset: Int, count: Int) -> [PointS]? {
        guard count >= 0, offset >= 0, offset <= size,
              count <= (size - offset) / 4
        else { return nil }
        var points: [PointS] = []
        points.reserveCapacity(count)
        for index in 0 ..< count {
            guard let point = pointS(offset + index * 4) else { return nil }
            points.append(point)
        }
        return points
    }

    /// Reads `count` UInt32 values, same contract as `pointsL(at:count:)`.
    func u32Array(at offset: Int, count: Int) -> [UInt32]? {
        guard count >= 0, offset >= 0, offset <= size,
              count <= (size - offset) / 4
        else { return nil }
        var values: [UInt32] = []
        values.reserveCapacity(count)
        for index in 0 ..< count {
            guard let value = u32(offset + index * 4) else { return nil }
            values.append(value)
        }
        return values
    }
}

extension EMFFile {
    /// Decodes the payload of one walked record, on demand.
    ///
    /// Access pattern (what EMFRender will do): iterate `records` in file
    /// order and call this once per record. Decoding is stateless and
    /// O(record size); results are not cached and no whole-file payload
    /// array is ever built, so `parse(_:)` cost is unchanged even for
    /// 276k-record files.
    ///
    /// Verdicts, never errors: types outside the current decode set —
    /// including EMR_HEADER (already decoded as `header`) and EMR_EOF —
    /// return `.unimplemented(type:)`; a payload that fails validation
    /// against its own `nSize` returns `.malformed(type:reason:)`. The
    /// record must be one of this file's `records`; a fabricated record is
    /// safe (every read is bounds-clamped) but its verdict is unspecified.
    public func payload(of record: EMFRawRecord) -> EMFRecordPayload {
        let slice = RecordSlice(reader: reader, record: record)
        return Self.decodePayload(type: record.type, slice: slice)
    }

    // MARK: - Dispatch

    private static func decodePayload(
        type: UInt32,
        slice: RecordSlice
    ) -> EMFRecordPayload {
        switch type {
        case 2: return decodePoly32(type: type, slice: slice, make: EMFRecordPayload.polyBezier)
        case 3: return decodePoly32(type: type, slice: slice, make: EMFRecordPayload.polygon)
        case 4: return decodePoly32(type: type, slice: slice, make: EMFRecordPayload.polyline)
        case 5: return decodePoly32(type: type, slice: slice, make: EMFRecordPayload.polyBezierTo)
        case 6: return decodePoly32(type: type, slice: slice, make: EMFRecordPayload.polylineTo)
        case 9: return decodeSizeL(type: type, slice: slice) { .setWindowExtEx(extent: $0) }
        case 10: return decodePointL(type: type, slice: slice) { .setWindowOrgEx(origin: $0) }
        case 11: return decodeSizeL(type: type, slice: slice) { .setViewportExtEx(extent: $0) }
        case 12: return decodePointL(type: type, slice: slice) { .setViewportOrgEx(origin: $0) }
        case 17: return decodeU32(type: type, slice: slice) { .setMapMode(MapMode($0)) }
        case 18: return decodeU32(type: type, slice: slice) { .setBkMode(BackgroundMode($0)) }
        case 19: return decodeU32(type: type, slice: slice) { .setPolyFillMode(PolygonFillMode($0)) }
        case 20: return decodeU32(type: type, slice: slice) { .setROP2(rawMode: $0) }
        case 27: return decodePointL(type: type, slice: slice) { .moveToEx(point: $0) }
        case 30: return decodeRectL(type: type, slice: slice) { .intersectClipRect(clip: $0) }
        case 33: return .saveDC
        case 34: return decodeU32(type: type, slice: slice) { .restoreDC(savedDC: Int32(bitPattern: $0)) }
        case 35: return decodeSetWorldTransform(slice: slice)
        case 36: return decodeModifyWorldTransform(slice: slice)
        case 37: return decodeU32(type: type, slice: slice) { .selectObject(ObjectHandle(raw: $0)) }
        case 38: return decodeCreatePen(slice: slice)
        case 39: return decodeCreateBrush(slice: slice)
        case 40: return decodeU32(type: type, slice: slice) { .deleteObject(ObjectHandle(raw: $0)) }
        case 42: return decodeRectL(type: type, slice: slice) { .ellipse(box: $0) }
        case 43: return decodeRectL(type: type, slice: slice) { .rectangle(box: $0) }
        case 44: return decodeRoundRect(slice: slice)
        case 45: return decodeArc(slice: slice)
        case 54: return decodePointL(type: type, slice: slice) { .lineTo(point: $0) }
        case 58: return decodeU32(type: type, slice: slice) { .setMiterLimit(miterLimit: $0) }
        case 59: return .beginPath
        case 60: return .endPath
        case 61: return .closeFigure
        case 62: return decodePathBounds(type: type, slice: slice) { .fillPath(bounds: $0) }
        case 63: return decodePathBounds(type: type, slice: slice) { .strokeAndFillPath(bounds: $0) }
        case 64: return decodePathBounds(type: type, slice: slice) { .strokePath(bounds: $0) }
        case 67: return decodeU32(type: type, slice: slice) { .selectClipPath(RegionMode($0)) }
        case 75: return decodeExtSelectClipRgn(slice: slice)
        case 85: return decodePoly16(type: type, slice: slice, make: EMFRecordPayload.polyBezier16)
        case 86: return decodePoly16(type: type, slice: slice, make: EMFRecordPayload.polygon16)
        case 87: return decodePoly16(type: type, slice: slice, make: EMFRecordPayload.polyline16)
        case 88: return decodePoly16(type: type, slice: slice, make: EMFRecordPayload.polyBezierTo16)
        case 89: return decodePoly16(type: type, slice: slice, make: EMFRecordPayload.polylineTo16)
        case 90: return decodePolyPoly16(type: type, slice: slice, make: EMFRecordPayload.polyPolyline16)
        case 91: return decodePolyPoly16(type: type, slice: slice, make: EMFRecordPayload.polyPolygon16)
        case 95: return decodeExtCreatePen(slice: slice)
        default: return .unimplemented(type: type)
        }
    }

    // MARK: - Fixed-shape decoders
    // Field offsets below are relative to the record start and include the
    // 8-byte Type/Size header, matching the [MS-EMF] §2.3 field tables.

    /// Single u32 field at offset 8 (EMR_SETMAPMODE §2.3.11.19 and friends).
    private static func decodeU32(
        type: UInt32,
        slice: RecordSlice,
        make: (UInt32) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let value = slice.u32(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 12, actualSize: slice.size))
        }
        return make(value)
    }

    /// Single PointL field at offset 8 (EMR_MOVETOEX §2.3.11.4,
    /// EMR_LINETO §2.3.5.13, EMR_SET*ORGEX §2.3.11.29/.31).
    private static func decodePointL(
        type: UInt32,
        slice: RecordSlice,
        make: (PointL) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let point = slice.pointL(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 16, actualSize: slice.size))
        }
        return make(point)
    }

    /// Single SizeL field at offset 8 (EMR_SET*EXTEX §2.3.11.28/.30).
    private static func decodeSizeL(
        type: UInt32,
        slice: RecordSlice,
        make: (SizeL) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let extent = slice.sizeL(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 16, actualSize: slice.size))
        }
        return make(extent)
    }

    /// Single RectL field at offset 8 (EMR_ELLIPSE §2.3.5.5,
    /// EMR_RECTANGLE §2.3.5.34, EMR_INTERSECTCLIPRECT §2.3.2.3).
    private static func decodeRectL(
        type: UInt32,
        slice: RecordSlice,
        make: (RectL) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let rect = slice.rectL(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 24, actualSize: slice.size))
        }
        return make(rect)
    }

    /// The path closers EMR_FILLPATH §2.3.5.9, EMR_STROKEANDFILLPATH
    /// §2.3.5.38, EMR_STROKEPATH §2.3.5.39: a single Bounds RectL at offset 8,
    /// 24 bytes total. Spec-literal — real emitters always write Bounds, so a
    /// shorter record is `.malformed` (never a lenient zero-bounds fallback).
    private static func decodePathBounds(
        type: UInt32,
        slice: RecordSlice,
        make: (RectL) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let bounds = slice.rectL(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 24, actualSize: slice.size))
        }
        return make(bounds)
    }

    /// EMR_SETWORLDTRANSFORM §2.3.12.2: XForm at offset 8, 32 bytes total.
    private static func decodeSetWorldTransform(slice: RecordSlice) -> EMFRecordPayload {
        guard let transform = slice.xform(8) else {
            return .malformed(type: 35, reason: .tooSmall(minimumSize: 32, actualSize: slice.size))
        }
        guard transform.isFinite else {
            return .malformed(type: 35, reason: .nonFiniteTransform)
        }
        return .setWorldTransform(transform)
    }

    /// EMR_MODIFYWORLDTRANSFORM §2.3.12.1: XForm at offset 8, mode u32 at
    /// offset 32, 36 bytes total.
    private static func decodeModifyWorldTransform(slice: RecordSlice) -> EMFRecordPayload {
        guard let transform = slice.xform(8), let rawMode = slice.u32(32) else {
            return .malformed(type: 36, reason: .tooSmall(minimumSize: 36, actualSize: slice.size))
        }
        guard transform.isFinite else {
            return .malformed(type: 36, reason: .nonFiniteTransform)
        }
        return .modifyWorldTransform(ModifyWorldTransformPayload(
            transform: transform,
            mode: ModifyWorldTransformMode(rawMode)
        ))
    }

    /// EMR_ROUNDRECT §2.3.5.35: Box RectL at 8, Corner SizeL at 24.
    private static func decodeRoundRect(slice: RecordSlice) -> EMFRecordPayload {
        guard let box = slice.rectL(8), let corner = slice.sizeL(24) else {
            return .malformed(type: 44, reason: .tooSmall(minimumSize: 32, actualSize: slice.size))
        }
        return .roundRect(RoundRectPayload(box: box, corner: corner))
    }

    /// EMR_ARC §2.3.5.2: Box RectL at 8, Start PointL at 24, End PointL at 32.
    private static func decodeArc(slice: RecordSlice) -> EMFRecordPayload {
        guard let box = slice.rectL(8),
              let start = slice.pointL(24),
              let end = slice.pointL(32)
        else {
            return .malformed(type: 45, reason: .tooSmall(minimumSize: 40, actualSize: slice.size))
        }
        return .arc(ArcPayload(box: box, start: start, end: end))
    }

    /// EMR_CREATEPEN §2.3.7.7: ihPen at 8, LogPen §2.2.19 at 12
    /// (PenStyle, Width PointL, ColorRef); 28 bytes total.
    private static func decodeCreatePen(slice: RecordSlice) -> EMFRecordPayload {
        guard let ihPen = slice.u32(8),
              let style = slice.u32(12),
              let width = slice.pointL(16),
              let color = slice.colorRef(24)
        else {
            return .malformed(type: 38, reason: .tooSmall(minimumSize: 28, actualSize: slice.size))
        }
        return .createPen(CreatePenPayload(ihPen: ihPen, style: style, width: width, color: color))
    }

    /// EMR_CREATEBRUSHINDIRECT §2.3.7.1: ihBrush at 8, LogBrushEx §2.2.12 at
    /// 12 (BrushStyle, Color, BrushHatch); 24 bytes total.
    private static func decodeCreateBrush(slice: RecordSlice) -> EMFRecordPayload {
        guard let ihBrush = slice.u32(8),
              let style = slice.u32(12),
              let color = slice.colorRef(16),
              let hatch = slice.u32(20)
        else {
            return .malformed(type: 39, reason: .tooSmall(minimumSize: 24, actualSize: slice.size))
        }
        return .createBrushIndirect(CreateBrushPayload(ihBrush: ihBrush, style: style, color: color, hatch: hatch))
    }

    /// EMR_EXTCREATEPEN §2.3.7.9: ihPen at 8; offBmi/cbBmi/offBits/cbBits at
    /// 12–28 (raw, not dereferenced in phase 2); LogPenEx §2.2.20 at 28
    /// (PenStyle, Width u32, BrushStyle, ColorRef, BrushHatch,
    /// NumStyleEntries, then the style array at 52). Fixed part 52 bytes;
    /// the style array is validated against nSize BEFORE allocation.
    private static func decodeExtCreatePen(slice: RecordSlice) -> EMFRecordPayload {
        guard let ihPen = slice.u32(8),
              let offBmi = slice.u32(12),
              let cbBmi = slice.u32(16),
              let offBits = slice.u32(20),
              let cbBits = slice.u32(24),
              let style = slice.u32(28),
              let width = slice.u32(32),
              let brushStyle = slice.u32(36),
              let color = slice.colorRef(40),
              let brushHatch = slice.u32(44),
              let numStyleEntries = slice.u32(48)
        else {
            return .malformed(type: 95, reason: .tooSmall(minimumSize: 52, actualSize: slice.size))
        }

        let declared = Int(numStyleEntries)
        let maxFitting = (slice.size - 52) / 4
        guard declared <= maxFitting else {
            return .malformed(type: 95, reason: .countTooLarge(declared: declared, maxFitting: maxFitting))
        }
        guard let styleEntries = slice.u32Array(at: 52, count: declared) else {
            return .malformed(type: 95, reason: .tooSmall(minimumSize: 52, actualSize: slice.size))
        }

        return .extCreatePen(ExtCreatePenPayload(
            ihPen: ihPen,
            offBmi: offBmi,
            cbBmi: cbBmi,
            offBits: offBits,
            cbBits: cbBits,
            style: style,
            width: width,
            brushStyle: brushStyle,
            color: color,
            brushHatch: brushHatch,
            styleEntries: styleEntries
        ))
    }

    // MARK: - Clipping-region decoder

    /// EMR_EXTSELECTCLIPRGN §2.3.2.2: RgnDataSize u32 at 8, RegionMode u32 at
    /// 12, RgnData at 16. RgnData is a RegionData object (§2.2.24): a 32-byte
    /// RegionDataHeader (§2.2.25 — Size==0x20, Type==RDH_RECTANGLES==0x01,
    /// CountRects, RgnSize, Bounds RectL) followed by CountRects × RectL.
    ///
    /// Per §2.3.2.2, when RegionMode is RGN_COPY the region data MAY be omitted
    /// (RgnDataSize 0, no bytes) meaning "reset to the default clipping
    /// region" — a valid payload, not malformed. All counts are validated in
    /// Int arithmetic against BOTH RgnDataSize and the record's own nSize
    /// before any allocation (primer §8).
    private static func decodeExtSelectClipRgn(slice: RecordSlice) -> EMFRecordPayload {
        let type: UInt32 = 75
        guard let rawRgnDataSize = slice.u32(8), let rawMode = slice.u32(12) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 16, actualSize: slice.size))
        }
        let mode = RegionMode(rawMode)
        let rgnDataSize = Int(rawRgnDataSize)

        // RGN_COPY with no region data: reset to the default clipping region.
        if mode == .copy, rgnDataSize == 0 {
            return .extSelectClipRgn(ExtSelectClipRgnPayload(mode: mode, bounds: nil, rects: []))
        }

        // The declared region data must fit within the record's own bytes
        // after the two fixed u32s at offset 8..16.
        let available = slice.size - 16
        guard rgnDataSize <= available else {
            return .malformed(type: type, reason: .countTooLarge(declared: rgnDataSize, maxFitting: max(available, 0)))
        }

        // The 32-byte RegionDataHeader must be present and readable.
        guard rgnDataSize >= 32,
              let headerSize = slice.u32(16),
              let headerType = slice.u32(20),
              let rawCountRects = slice.u32(24),
              // RgnSize (offset 28) is advisory here — not trusted for bounds.
              let bounds = slice.rectL(32)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 48, actualSize: slice.size))
        }

        // Header constants are mandatory ([MS-EMF] §2.2.25).
        guard headerSize == 0x20, headerType == 0x01 else {
            return .malformed(type: type, reason: .badRegionHeader(size: headerSize, type: headerType))
        }

        // CountRects × 16 must fit in the rects region, bounded independently
        // by RgnDataSize (region-internal budget) and nSize (record budget).
        let declared = Int(rawCountRects)
        let maxByRgnData = (rgnDataSize - 32) / 16
        let maxBySize = (slice.size - 48) / 16
        let maxFitting = min(maxByRgnData, maxBySize)
        guard declared <= maxFitting else {
            return .malformed(type: type, reason: .countTooLarge(declared: declared, maxFitting: maxFitting))
        }

        var rects: [RectL] = []
        rects.reserveCapacity(declared)
        for index in 0 ..< declared {
            guard let rect = slice.rectL(48 + index * 16) else {
                return .malformed(type: type, reason: .tooSmall(minimumSize: 48, actualSize: slice.size))
            }
            rects.append(rect)
        }

        return .extSelectClipRgn(ExtSelectClipRgnPayload(mode: mode, bounds: bounds, rects: rects))
    }

    // MARK: - Geometry array decoders

    /// The common 32-bit poly layout ([MS-EMF] §2.3.5.16/.18/.22/.24/.26):
    /// Bounds RectL at 8, Count u32 at 24, Count PointL values at 28. A
    /// count that cannot fit in nSize is `.countTooLarge` BEFORE any
    /// allocation. Extra trailing bytes beyond the points are ignored per
    /// the spec ("any extra points MUST be ignored").
    private static func decodePoly32(
        type: UInt32,
        slice: RecordSlice,
        make: (PolyPointsPayload) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let bounds = slice.rectL(8), let rawCount = slice.u32(24) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 28, actualSize: slice.size))
        }
        let declared = Int(rawCount)
        let maxFitting = (slice.size - 28) / 8
        guard declared <= maxFitting else {
            return .malformed(type: type, reason: .countTooLarge(declared: declared, maxFitting: maxFitting))
        }
        guard let points = slice.pointsL(at: 28, count: declared) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 28, actualSize: slice.size))
        }
        return make(PolyPointsPayload(bounds: bounds, points: points))
    }

    /// The common 16-bit poly layout ([MS-EMF] §2.3.5.17/.19/.23/.25/.27):
    /// identical to the 32-bit family but with 4-byte PointS elements.
    private static func decodePoly16(
        type: UInt32,
        slice: RecordSlice,
        make: (Poly16PointsPayload) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let bounds = slice.rectL(8), let rawCount = slice.u32(24) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 28, actualSize: slice.size))
        }
        let declared = Int(rawCount)
        let maxFitting = (slice.size - 28) / 4
        guard declared <= maxFitting else {
            return .malformed(type: type, reason: .countTooLarge(declared: declared, maxFitting: maxFitting))
        }
        guard let points = slice.pointsS(at: 28, count: declared) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 28, actualSize: slice.size))
        }
        return make(Poly16PointsPayload(bounds: bounds, points: points))
    }

    /// EMR_POLYPOLYLINE16 §2.3.5.31 / EMR_POLYPOLYGON16 §2.3.5.29:
    /// Bounds at 8, NumberOfPolys u32 at 24, Count u32 at 28, a
    /// NumberOfPolys-length u32 array at 32, then Count PointS values.
    /// Both counts are validated against nSize (in Int arithmetic) before
    /// any allocation, and the per-poly counts must sum exactly to Count.
    private static func decodePolyPoly16(
        type: UInt32,
        slice: RecordSlice,
        make: (PolyPoly16Payload) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let bounds = slice.rectL(8),
              let rawPolyCount = slice.u32(24),
              let rawTotal = slice.u32(28)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 32, actualSize: slice.size))
        }

        let polyCount = Int(rawPolyCount)
        let maxPolys = (slice.size - 32) / 4
        guard polyCount <= maxPolys else {
            return .malformed(type: type, reason: .countTooLarge(declared: polyCount, maxFitting: maxPolys))
        }

        let pointsOffset = 32 + polyCount * 4
        let total = Int(rawTotal)
        let maxPoints = (slice.size - pointsOffset) / 4
        guard total <= maxPoints else {
            return .malformed(type: type, reason: .countTooLarge(declared: total, maxFitting: maxPoints))
        }

        guard let pointCounts = slice.u32Array(at: 32, count: polyCount),
              let points = slice.pointsS(at: pointsOffset, count: total)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 32, actualSize: slice.size))
        }

        // Sum in Int: polyCount is bounded by nSize/4 and each count by
        // UInt32.max, so the sum fits comfortably in 64-bit Int.
        let sum = pointCounts.reduce(0) { $0 + Int($1) }
        guard sum == total else {
            return .malformed(type: type, reason: .countMismatch(declaredTotal: total, sumOfCounts: sum))
        }

        return make(PolyPoly16Payload(bounds: bounds, pointCounts: pointCounts, points: points))
    }
}
