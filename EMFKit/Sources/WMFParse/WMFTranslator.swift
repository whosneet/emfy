import EMFParse
import Foundation

/// A WMF file translated into the shared record/DC model for playback through
/// EMFRender's existing GDI path. The translation is a pure value transform —
/// no CGContext, no rendering — so every decode and the object-table logic are
/// unit-testable in isolation ([MS-WMF] §2.3, §3.1.4).
///
/// `payloads` is a flat sequence of `EMFRecordPayload`s: a short page-setup
/// preamble (map mode + window/viewport mapping that scales the WMF logical
/// space onto the device canvas) followed by one or more payloads per WMF
/// record. EMFRender plays them through `DeviceContext`/`draw` exactly as it
/// plays EMF records, so WMF reuses the renderer and never forks it.
public struct WMFRenderProgram: Sendable, Equatable {
    /// Device-canvas width in pixels (the playback bitmap width).
    public let canvasWidth: Int
    /// Device-canvas height in pixels.
    public let canvasHeight: Int
    /// The translated payload stream, page-setup preamble first.
    public let payloads: [EMFRecordPayload]

    public init(canvasWidth: Int, canvasHeight: Int, payloads: [EMFRecordPayload]) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.payloads = payloads
    }
}

/// Translates a parsed `WMFFile` into a `WMFRenderProgram` ([MS-WMF] §2.3).
///
/// Coordinate model (stated for the record): the device canvas is sized in
/// pixels from the page setup, and a map-mode / window / viewport preamble
/// establishes a WMF-logical → device-pixel mapping so that the file's own
/// coordinates (16-bit logical units) land on the canvas. The file's own
/// window/viewport records then compose on top. Because the preamble selects
/// MM_ANISOTROPIC, cosmetic (zero-width) pens stay one *device* pixel wide
/// regardless of the logical scale ([MS-WMF] §3.1.4.2).
public enum WMFTranslator {

    // MARK: - RecordFunction constants ([MS-WMF] §2.1.1.1, verified against
    // the spec's RecordType enumeration — the same values WMFRecordType names).

    private enum Function {
        static let eof: UInt16 = 0x0000
        static let saveDC: UInt16 = 0x001E
        static let setBkMode: UInt16 = 0x0102
        static let setMapMode: UInt16 = 0x0103
        static let setROP2: UInt16 = 0x0104
        static let setRelabs: UInt16 = 0x0105
        static let setPolyFillMode: UInt16 = 0x0106
        static let setStretchBltMode: UInt16 = 0x0107
        static let restoreDC: UInt16 = 0x0127
        static let selectObject: UInt16 = 0x012D
        static let setTextAlign: UInt16 = 0x012E
        static let deleteObject: UInt16 = 0x01F0
        static let setBkColor: UInt16 = 0x0201
        static let setTextColor: UInt16 = 0x0209
        static let setWindowOrg: UInt16 = 0x020B
        static let setWindowExt: UInt16 = 0x020C
        static let setViewportOrg: UInt16 = 0x020D
        static let setViewportExt: UInt16 = 0x020E
        static let offsetWindowOrg: UInt16 = 0x020F
        static let offsetViewportOrg: UInt16 = 0x0211
        static let lineTo: UInt16 = 0x0213
        static let moveTo: UInt16 = 0x0214
        static let polygon: UInt16 = 0x0324
        static let polyline: UInt16 = 0x0325
        static let scaleWindowExt: UInt16 = 0x0410
        static let scaleViewportExt: UInt16 = 0x0412
        static let excludeClipRect: UInt16 = 0x0415
        static let intersectClipRect: UInt16 = 0x0416
        static let ellipse: UInt16 = 0x0418
        static let rectangle: UInt16 = 0x041B
        static let setPixel: UInt16 = 0x041F
        static let polyPolygon: UInt16 = 0x0538
        static let roundRect: UInt16 = 0x061C
        static let patBlt: UInt16 = 0x061D
        static let arc: UInt16 = 0x0817
        static let pie: UInt16 = 0x081A
        static let chord: UInt16 = 0x0830
        // Object-creating records that consume a table slot even when the
        // object itself is not rendered yet ([MS-WMF] §3.1.4.1).
        static let createPenIndirect: UInt16 = 0x02FA
        static let createFontIndirect: UInt16 = 0x02FB
        static let createBrushIndirect: UInt16 = 0x02FC
        static let createPalette: UInt16 = 0x00F7
        static let createPatternBrush: UInt16 = 0x01F9
        static let dibCreatePatternBrush: UInt16 = 0x0142
        static let createRegion: UInt16 = 0x06FF
    }

    /// Hard cap on the WMF object table (§8). META_HEADER NumberOfObjects is
    /// advisory (16 in LibreOffice exports); a crafted file could claim far
    /// more, so allocation is bounded here and an index at or above the cap is
    /// a logged skip, never a crash.
    static let objectTableCap = 4096

    /// Render DPI used to size the placeable canvas from the destination
    /// rectangle and units-per-inch ([MS-WMF] §2.3.2.3). 96 matches the
    /// device-pixel scale the oracle (and the embedded EMF) use.
    static let renderDPI = 96.0

    /// Fallback canvas when a standard WMF carries no usable window extent.
    static let fallbackCanvasWidth = 1024
    static let fallbackCanvasHeight = 768

    /// Canvas caps (§8), mirroring EMFRender's makeImage caps. WMFParse cannot
    /// depend on EMFRender (the dependency runs the other way), so the clamp is
    /// duplicated here as pure arithmetic: 16384 per side, 32 Mpx total area.
    static let canvasDimensionCap = 16_384
    static let canvasAreaCap = 32_000_000

    // MARK: - Entry point

    public static func translate(_ file: WMFFile) -> WMFRenderProgram {
        let page = pageSetup(file)
        var payloads = page.preamble
        var objects = ObjectTable()

        for record in file.records {
            translate(record, in: file, objects: &objects, into: &payloads)
        }

        return WMFRenderProgram(
            canvasWidth: page.canvasWidth,
            canvasHeight: page.canvasHeight,
            payloads: payloads
        )
    }

    // MARK: - Per-record translation

    private static func translate(
        _ record: WMFRawRecord,
        in file: WMFFile,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        let body = WMFByteReader(file.payload(of: record))
        let function = record.function

        switch function {
        case Function.eof:
            return

        // MARK: DC state
        case Function.saveDC:
            objects.saveDepth = min(objects.saveDepth + 1, saveDepthCap)
            payloads.append(.saveDC)

        case Function.restoreDC:
            if let saved = body.readInt16(at: 0) {
                payloads.append(.restoreDC(savedDC: objects.relativeRestore(saved)))
            }

        case Function.setBkMode:
            if let mode = body.readUInt16(at: 0) {
                payloads.append(.setBkMode(BackgroundMode(UInt32(mode))))
            }

        case Function.setMapMode:
            if let mode = body.readUInt16(at: 0) {
                payloads.append(.setMapMode(MapMode(UInt32(mode))))
            }

        case Function.setROP2:
            if let mode = body.readUInt16(at: 0) {
                payloads.append(.setROP2(rawMode: UInt32(mode)))
            }

        case Function.setPolyFillMode:
            if let mode = body.readUInt16(at: 0) {
                payloads.append(.setPolyFillMode(PolygonFillMode(UInt32(mode))))
            }

        case Function.setTextAlign:
            if let mask = body.readUInt16(at: 0) {
                payloads.append(.setTextAlign(TextAlign(rawValue: UInt32(mask))))
            }

        case Function.setBkColor:
            if let color = readColor(body, at: 0) {
                payloads.append(.setBkColor(color))
            }

        case Function.setTextColor:
            if let color = readColor(body, at: 0) {
                payloads.append(.setTextColor(color))
            }

        case Function.setWindowOrg:
            if let point = readReversedPoint(body) {
                objects.windowOrg = point
                payloads.append(.setWindowOrgEx(origin: point))
            }

        case Function.setWindowExt:
            if let size = readReversedSize(body) {
                objects.windowExt = size
                payloads.append(.setWindowExtEx(extent: size))
            }

        case Function.setViewportOrg:
            if let point = readReversedPoint(body) {
                objects.viewportOrg = point
                payloads.append(.setViewportOrgEx(origin: point))
            }

        case Function.setViewportExt:
            if let size = readReversedSize(body) {
                objects.viewportExt = size
                payloads.append(.setViewportExtEx(extent: size))
            }

        case Function.offsetWindowOrg:
            if let delta = readReversedPoint(body) {
                objects.windowOrg = PointL(x: objects.windowOrg.x &+ delta.x, y: objects.windowOrg.y &+ delta.y)
                payloads.append(.setWindowOrgEx(origin: objects.windowOrg))
            }

        case Function.offsetViewportOrg:
            if let delta = readReversedPoint(body) {
                objects.viewportOrg = PointL(x: objects.viewportOrg.x &+ delta.x, y: objects.viewportOrg.y &+ delta.y)
                payloads.append(.setViewportOrgEx(origin: objects.viewportOrg))
            }

        case Function.scaleWindowExt:
            if let scaled = scaled(objects.windowExt, body: body) {
                objects.windowExt = scaled
                payloads.append(.setWindowExtEx(extent: scaled))
            }

        case Function.scaleViewportExt:
            if let scaled = scaled(objects.viewportExt, body: body) {
                objects.viewportExt = scaled
                payloads.append(.setViewportExtEx(extent: scaled))
            }

        // MARK: Clipping
        case Function.intersectClipRect:
            if let rect = readReversedClipRect(body) {
                payloads.append(.intersectClipRect(clip: rect))
            }

        case Function.excludeClipRect:
            if let rect = readReversedClipRect(body) {
                payloads.append(.excludeClipRect(clip: rect))
            }

        // MARK: Objects
        case Function.createPenIndirect:
            createPen(body, objects: &objects, into: &payloads)

        case Function.createBrushIndirect:
            createBrush(body, objects: &objects, into: &payloads)

        case Function.createFontIndirect, Function.createPalette, Function.createPatternBrush,
             Function.dibCreatePatternBrush, Function.createRegion:
            // Consume a table slot but do not render yet (fonts: W4b; palettes,
            // pattern brushes, regions: later). A later SELECTOBJECT of the slot
            // logs and skips in the DC ([MS-WMF] §3.1.4.1).
            _ = objects.allocate(renderable: false, into: &payloads)
            payloads.append(.unimplemented(type: UInt32(function)))

        case Function.selectObject:
            selectObject(body, objects: &objects, into: &payloads)

        case Function.deleteObject:
            deleteObject(body, objects: &objects, into: &payloads)

        // MARK: Geometry
        case Function.moveTo:
            if let point = readReversedPoint(body) {
                payloads.append(.moveToEx(point: point))
            }

        case Function.lineTo:
            if let point = readReversedPoint(body) {
                payloads.append(.lineTo(point: point))
            }

        case Function.polyline:
            if let poly = readPoly16(body, payloadBytes: record.payloadByteCount) {
                payloads.append(.polyline16(poly))
            }

        case Function.polygon:
            if let poly = readPoly16(body, payloadBytes: record.payloadByteCount) {
                payloads.append(.polygon16(poly))
            }

        case Function.polyPolygon:
            if let poly = readPolyPolygon(body, payloadBytes: record.payloadByteCount) {
                payloads.append(.polyPolygon16(poly))
            }

        case Function.rectangle:
            if let box = readReversedRect(body) {
                payloads.append(.rectangle(box: box))
            }

        case Function.ellipse:
            if let box = readReversedRect(body) {
                payloads.append(.ellipse(box: box))
            }

        case Function.roundRect:
            if let payload = readRoundRect(body) {
                payloads.append(.roundRect(payload))
            }

        case Function.arc:
            if let payload = readArc(body) {
                payloads.append(.arc(payload))
            }

        case Function.pie:
            if let payload = readArc(body) {
                payloads.append(.pie(payload))
            }

        case Function.chord:
            if let payload = readArc(body) {
                payloads.append(.chord(payload))
            }

        case Function.setPixel:
            if let color = readColor(body, at: 0),
               let y = body.readInt16(at: 4), let x = body.readInt16(at: 6) {
                payloads.append(.setPixel(point: PointL(x: Int32(x), y: Int32(y)), color: color))
            }

        case Function.patBlt:
            if let payload = readPatBlt(body) {
                payloads.append(.patBlt(bounds: payload.bounds, rasterOperation: payload.rop))
            }

        // MARK: Everything else — log type and skip (§8).
        default:
            payloads.append(.unimplemented(type: UInt32(function)))
        }
    }

    // MARK: - Object table ([MS-WMF] §3.1.4.1)

    /// The lowest-free-index object table, plus the window/viewport shadow the
    /// relative state records (OFFSET*, SCALE*) and the save-depth tracking need.
    private struct ObjectTable {
        private var occupied: Set<Int> = []
        private var renderable: Set<Int> = []
        var saveDepth = 0

        // Window/viewport shadow, seeded by the page-setup preamble so the
        // relative records resolve to absolute values the DC can consume.
        var windowOrg = PointL(x: 0, y: 0)
        var windowExt = SizeL(cx: 1, cy: 1)
        var viewportOrg = PointL(x: 0, y: 0)
        var viewportExt = SizeL(cx: 1, cy: 1)

        /// Allocates the lowest free index. The lowest free index is always at
        /// most the number of occupied slots, so the scan is bounded by the live
        /// object count. Returns `nil` at the cap (the caller logs and skips).
        mutating func allocate(
            renderable isRenderable: Bool,
            into payloads: inout [EMFRecordPayload]
        ) -> Int? {
            var index = 0
            while occupied.contains(index) { index += 1 }
            guard index < objectTableCap else {
                payloads.append(.unimplemented(type: 0xFFFF))
                return nil
            }
            occupied.insert(index)
            if isRenderable { renderable.insert(index) }
            return index
        }

        /// Frees a slot and reports whether it held a renderable object (so the
        /// caller emits a matching EMR_DELETEOBJECT only for those).
        mutating func free(_ index: Int) -> (occupied: Bool, renderable: Bool) {
            let wasOccupied = occupied.remove(index) != nil
            let wasRenderable = renderable.remove(index) != nil
            return (wasOccupied, wasRenderable)
        }

        func isRenderable(_ index: Int) -> Bool { renderable.contains(index) }

        /// Converts a META_RESTOREDC `nSavedDC` ([MS-WMF] §2.3.5.10) to the
        /// EMF relative form (always negative): a negative value passes through;
        /// a positive value is an absolute saved instance, converted relative to
        /// the current save depth. Also updates the shadow save depth.
        mutating func relativeRestore(_ nSavedDC: Int16) -> Int32 {
            let relative: Int
            if nSavedDC < 0 {
                relative = Int(nSavedDC)
            } else {
                // Absolute instance n (1-based): pop back so instance n is
                // current, discarding everything above it.
                relative = -(saveDepth - Int(nSavedDC) + 1)
            }
            if relative < 0, -relative <= saveDepth {
                saveDepth += relative
            }
            return Int32(relative)
        }
    }

    /// Mirrors DeviceContext.saveStackCap so the shadow save depth tracks the
    /// renderer (saves past the cap are dropped there and here).
    private static let saveDepthCap = 512

    private static func createPen(
        _ body: WMFByteReader,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        // Pen Object ([MS-WMF] §2.2.1.4): PenStyle(2), Width PointS(4, x used),
        // ColorRef(4).
        guard let style = body.readUInt16(at: 0),
              let widthX = body.readInt16(at: 2),
              let color = readColor(body, at: 6)
        else { return }
        guard let index = objects.allocate(renderable: true, into: &payloads) else { return }
        payloads.append(.createPen(CreatePenPayload(
            ihPen: UInt32(index + 1),
            style: UInt32(style),
            width: PointL(x: Int32(widthX), y: 0),
            color: color
        )))
    }

    private static func createBrush(
        _ body: WMFByteReader,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        // LogBrush Object ([MS-WMF] §2.2.2.10): BrushStyle(2), ColorRef(4),
        // BrushHatch(2).
        guard let style = body.readUInt16(at: 0),
              let color = readColor(body, at: 2),
              let hatch = body.readUInt16(at: 6)
        else { return }
        guard let index = objects.allocate(renderable: true, into: &payloads) else { return }
        payloads.append(.createBrushIndirect(CreateBrushPayload(
            ihBrush: UInt32(index + 1),
            style: UInt32(style),
            color: color,
            hatch: UInt32(hatch)
        )))
    }

    private static func selectObject(
        _ body: WMFByteReader,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let raw = body.readUInt16(at: 0) else { return }
        // Stock objects are selected with the high bit set; the low bits are a
        // StockObject value ([MS-WMF] glossary → [MS-EMF] §2.1.31).
        if raw & 0x8000 != 0 {
            payloads.append(.selectObject(ObjectHandle(raw: 0x8000_0000 | UInt32(raw & 0x7FFF))))
            return
        }
        let index = Int(raw)
        guard index < objectTableCap else { return }
        // Emit the select even for an unrenderable/absent slot: the DC logs the
        // missing object and keeps the current selection ([MS-WMF] §2.3.4.10).
        payloads.append(.selectObject(.table(index: UInt32(index + 1))))
    }

    private static func deleteObject(
        _ body: WMFByteReader,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let raw = body.readUInt16(at: 0), raw & 0x8000 == 0 else { return }
        let index = Int(raw)
        guard index < objectTableCap else { return }
        let freed = objects.free(index)
        // Emit the DC delete only when a renderable object actually lives there,
        // so freeing a font/palette/region slot does not log a bogus miss.
        if freed.renderable {
            payloads.append(.deleteObject(.table(index: UInt32(index + 1))))
        }
    }

    // MARK: - Field readers (all bounds-checked; reversed field orders per spec)

    /// A ColorRef ([MS-WMF] §2.2.2.8): Red, Green, Blue, Reserved (low byte of
    /// the little-endian word is Red).
    private static func readColor(_ body: WMFByteReader, at offset: Int) -> ColorRef? {
        guard let raw = body.readUInt32(at: offset) else { return nil }
        return ColorRef(
            red: UInt8(raw & 0xFF),
            green: UInt8((raw >> 8) & 0xFF),
            blue: UInt8((raw >> 16) & 0xFF)
        )
    }

    /// A point stored Y-then-X (META_MOVETO/LINETO/SETWINDOWORG/…,
    /// [MS-WMF] §2.3.5.4 et al.).
    private static func readReversedPoint(_ body: WMFByteReader) -> PointL? {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2) else { return nil }
        return PointL(x: Int32(x), y: Int32(y))
    }

    /// A size stored Y-then-X (META_SETWINDOWEXT/SETVIEWPORTEXT,
    /// [MS-WMF] §2.3.5.30/.28).
    private static func readReversedSize(_ body: WMFByteReader) -> SizeL? {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2) else { return nil }
        return SizeL(cx: Int32(x), cy: Int32(y))
    }

    /// A rectangle stored Bottom, Right, Top, Left (META_RECTANGLE/ELLIPSE,
    /// [MS-WMF] §2.3.3.17/.3).
    private static func readReversedRect(_ body: WMFByteReader) -> RectL? {
        guard let bottom = body.readInt16(at: 0), let right = body.readInt16(at: 2),
              let top = body.readInt16(at: 4), let left = body.readInt16(at: 6)
        else { return nil }
        return RectL(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom))
    }

    /// A clip rectangle stored Bottom, Right, Top, Left (META_INTERSECTCLIPRECT
    /// / META_EXCLUDECLIPRECT, [MS-WMF] §2.3.5.3/.2).
    private static func readReversedClipRect(_ body: WMFByteReader) -> RectL? {
        readReversedRect(body)
    }

    /// META_ROUNDRECT ([MS-WMF] §2.3.3.18): Height, Width, Bottom, Right, Top,
    /// Left. Corner is the full width/height of the rounding ellipse.
    private static func readRoundRect(_ body: WMFByteReader) -> RoundRectPayload? {
        guard let height = body.readInt16(at: 0), let width = body.readInt16(at: 2),
              let bottom = body.readInt16(at: 4), let right = body.readInt16(at: 6),
              let top = body.readInt16(at: 8), let left = body.readInt16(at: 10)
        else { return nil }
        return RoundRectPayload(
            box: RectL(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom)),
            corner: SizeL(cx: Int32(width), cy: Int32(height))
        )
    }

    /// META_ARC/PIE/CHORD ([MS-WMF] §2.3.3.1/.13/.2): Y/X end-or-radial-2,
    /// Y/X start-or-radial-1, Bottom, Right, Top, Left.
    private static func readArc(_ body: WMFByteReader) -> ArcPayload? {
        guard let yEnd = body.readInt16(at: 0), let xEnd = body.readInt16(at: 2),
              let yStart = body.readInt16(at: 4), let xStart = body.readInt16(at: 6),
              let bottom = body.readInt16(at: 8), let right = body.readInt16(at: 10),
              let top = body.readInt16(at: 12), let left = body.readInt16(at: 14)
        else { return nil }
        return ArcPayload(
            box: RectL(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom)),
            start: PointL(x: Int32(xStart), y: Int32(yStart)),
            end: PointL(x: Int32(xEnd), y: Int32(yEnd))
        )
    }

    /// META_PATBLT ([MS-WMF] §2.3.3.12): RasterOperation(4), Height, Width,
    /// YLeft, XLeft. The rectangle is (XLeft, YLeft) extended by Width × Height.
    private static func readPatBlt(_ body: WMFByteReader) -> (bounds: RectL, rop: UInt32)? {
        guard let rop = body.readUInt32(at: 0),
              let height = body.readInt16(at: 4), let width = body.readInt16(at: 6),
              let yLeft = body.readInt16(at: 8), let xLeft = body.readInt16(at: 10)
        else { return nil }
        // 16-bit operands widened to Int32 before adding so the corner cannot
        // overflow (§8).
        let left = Int32(xLeft)
        let top = Int32(yLeft)
        return (
            RectL(left: left, top: top, right: left + Int32(width), bottom: top + Int32(height)),
            rop
        )
    }

    /// META_POLYLINE / META_POLYGON ([MS-WMF] §2.3.3.14/.15): NumberOfPoints
    /// (Int16), then that many PointS. The count is validated against the
    /// record's own payload bytes before the points are read (§8).
    private static func readPoly16(_ body: WMFByteReader, payloadBytes: Int) -> Poly16PointsPayload? {
        guard let count16 = body.readInt16(at: 0), count16 >= 0 else { return nil }
        let count = Int(count16)
        // 2-byte count header + count × 4-byte points must fit the payload.
        guard 2 + count * 4 <= payloadBytes else { return nil }
        var points: [PointS] = []
        points.reserveCapacity(count)
        for i in 0 ..< count {
            guard let x = body.readInt16(at: 2 + i * 4), let y = body.readInt16(at: 2 + i * 4 + 2) else { return nil }
            points.append(PointS(x: x, y: y))
        }
        return Poly16PointsPayload(bounds: RectL(left: 0, top: 0, right: 0, bottom: 0), points: points)
    }

    /// META_POLYPOLYGON ([MS-WMF] §2.3.3.16 / §2.2.2.17): NumberOfPolygons
    /// (UInt16), the per-polygon counts (UInt16 each), then all PointS. Every
    /// count is validated against the record's payload bytes before allocation.
    private static func readPolyPolygon(_ body: WMFByteReader, payloadBytes: Int) -> PolyPoly16Payload? {
        guard let polyCount16 = body.readUInt16(at: 0) else { return nil }
        let polyCount = Int(polyCount16)
        // 2-byte count + polyCount × 2-byte sub-counts must fit before points.
        guard 2 + polyCount * 2 <= payloadBytes else { return nil }
        var counts: [UInt32] = []
        counts.reserveCapacity(polyCount)
        var total = 0
        for i in 0 ..< polyCount {
            guard let c = body.readUInt16(at: 2 + i * 2) else { return nil }
            counts.append(UInt32(c))
            total += Int(c)
        }
        let pointsStart = 2 + polyCount * 2
        guard pointsStart + total * 4 <= payloadBytes else { return nil }
        var points: [PointS] = []
        points.reserveCapacity(total)
        for i in 0 ..< total {
            guard let x = body.readInt16(at: pointsStart + i * 4),
                  let y = body.readInt16(at: pointsStart + i * 4 + 2)
            else { return nil }
            points.append(PointS(x: x, y: y))
        }
        return PolyPoly16Payload(
            bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
            pointCounts: counts,
            points: points
        )
    }

    /// META_SCALEWINDOWEXT / META_SCALEVIEWPORTEXT ([MS-WMF] §2.3.5.13/.12):
    /// yDenom, yNum, xDenom, xNum. Multiplies the current extent by num/denom.
    /// A zero denominator leaves the axis unchanged (guarded division, §8).
    private static func scaled(_ extent: SizeL, body: WMFByteReader) -> SizeL? {
        guard let yDenom = body.readInt16(at: 0), let yNum = body.readInt16(at: 2),
              let xDenom = body.readInt16(at: 4), let xNum = body.readInt16(at: 6)
        else { return nil }
        func scale(_ value: Int32, _ num: Int16, _ denom: Int16) -> Int32 {
            guard denom != 0 else { return value }
            // 32-bit × 16-bit in the Int64 domain, then back — no overflow (§8).
            let product = Int64(value) * Int64(num) / Int64(denom)
            return Int32(truncatingIfNeeded: product)
        }
        return SizeL(cx: scale(extent.cx, xNum, xDenom), cy: scale(extent.cy, yNum, yDenom))
    }

    // MARK: - Page setup ([MS-WMF] §2.3.2.3, §3.1.4.2)

    private struct PageSetup {
        var canvasWidth: Int
        var canvasHeight: Int
        var preamble: [EMFRecordPayload]
    }

    /// Establishes the device canvas and a map-mode/window/viewport preamble
    /// that maps the WMF logical space onto it.
    ///
    /// - Placeable: the destination BoundingBox and Inch (units per inch) size
    ///   the canvas at `renderDPI`; window = the BoundingBox, viewport = the
    ///   canvas.
    /// - Standard: the first SETWINDOWORG/EXT the file carries sizes the canvas
    ///   (1:1 logical→device); fallback 1024×768 when neither is usable.
    private static func pageSetup(_ file: WMFFile) -> PageSetup {
        if let placeable = file.placeable {
            return placeablePageSetup(placeable)
        }
        return standardPageSetup(file)
    }

    private static func placeablePageSetup(_ placeable: WMFPlaceableHeader) -> PageSetup {
        let bb = placeable.boundingBox
        let boxWidth = Int(bb.right) - Int(bb.left)
        let boxHeight = Int(bb.bottom) - Int(bb.top)
        let inch = Int(placeable.inch)

        let canvasW = canvasDimension(logical: boxWidth, inch: inch)
        let canvasH = canvasDimension(logical: boxHeight, inch: inch)
        let (cw, ch) = clampArea(width: canvasW, height: canvasH)

        let windowOrg = PointL(x: Int32(bb.left), y: Int32(bb.top))
        // Guard against a zero/degenerate extent dividing in the DC: fall back
        // to 1 so the mapping stays finite (the drawing collapses, not crashes).
        let windowExt = SizeL(
            cx: Int32(boxWidth == 0 ? 1 : boxWidth),
            cy: Int32(boxHeight == 0 ? 1 : boxHeight)
        )
        return PageSetup(
            canvasWidth: cw,
            canvasHeight: ch,
            preamble: preamble(windowOrg: windowOrg, windowExt: windowExt, canvasWidth: cw, canvasHeight: ch)
        )
    }

    private static func standardPageSetup(_ file: WMFFile) -> PageSetup {
        // Pre-scan the first window org/ext the file sets.
        var windowOrg = PointL(x: 0, y: 0)
        var windowExt: SizeL?
        for record in file.records {
            let body = WMFByteReader(file.payload(of: record))
            if record.function == Function.setWindowOrg, windowExt == nil, let point = readReversedPoint(body) {
                windowOrg = point
            } else if record.function == Function.setWindowExt, let size = readReversedSize(body) {
                windowExt = size
                break
            }
        }

        let cw: Int
        let ch: Int
        let ext: SizeL
        if let windowExt, windowExt.cx != 0, windowExt.cy != 0 {
            let clampedW = clampDimension(Double(abs(Int(windowExt.cx))))
            let clampedH = clampDimension(Double(abs(Int(windowExt.cy))))
            (cw, ch) = clampArea(width: clampedW, height: clampedH)
            ext = windowExt
        } else {
            cw = fallbackCanvasWidth
            ch = fallbackCanvasHeight
            ext = SizeL(cx: Int32(cw), cy: Int32(ch))
            windowOrg = PointL(x: 0, y: 0)
        }

        return PageSetup(
            canvasWidth: cw,
            canvasHeight: ch,
            preamble: preamble(windowOrg: windowOrg, windowExt: ext, canvasWidth: cw, canvasHeight: ch)
        )
    }

    /// The device-pixel canvas dimension for a logical span at `renderDPI`.
    /// With no usable units-per-inch the logical span is treated 1:1 as pixels;
    /// a non-positive span collapses to 1.
    private static func canvasDimension(logical: Int, inch: Int) -> Int {
        if logical > 0, inch > 0 {
            return clampDimension(Double(logical) / Double(inch) * renderDPI)
        }
        if logical > 0 {
            return clampDimension(Double(logical))
        }
        return 1
    }

    /// Rounds and clamps a requested canvas dimension into [1, cap].
    private static func clampDimension(_ requested: Double) -> Int {
        guard requested.isFinite else { return canvasDimensionCap }
        let rounded = requested.rounded()
        if rounded < 1 { return 1 }
        if rounded > Double(canvasDimensionCap) { return canvasDimensionCap }
        return Int(rounded)
    }

    /// Scales an already per-side-clamped canvas down to `canvasAreaCap` total
    /// pixels, preserving aspect ratio, floored to 1×1. Inputs are each in
    /// [1, canvasDimensionCap], so `width * height` fits Int without overflow.
    private static func clampArea(width: Int, height: Int) -> (width: Int, height: Int) {
        let area = width * height
        guard area > canvasAreaCap else { return (width, height) }
        let scale = (Double(canvasAreaCap) / Double(area)).squareRoot()
        let scaledWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        return (scaledWidth, scaledHeight)
    }

    /// The MM_ANISOTROPIC window→viewport preamble: map the WMF logical window
    /// onto the full device canvas. Cosmetic pens stay one device pixel wide
    /// because the device space is the canvas, not the logical space.
    private static func preamble(
        windowOrg: PointL,
        windowExt: SizeL,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> [EMFRecordPayload] {
        [
            .setMapMode(.anisotropic),
            .setWindowOrgEx(origin: windowOrg),
            .setWindowExtEx(extent: windowExt),
            .setViewportOrgEx(origin: PointL(x: 0, y: 0)),
            .setViewportExtEx(extent: SizeL(cx: Int32(canvasWidth), cy: Int32(canvasHeight))),
        ]
    }
}
