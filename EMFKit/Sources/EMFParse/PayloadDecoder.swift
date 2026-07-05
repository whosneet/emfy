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

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= size - 2 else { return nil }
        return reader.readUInt16(at: base + offset)
    }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset <= size - 1,
              let byte = reader.data(at: base + offset, length: 1)
        else { return nil }
        return byte[byte.startIndex]
    }

    /// The raw bytes in `[offset, offset + length)`, bounds-checked against
    /// the record's own extent. `length` must be >= 0.
    func bytes(at offset: Int, length: Int) -> Data? {
        guard length >= 0, offset >= 0, length <= size - offset else { return nil }
        return reader.data(at: base + offset, length: length)
    }

    /// Decodes `codeUnits` UTF-16LE code units at `offset` into a `String`.
    /// Bounds-checked against the record. Lone surrogates decode losslessly
    /// (`String(decoding:as:)` substitutes U+FFFD; it never fails), so a
    /// hostile string never fails the payload. Reads up to the first NUL when
    /// `stopAtNUL` is set (LogFont FaceName semantics, [MS-EMF] §2.2.13);
    /// otherwise decodes exactly `codeUnits` (EmrText string, §2.2.5).
    func utf16String(at offset: Int, codeUnits: Int, stopAtNUL: Bool) -> String? {
        guard codeUnits >= 0, offset >= 0, codeUnits <= (size - offset) / 2 else {
            return nil
        }
        var units: [UInt16] = []
        units.reserveCapacity(codeUnits)
        for index in 0 ..< codeUnits {
            guard let unit = reader.readUInt16(at: base + offset + index * 2) else {
                return nil
            }
            if stopAtNUL, unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
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
        case 22: return decodeU32(type: type, slice: slice) { .setTextAlign(TextAlign(rawValue: $0)) }
        case 24: return decodeColor(type: type, slice: slice) { .setTextColor($0) }
        case 25: return decodeColor(type: type, slice: slice) { .setBkColor($0) }
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
        case 76: return decodeBitBlt(slice: slice, stretch: false)
        case 77: return decodeBitBlt(slice: slice, stretch: true)
        case 80: return decodeSetDIBitsToDevice(slice: slice)
        case 81: return decodeStretchDIBits(slice: slice)
        case 82: return decodeExtCreateFontIndirectW(slice: slice)
        case 84: return decodeExtTextOutW(slice: slice)
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

    /// Single ColorRef field at offset 8 (EMR_SETTEXTCOLOR §2.3.11.26,
    /// EMR_SETBKCOLOR §2.3.11.10).
    private static func decodeColor(
        type: UInt32,
        slice: RecordSlice,
        make: (ColorRef) -> EMFRecordPayload
    ) -> EMFRecordPayload {
        guard let color = slice.colorRef(8) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 12, actualSize: slice.size))
        }
        return make(color)
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

    // MARK: - Text decoders

    /// EMR_EXTCREATEFONTINDIRECTW §2.3.7.8: ihFonts u32 at 8, then the `elw`
    /// font object at 12. `elw` is a LogFont (92), LogFontEx (348), LogFontExDv
    /// (>348), or LogFontPanose (320) — every variant begins with the same
    /// 92-byte LogFont (§2.2.14/.15/.16), so the prefix decodes uniformly.
    /// The full record is therefore at least 12 + 92 = 104 bytes; a shorter one
    /// is `.malformed`. `hasExtendedData` is true when `elw` exceeded 92 bytes.
    private static func decodeExtCreateFontIndirectW(slice: RecordSlice) -> EMFRecordPayload {
        let type: UInt32 = 82
        guard let ihFonts = slice.u32(8), let logFont = decodeLogFont(slice: slice, at: 12) else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 104, actualSize: slice.size))
        }
        // elw size = record size - 12; > 92 means LogFontEx/ExDv/Panose extras.
        let hasExtendedData = (slice.size - 12) > 92
        return .extCreateFontIndirectW(ExtCreateFontPayload(
            ihFonts: ihFonts,
            logFont: logFont,
            hasExtendedData: hasExtendedData
        ))
    }

    /// The 92-byte LogFont prefix ([MS-EMF] §2.2.13) at record offset `at`:
    /// five i32s (Height..Weight) at +0..+16, eight u8s (Italic..PitchAndFamily)
    /// at +20..+27, then a 64-byte (32 UTF-16LE code units) NUL-terminable
    /// FaceName at +28. Returns nil (→ caller reports `.malformed`) on a short
    /// read. Height is carried signed (§2.2.13 sign convention).
    private static func decodeLogFont(slice: RecordSlice, at offset: Int) -> LogFont? {
        guard let height = slice.i32(offset),
              let width = slice.i32(offset + 4),
              let escapement = slice.i32(offset + 8),
              let orientation = slice.i32(offset + 12),
              let weight = slice.i32(offset + 16),
              let italic = slice.u8(offset + 20),
              let underline = slice.u8(offset + 21),
              let strikeOut = slice.u8(offset + 22),
              let charSet = slice.u8(offset + 23),
              let outPrecision = slice.u8(offset + 24),
              let clipPrecision = slice.u8(offset + 25),
              let quality = slice.u8(offset + 26),
              let pitchAndFamily = slice.u8(offset + 27),
              // FaceName: 32 UTF-16LE code units, NUL-terminated (§2.2.13).
              let faceName = slice.utf16String(at: offset + 28, codeUnits: 32, stopAtNUL: true)
        else { return nil }
        return LogFont(
            height: height,
            width: width,
            escapement: escapement,
            orientation: orientation,
            weight: weight,
            italic: italic,
            underline: underline,
            strikeOut: strikeOut,
            charSet: charSet,
            outPrecision: outPrecision,
            clipPrecision: clipPrecision,
            quality: quality,
            pitchAndFamily: pitchAndFamily,
            faceName: faceName
        )
    }

    /// EMR_EXTTEXTOUTW §2.3.5.8: Bounds RectL at 8 (ignored on receipt),
    /// iGraphicsMode u32 at 24, exScale f32 at 28, eyScale f32 at 32, then the
    /// EmrText object (§2.2.5) at 36. Fixed part through the EmrText fixed
    /// fields is 76 bytes (offDx sits at 72).
    ///
    /// EmrText fixed fields, at RECORD offsets: Reference PointL at 36, Chars
    /// u32 at 44, offString u32 at 48, Options u32 at 52, Rectangle RectL at 56,
    /// offDx u32 at 72. offString and offDx are RECORD-start-relative (§2.2.5:
    /// "from the start of the record in which this object is contained").
    private static func decodeExtTextOutW(slice: RecordSlice) -> EMFRecordPayload {
        let type: UInt32 = 84
        guard let bounds = slice.rectL(8),
              let graphicsMode = slice.u32(24),
              let exScale = slice.f32(28),
              let eyScale = slice.f32(32),
              let reference = slice.pointL(36),
              let rawChars = slice.u32(44),
              let rawOffString = slice.u32(48),
              let rawOptions = slice.u32(52),
              let rectangle = slice.rectL(56),
              let rawOffDx = slice.u32(72)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 76, actualSize: slice.size))
        }
        _ = bounds // Bounds MUST be ignored on receipt (§2.3.5.8); not carried.

        // Hostile floats never propagate (primer §8): reject non-finite scales.
        guard exScale.isFinite, eyScale.isFinite else {
            return .malformed(type: type, reason: .nonFiniteTransform)
        }

        let options = ExtTextOutOptions(rawValue: rawOptions)
        let chars = Int(rawChars)
        let offString = Int(rawOffString)

        // String: `chars` UTF-16LE code units at the record-relative offString.
        // Validate the byte range against nSize before decoding (§8).
        let stringByteLength = chars * 2
        guard offString >= 0, chars >= 0, stringByteLength <= slice.size - offString else {
            return .malformed(type: type, reason: .rangeOutOfBounds(
                offset: offString, length: stringByteLength, recordSize: slice.size
            ))
        }
        guard let string = slice.utf16String(at: offString, codeUnits: chars, stopAtNUL: false) else {
            return .malformed(type: type, reason: .rangeOutOfBounds(
                offset: offString, length: stringByteLength, recordSize: slice.size
            ))
        }

        // Dx: present only when offDx != 0. Length is `chars`, or `2 × chars`
        // when ETO_PDY is set (§2.2.5 OutputDx). Validate the range against
        // nSize before allocating.
        var dx: [UInt32]? = nil
        if rawOffDx != 0 {
            let offDx = Int(rawOffDx)
            let dxCount = options.pdy ? chars * 2 : chars
            let dxByteLength = dxCount * 4
            guard offDx >= 0, dxByteLength <= slice.size - offDx else {
                return .malformed(type: type, reason: .rangeOutOfBounds(
                    offset: offDx, length: dxByteLength, recordSize: slice.size
                ))
            }
            guard let values = slice.u32Array(at: offDx, count: dxCount) else {
                return .malformed(type: type, reason: .rangeOutOfBounds(
                    offset: offDx, length: dxByteLength, recordSize: slice.size
                ))
            }
            dx = values
        }

        return .extTextOutW(ExtTextPayload(
            graphicsMode: graphicsMode,
            exScale: exScale,
            eyScale: eyScale,
            reference: reference,
            rectangle: rectangle,
            string: string,
            options: options,
            dx: dx
        ))
    }

    // MARK: - Bitmap decoders

    /// Per-side and total-area caps for a decoded DIB (primer §8): a hostile
    /// header must never make the renderer allocate an enormous surface.
    private static let dibMaxDimension = 30_000
    private static let dibMaxArea = 100_000_000

    /// EMR_STRETCHDIBITS §2.3.1.7. Fixed part 80 bytes: Bounds RectL at 8,
    /// xDest/yDest at 24/28, xSrc/ySrc at 32/36, cxSrc/cySrc at 40/44,
    /// offBmiSrc/cbBmiSrc/offBitsSrc/cbBitsSrc at 48/52/56/60, UsageSrc at 64,
    /// BitBltRasterOperation at 68, cxDest/cyDest at 72/76.
    private static func decodeStretchDIBits(slice: RecordSlice) -> EMFRecordPayload {
        let type: UInt32 = 81
        guard let bounds = slice.rectL(8),
              let xDest = slice.i32(24), let yDest = slice.i32(28),
              let xSrc = slice.i32(32), let ySrc = slice.i32(36),
              let cxSrc = slice.i32(40), let cySrc = slice.i32(44),
              let offBmi = slice.u32(48), let cbBmi = slice.u32(52),
              let offBits = slice.u32(56), let cbBits = slice.u32(60),
              let usageSrc = slice.u32(64), let rop = slice.u32(68),
              let cxDest = slice.i32(72), let cyDest = slice.i32(76)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 80, actualSize: slice.size))
        }

        let dibResult = decodeDIB(
            slice: slice, type: type,
            offBmi: offBmi, cbBmi: cbBmi, offBits: offBits, cbBits: cbBits
        )
        switch dibResult {
        case .failure(let reason):
            return .malformed(type: type, reason: reason)
        case .success(let dib):
            return .stretchDIBits(StretchDIBitsPayload(
                bounds: bounds,
                dest: PointL(x: xDest, y: yDest),
                destSize: SizeL(cx: cxDest, cy: cyDest),
                src: PointL(x: xSrc, y: ySrc),
                srcSize: SizeL(cx: cxSrc, cy: cySrc),
                usageSrc: usageSrc,
                rasterOperation: rop,
                dib: dib
            ))
        }
    }

    /// EMR_SETDIBITSTODEVICE §2.3.1.5. Fixed part 76 bytes: Bounds at 8,
    /// xDest/yDest at 24/28, xSrc/ySrc at 32/36, cxSrc/cySrc at 40/44,
    /// offBmiSrc/cbBmiSrc/offBitsSrc/cbBitsSrc at 48/52/56/60, UsageSrc at 64,
    /// iStartScan at 68, cScans at 72. No raster op, no source transform.
    private static func decodeSetDIBitsToDevice(slice: RecordSlice) -> EMFRecordPayload {
        let type: UInt32 = 80
        guard let bounds = slice.rectL(8),
              let xDest = slice.i32(24), let yDest = slice.i32(28),
              let xSrc = slice.i32(32), let ySrc = slice.i32(36),
              let cxSrc = slice.i32(40), let cySrc = slice.i32(44),
              let offBmi = slice.u32(48), let cbBmi = slice.u32(52),
              let offBits = slice.u32(56), let cbBits = slice.u32(60),
              let usageSrc = slice.u32(64),
              let startScan = slice.u32(68), let scanCount = slice.u32(72)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: 76, actualSize: slice.size))
        }

        let dibResult = decodeDIB(
            slice: slice, type: type,
            offBmi: offBmi, cbBmi: cbBmi, offBits: offBits, cbBits: cbBits
        )
        switch dibResult {
        case .failure(let reason):
            return .malformed(type: type, reason: reason)
        case .success(let dib):
            return .setDIBitsToDevice(SetDIBitsToDevicePayload(
                bounds: bounds,
                dest: PointL(x: xDest, y: yDest),
                src: PointL(x: xSrc, y: ySrc),
                srcSize: SizeL(cx: cxSrc, cy: cySrc),
                usageSrc: usageSrc,
                startScan: startScan,
                scanCount: scanCount,
                dib: dib
            ))
        }
    }

    /// EMR_BITBLT §2.3.1.2 (100-byte fixed part) and EMR_STRETCHBLT §2.3.1.6
    /// (108-byte fixed part = BITBLT + cxSrc/cySrc). Shared layout: Bounds at 8,
    /// xDest/yDest at 24/28, cxDest/cyDest at 32/36, BitBltRasterOperation at
    /// 40, xSrc/ySrc at 44/48, XformSrc (24 bytes) at 52, BkColorSrc at 76,
    /// UsageSrc at 80, offBmiSrc/cbBmiSrc/offBitsSrc/cbBitsSrc at 84/88/92/96.
    /// STRETCHBLT adds cxSrc at 100 and cySrc at 104.
    ///
    /// A sourceless (rop-only) blit is VALID: cbBmiSrc == 0 means the DIB is
    /// omitted (§2.3.1.2), yielding `dib == nil` — not malformed.
    private static func decodeBitBlt(slice: RecordSlice, stretch: Bool) -> EMFRecordPayload {
        let type: UInt32 = stretch ? 77 : 76
        let minimumSize = stretch ? 108 : 100
        guard let bounds = slice.rectL(8),
              let xDest = slice.i32(24), let yDest = slice.i32(28),
              let cxDest = slice.i32(32), let cyDest = slice.i32(36),
              let rop = slice.u32(40),
              let xSrc = slice.i32(44), let ySrc = slice.i32(48),
              let xform = slice.xform(52),
              let bkColor = slice.colorRef(76),
              let usageSrc = slice.u32(80),
              let offBmi = slice.u32(84), let cbBmi = slice.u32(88),
              let offBits = slice.u32(92), let cbBits = slice.u32(96)
        else {
            return .malformed(type: type, reason: .tooSmall(minimumSize: minimumSize, actualSize: slice.size))
        }

        var srcSize: SizeL? = nil
        if stretch {
            guard let cxSrc = slice.i32(100), let cySrc = slice.i32(104) else {
                return .malformed(type: type, reason: .tooSmall(minimumSize: 108, actualSize: slice.size))
            }
            srcSize = SizeL(cx: cxSrc, cy: cySrc)
        }

        // Hostile floats never propagate (primer §8).
        guard xform.isFinite else {
            return .malformed(type: type, reason: .nonFiniteTransform)
        }

        // Sourceless (rop-only) form: cbBmiSrc == 0, DIB omitted — VALID.
        var dib: DIB? = nil
        if cbBmi != 0 {
            switch decodeDIB(
                slice: slice, type: type,
                offBmi: offBmi, cbBmi: cbBmi, offBits: offBits, cbBits: cbBits
            ) {
            case .failure(let reason):
                return .malformed(type: type, reason: reason)
            case .success(let decoded):
                dib = decoded
            }
        }

        let payload = BitBltPayload(
            bounds: bounds,
            dest: PointL(x: xDest, y: yDest),
            destSize: SizeL(cx: cxDest, cy: cyDest),
            rasterOperation: rop,
            src: PointL(x: xSrc, y: ySrc),
            xformSrc: xform,
            bkColorSrc: bkColor,
            usageSrc: usageSrc,
            srcSize: srcSize,
            dib: dib
        )
        return stretch ? .stretchBlt(payload) : .bitBlt(payload)
    }

    // MARK: - Shared DIB core

    /// Outcome of `decodeDIB`: a decoded DIB (whose `content` may itself be
    /// `.unsupported`, a valid verdict) or a `.malformed` reason. A dedicated
    /// enum rather than `Result` — `EMFPayloadIssue` is a plain value type, not
    /// an `Error`.
    private enum DIBDecodeResult {
        case success(DIB)
        case failure(EMFPayloadIssue)
    }

    /// Decodes one source DIB from the record-relative BMI and bits ranges
    /// carried by every bitmap record. Returns `.failure(reason)` for a hostile
    /// or internally-inconsistent DIB (`.malformed`) and `.success(dib)` for a
    /// valid one — where the DIB's own `content` is `.pixels` when this phase
    /// decodes it (BI_RGB 24/32-bit, or 8-bit palettised) or `.unsupported`
    /// otherwise (RLE, BITFIELDS, 1/4/16-bit, palette usage).
    ///
    /// Every offset and length is validated against the record's `nSize` in
    /// Int arithmetic BEFORE any pixel bytes are exposed (primer §8, the
    /// hostile surface). BitmapInfoHeader layout per [MS-WMF] §2.2.2.3
    /// (not in the local [MS-EMF] PDF); RGBQuad order per [MS-WMF] §2.2.2.20.
    private static func decodeDIB(
        slice: RecordSlice,
        type: UInt32,
        offBmi: UInt32,
        cbBmi: UInt32,
        offBits: UInt32,
        cbBits: UInt32
    ) -> DIBDecodeResult {
        let bmiOffset = Int(offBmi)
        let bmiSize = Int(cbBmi)
        let bitsOffset = Int(offBits)
        let bitsSize = Int(cbBits)

        // The BMI and bits ranges must each fit inside the record (§8). Bits
        // may legitimately be empty (bitsSize 0), but the offset still has to
        // be in range.
        guard bmiOffset >= 0, bmiSize >= 0, bmiSize <= slice.size - bmiOffset else {
            return .failure(.rangeOutOfBounds(offset: bmiOffset, length: bmiSize, recordSize: slice.size))
        }
        guard bitsOffset >= 0, bitsSize >= 0, bitsSize <= slice.size - bitsOffset else {
            return .failure(.rangeOutOfBounds(offset: bitsOffset, length: bitsSize, recordSize: slice.size))
        }

        // BitmapInfoHeader is at least 40 bytes; its fixed prefix must fit both
        // cbBmiSrc and the record. Larger headers are legal — read the 40-byte
        // prefix and ignore the rest (still bounded by cbBmiSrc).
        guard bmiSize >= 40, let rawHeaderSize = slice.u32(bmiOffset) else {
            return .failure(.tooSmall(minimumSize: bmiOffset + 40, actualSize: slice.size))
        }
        guard rawHeaderSize >= 40 else {
            return .failure(.badBitmapHeader(headerSize: rawHeaderSize))
        }

        guard let width = slice.i32(bmiOffset + 4),
              let height = slice.i32(bmiOffset + 8),
              // Planes u16 at +12 (MUST be 1; not acted on), BitCount u16 at +14.
              let bitCount = slice.u16(bmiOffset + 14),
              let rawCompression = slice.u32(bmiOffset + 16),
              // ColorUsed u32 at +32 (palette length; 0 means "all for BitCount").
              let colorUsed = slice.u32(bmiOffset + 32)
        else {
            return .failure(.tooSmall(minimumSize: bmiOffset + 40, actualSize: slice.size))
        }
        let compression = BitmapCompression(rawCompression)

        // Only BI_RGB is decoded to pixels; anything else is a VALID
        // `.unsupported` DIB the renderer logs (distinct from `.malformed`).
        guard compression == .rgb else {
            return .success(DIB(
                width: width, height: height, bitCount: bitCount,
                compression: compression,
                content: .unsupported(.compression(compression))
            ))
        }
        // 24/32-bit truecolor and 8-bit palettised are decoded; others are
        // `.unsupported` (1/4/16-bit).
        guard bitCount == 24 || bitCount == 32 || bitCount == 8 else {
            return .success(DIB(
                width: width, height: height, bitCount: bitCount,
                compression: compression,
                content: .unsupported(.bitCount(bitCount))
            ))
        }

        // §8 HOSTILE SURFACE — the stride/size math. Dimensions are validated
        // BEFORE the stride multiply so nothing overflows and nothing enormous
        // is allocated. All arithmetic is Int (64-bit here); width/height came
        // from i32 so |value| fits comfortably.
        let w = Int(width)
        let absHeight = height == Int32.min ? Int(Int32.max) + 1 : abs(Int(height))
        guard w > 0, absHeight > 0,
              w <= dibMaxDimension, absHeight <= dibMaxDimension,
              w <= dibMaxArea / absHeight
        else {
            return .failure(.badBitmapDimensions(width: w, height: absHeight))
        }

        // stride = ((Width × BitCount + 31) / 32) × 4, required = stride × |Height|.
        // w ≤ 30_000 and bitCount ≤ 32 keep the product far below Int overflow.
        let stride = ((w * Int(bitCount) + 31) / 32) * 4
        let required = stride * absHeight
        guard required <= bitsSize else {
            return .failure(.badBitmapDimensions(width: w, height: absHeight))
        }
        guard let pixelBytes = slice.bytes(at: bitsOffset, length: required) else {
            return .failure(.rangeOutOfBounds(offset: bitsOffset, length: required, recordSize: slice.size))
        }

        // Palette (8-bit only): 4-byte RGBQuads (B,G,R,X) directly after the
        // header prefix, inside cbBmiSrc. ColorUsed names the intended entry
        // count (0 = "up to 256"), but the number PHYSICALLY present is bounded
        // by what fits in cbBmiSrc after the header — real emitters (libUEMF,
        // libemf2svg test-039) write a short 100-entry table with ColorUsed 0,
        // relying on the reader to size the table from cbBmiSrc, exactly as GDI
        // does. So the count is clamped to the available bytes rather than
        // rejected. Pixel indices that then fall outside the table are the
        // renderer's concern (Task B), not a parse failure.
        var palette: [RGBQuad] = []
        if bitCount == 8 {
            let headerSize = Int(rawHeaderSize)
            let paletteOffset = bmiOffset + headerSize
            // Bytes available for the color table within cbBmiSrc (never past
            // the header record, never negative).
            let availableBytes = headerSize <= bmiSize ? bmiSize - headerSize : 0
            let availableQuads = availableBytes / 4
            let requested = colorUsed == 0 ? 256 : Int(colorUsed)
            let paletteCount = min(requested, availableQuads)
            palette.reserveCapacity(paletteCount)
            for index in 0 ..< paletteCount {
                guard let b = slice.u8(paletteOffset + index * 4),
                      let g = slice.u8(paletteOffset + index * 4 + 1),
                      let r = slice.u8(paletteOffset + index * 4 + 2),
                      let x = slice.u8(paletteOffset + index * 4 + 3)
                else {
                    // Bounded by availableQuads above, so this is unreachable in
                    // practice; kept as a defensive typed failure rather than a
                    // force-unwrap (§8).
                    return .failure(.rangeOutOfBounds(
                        offset: paletteOffset, length: paletteCount * 4, recordSize: slice.size
                    ))
                }
                palette.append(RGBQuad(blue: b, green: g, red: r, reserved: x))
            }
        }

        return .success(DIB(
            width: width, height: height, bitCount: bitCount,
            compression: compression,
            content: .pixels(bytes: pixelBytes, stride: stride, palette: palette)
        ))
    }
}
