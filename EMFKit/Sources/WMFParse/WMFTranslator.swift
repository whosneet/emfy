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
        // Text ([MS-WMF] §2.3.3.20/.5).
        static let textOut: UInt16 = 0x0521
        static let extTextOut: UInt16 = 0x0A32
        // Bitmaps ([MS-WMF] §2.3.1): DIB-carrying and DDB (Bitmap16) blits.
        static let bitBlt: UInt16 = 0x0922
        static let stretchBlt: UInt16 = 0x0B23
        static let dibBitBlt: UInt16 = 0x0940
        static let dibStretchBlt: UInt16 = 0x0B41
        static let setDIBToDev: UInt16 = 0x0D33
        static let stretchDIB: UInt16 = 0x0F43
        // Regions ([MS-WMF] §2.3.3/.4/.5).
        static let selectClipRegion: UInt16 = 0x012C
        static let offsetClipRgn: UInt16 = 0x0220
        static let fillRegion: UInt16 = 0x0228
        static let invertRegion: UInt16 = 0x012A
        static let paintRegion: UInt16 = 0x012B
        static let frameRegion: UInt16 = 0x0429
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

    /// Hard cap on the rectangles a single META_CREATEREGION yields (§8): a
    /// hostile Region Object could declare a huge ScanCount or per-scan point
    /// count, so the extracted rect union is bounded here and the parse stops at
    /// the cap. Real regions are a handful of scanlines; 8192 is far above any
    /// legitimate file yet keeps the clip model's work bounded.
    static let regionRectCap = 8192

    /// Caps for a DDB (Bitmap16) source (§8), mirroring the DIB decoder's
    /// per-side and area caps so a hostile Bitmap16 cannot force a huge
    /// allocation when it is expanded/repacked into the shared DIB model.
    static let ddbDimensionCap = 30_000
    static let ddbAreaCap = 4_000_000

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

        case Function.createFontIndirect:
            createFont(body, objects: &objects, into: &payloads)

        case Function.createPatternBrush, Function.dibCreatePatternBrush:
            createPatternBrush(function: function, objects: &objects, into: &payloads)

        case Function.createRegion:
            createRegion(body, payloadBytes: record.payloadByteCount, objects: &objects, into: &payloads)

        case Function.createPalette:
            // CREATEPALETTE keeps its table slot but is not realised: palette
            // tracking is log-and-skip (DIB_PAL_COLORS DIBs are skipped on their
            // own usage flag). A later SELECTOBJECT of the slot logs in the DC.
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

        // MARK: Text ([MS-WMF] §2.3.3.20/.5)
        case Function.textOut:
            textOut(body, payloadBytes: record.payloadByteCount, charSet: objects.currentCharSet, into: &payloads)

        case Function.extTextOut:
            extTextOut(body, payloadBytes: record.payloadByteCount, charSet: objects.currentCharSet, into: &payloads)

        // MARK: Bitmaps ([MS-WMF] §2.3.1)
        case Function.stretchDIB:
            stretchDIB(body, payloadBytes: record.payloadByteCount, into: &payloads)

        case Function.dibBitBlt:
            dibBlt(body, record: record, stretch: false, into: &payloads)

        case Function.dibStretchBlt:
            dibBlt(body, record: record, stretch: true, into: &payloads)

        case Function.setDIBToDev:
            setDIBToDev(body, payloadBytes: record.payloadByteCount, into: &payloads)

        case Function.bitBlt:
            ddbBlt(body, record: record, stretch: false, into: &payloads)

        case Function.stretchBlt:
            ddbBlt(body, record: record, stretch: true, into: &payloads)

        // MARK: Regions ([MS-WMF] §2.3.3/.4/.5)
        case Function.selectClipRegion:
            selectClipRegion(body, objects: objects, into: &payloads)

        case Function.fillRegion:
            fillRegion(body, objects: objects, into: &payloads)

        case Function.paintRegion:
            paintRegion(body, objects: objects, into: &payloads)

        case Function.frameRegion:
            frameRegion(body, objects: objects, into: &payloads)

        case Function.invertRegion:
            invertRegion(body, objects: objects, into: &payloads)

        // MARK: Everything else — log type and skip (§8). Covers
        // META_OFFSETCLIPRGN, the palette-manipulation records, and any record
        // with no shared-model analogue.
        default:
            payloads.append(.unimplemented(type: UInt32(function)))
        }
    }

    // MARK: - Object table ([MS-WMF] §3.1.4.1)

    /// A region extracted from a META_CREATEREGION Region Object ([MS-WMF]
    /// §2.2.1.5): its bounding rectangle and the union of per-scanline rectangles
    /// the region's scans define. Held per table slot so the region records
    /// (SELECTCLIPREGION, FILLREGION, …) can resolve their Region index.
    private struct RegionShape: Equatable {
        var bounds: RectL
        var rects: [RectL]
    }

    /// The lowest-free-index object table, plus the window/viewport shadow the
    /// relative state records (OFFSET*, SCALE*) and the save-depth tracking need.
    private struct ObjectTable {
        /// Occupancy as a fixed `objectTableCap`-bit set (64 UInt64 words), so
        /// the lowest-free-index allocation is O(words) and the full-table case is
        /// O(1) — no per-create scan that a hostile create/free stream could blow
        /// up to minutes at `recordCountLimit` records (§8: bounded time).
        private var occupiedWords = [UInt64](repeating: 0, count: objectTableCap / 64)
        /// Live object count: the fail-fast test for a full table.
        private var occupiedCount = 0
        private var renderable: Set<Int> = []
        /// Slot → the CharSet of the font created there ([MS-WMF] §2.2.1.2), so
        /// a SELECTOBJECT of the slot can update the current text encoding.
        private var fontCharSets: [Int: UInt8] = [:]
        /// Slot → the region created there (META_CREATEREGION), for the region
        /// records that reference a Region index.
        var regions: [Int: RegionShape] = [:]
        /// The CharSet of the currently selected font ([MS-WMF] §2.2.1.5):
        /// decodes the 8-bit TEXTOUT/EXTTEXTOUT strings. ANSI_CHARSET default.
        var currentCharSet: UInt8 = 0
        var saveDepth = 0

        // Window/viewport shadow, seeded by the page-setup preamble so the
        // relative records resolve to absolute values the DC can consume.
        var windowOrg = PointL(x: 0, y: 0)
        var windowExt = SizeL(cx: 1, cy: 1)
        var viewportOrg = PointL(x: 0, y: 0)
        var viewportExt = SizeL(cx: 1, cy: 1)

        /// Allocates the lowest free index, preserving lowest-free-index
        /// semantics. A full table fails fast in O(1); otherwise the lowest word
        /// with a free bit yields the lowest free index via `trailingZeroBitCount`
        /// — bounded work regardless of the create/free pattern (§8). Returns
        /// `nil` at the cap (the caller logs and skips).
        mutating func allocate(
            renderable isRenderable: Bool,
            into payloads: inout [EMFRecordPayload]
        ) -> Int? {
            guard occupiedCount < objectTableCap else {
                payloads.append(.unimplemented(type: 0xFFFF))
                return nil
            }
            // A word with a free bit exists because the table is not full; scan
            // past the full words (at most 64) to it.
            var word = 0
            while word < occupiedWords.count, occupiedWords[word] == .max { word += 1 }
            guard word < occupiedWords.count else {
                // Unreachable while occupiedCount is consistent; fail safe (§8).
                payloads.append(.unimplemented(type: 0xFFFF))
                return nil
            }
            let bit = (~occupiedWords[word]).trailingZeroBitCount
            let index = word * 64 + bit
            occupiedWords[word] |= UInt64(1) << bit
            occupiedCount += 1
            if isRenderable { renderable.insert(index) }
            return index
        }

        /// Frees a slot and reports whether it held a renderable object (so the
        /// caller emits a matching EMR_DELETEOBJECT only for those). Also clears
        /// any font-charset or region bound to the slot; the current text
        /// encoding is unaffected (a selected font is a value copy in the DC).
        mutating func free(_ index: Int) -> (occupied: Bool, renderable: Bool) {
            let wasRenderable = renderable.remove(index) != nil
            fontCharSets[index] = nil
            regions[index] = nil
            guard index >= 0, index < objectTableCap else { return (false, wasRenderable) }
            let mask = UInt64(1) << (index % 64)
            let wasOccupied = occupiedWords[index / 64] & mask != 0
            if wasOccupied {
                occupiedWords[index / 64] &= ~mask
                occupiedCount -= 1
            }
            return (wasOccupied, wasRenderable)
        }

        func isRenderable(_ index: Int) -> Bool { renderable.contains(index) }

        /// Records the CharSet of a font created at `index`.
        mutating func registerFont(_ index: Int, charSet: UInt8) {
            fontCharSets[index] = charSet
        }

        /// Updates the current text encoding when `index` names a font slot;
        /// non-font selections leave it unchanged.
        mutating func selectFont(_ index: Int) {
            if let charSet = fontCharSets[index] { currentCharSet = charSet }
        }

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
        // Selecting a font slot updates the encoding the next TEXTOUT decodes in.
        objects.selectFont(index)
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

    // MARK: - Text ([MS-WMF] §2.2.1.2, §2.3.3.20, §2.3.3.5)

    /// META_CREATEFONTINDIRECT ([MS-WMF] §2.3.4.2): a 16-bit Font Object
    /// (§2.2.1.2) translated to the shared LOGFONT so the existing FontMapper /
    /// TextDrawer path draws it. The slot is consumed either way — a renderable
    /// font when the object parses, otherwise an inert slot — so the file's
    /// object numbering stays correct.
    private static func createFont(
        _ body: WMFByteReader,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        if let logFont = readFont(body) {
            guard let index = objects.allocate(renderable: true, into: &payloads) else { return }
            objects.registerFont(index, charSet: logFont.charSet)
            payloads.append(.extCreateFontIndirectW(ExtCreateFontPayload(
                ihFonts: UInt32(index + 1),
                logFont: logFont,
                hasExtendedData: false
            )))
        } else {
            _ = objects.allocate(renderable: false, into: &payloads)
            payloads.append(.unimplemented(type: UInt32(Function.createFontIndirect)))
        }
    }

    /// Decodes a 16-bit Font Object ([MS-WMF] §2.2.1.2) into the shared LogFont:
    /// an 18-byte fixed part, then a NUL-terminated Latin-1 Facename of up to 32
    /// bytes. The 16-bit metrics widen to the LogFont's Int32 fields. Returns nil
    /// on a short record.
    private static func readFont(_ body: WMFByteReader) -> LogFont? {
        guard let height = body.readInt16(at: 0),
              let width = body.readInt16(at: 2),
              let escapement = body.readInt16(at: 4),
              let orientation = body.readInt16(at: 6),
              let weight = body.readInt16(at: 8),
              let italic = body.readUInt8(at: 10),
              let underline = body.readUInt8(at: 11),
              let strikeOut = body.readUInt8(at: 12),
              let charSet = body.readUInt8(at: 13),
              let outPrecision = body.readUInt8(at: 14),
              let clipPrecision = body.readUInt8(at: 15),
              let quality = body.readUInt8(at: 16),
              let pitchAndFamily = body.readUInt8(at: 17)
        else { return nil }
        return LogFont(
            height: Int32(height), width: Int32(width),
            escapement: Int32(escapement), orientation: Int32(orientation),
            weight: Int32(weight),
            italic: italic, underline: underline, strikeOut: strikeOut,
            charSet: charSet, outPrecision: outPrecision,
            clipPrecision: clipPrecision, quality: quality,
            pitchAndFamily: pitchAndFamily, faceName: readFaceName(body, at: 18)
        )
    }

    /// Facename ([MS-WMF] §2.2.1.2): up to 32 NUL-terminated 8-bit Latin-1
    /// characters. Latin-1 maps every byte, so this never fails or drops bytes.
    private static func readFaceName(_ body: WMFByteReader, at offset: Int) -> String {
        var units: [UInt8] = []
        for i in 0 ..< 32 {
            guard let byte = body.readUInt8(at: offset + i), byte != 0 else { break }
            units.append(byte)
        }
        return String(bytes: units, encoding: .isoLatin1) ?? ""
    }

    /// META_TEXTOUT ([MS-WMF] §2.3.3.20): StringLength, the even-padded 8-bit
    /// String, then YStart, XStart (reversed). The string decodes through the
    /// current font's CharSet into the shared EXTTEXTOUTW payload.
    private static func textOut(
        _ body: WMFByteReader,
        payloadBytes: Int,
        charSet: UInt8,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let rawLength = body.readInt16(at: 0), rawLength >= 0 else { return }
        let length = Int(rawLength)
        let padded = (length + 1) & ~1
        // StringLength(2) + padded String + YStart(2) + XStart(2) must fit (§8).
        guard 2 + padded + 4 <= payloadBytes,
              let stringData = body.data(at: 2, length: length),
              let y = body.readInt16(at: 2 + padded),
              let x = body.readInt16(at: 2 + padded + 2)
        else { return }
        payloads.append(.extTextOutW(makeText(
            reference: PointL(x: Int32(x), y: Int32(y)),
            rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0),
            string: decodeANSIString(stringData, charSet: charSet),
            options: 0, dx: nil
        )))
    }

    /// META_EXTTEXTOUT ([MS-WMF] §2.3.3.5): Y, X, StringLength, fwOpts, an
    /// optional clip/opaque Rectangle (present only when ETO_CLIPPED/ETO_OPAQUE
    /// is set), the even-padded 8-bit String, and an optional Dx advance array.
    /// All offsets and counts are validated against the record size before use.
    private static func extTextOut(
        _ body: WMFByteReader,
        payloadBytes: Int,
        charSet: UInt8,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let y = body.readInt16(at: 0), let x = body.readInt16(at: 2),
              let rawLength = body.readInt16(at: 4), rawLength >= 0,
              let fwOpts = body.readUInt16(at: 6)
        else { return }
        let length = Int(rawLength)
        let options = ExtTextOutOptions(rawValue: UInt32(fwOpts))

        // The optional Rectangle (a Rect Object, §2.2.2.18: Left, Top, Right,
        // Bottom — NOT reversed) is present only when ETO_OPAQUE/ETO_CLIPPED set.
        var rectangle = RectL(left: 0, top: 0, right: 0, bottom: 0)
        var stringOffset = 8
        if options.opaque || options.clipped {
            guard let left = body.readInt16(at: 8), let top = body.readInt16(at: 10),
                  let right = body.readInt16(at: 12), let bottom = body.readInt16(at: 14)
            else { return }
            rectangle = RectL(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom))
            stringOffset = 16
        }

        let padded = (length + 1) & ~1
        guard stringOffset + padded <= payloadBytes,
              let stringData = body.data(at: stringOffset, length: length)
        else { return }

        // Optional Dx: StringLength 16-bit advances after the padded string,
        // present only when the record has room for them (§8).
        var dx: [UInt32]? = nil
        let dxOffset = stringOffset + padded
        if length > 0, dxOffset + length * 2 <= payloadBytes {
            var values: [UInt32] = []
            values.reserveCapacity(length)
            var ok = true
            for i in 0 ..< length {
                guard let advance = body.readInt16(at: dxOffset + i * 2) else { ok = false; break }
                // WMF Dx are non-negative cell advances; clamp any stray sign.
                values.append(UInt32(max(0, Int(advance))))
            }
            if ok { dx = values }
        }

        payloads.append(.extTextOutW(makeText(
            reference: PointL(x: Int32(x), y: Int32(y)),
            rectangle: rectangle,
            string: decodeANSIString(stringData, charSet: charSet),
            options: UInt32(fwOpts), dx: dx
        )))
    }

    /// Builds the shared EXTTEXTOUTW payload for a WMF run: GM_COMPATIBLE with a
    /// unit page scale, since the WMF logical→device mapping is carried entirely
    /// by the preamble and window/viewport records (as for geometry).
    private static func makeText(
        reference: PointL, rectangle: RectL, string: String, options: UInt32, dx: [UInt32]?
    ) -> ExtTextPayload {
        ExtTextPayload(
            graphicsMode: 1, exScale: 1, eyScale: 1,
            reference: reference, rectangle: rectangle,
            string: string, options: ExtTextOutOptions(rawValue: options), dx: dx
        )
    }

    /// Decodes an 8-bit WMF string through the font's CharSet ([MS-WMF]
    /// §2.3.3.5's CharSet→codepage table). An undecodable run degrades to a
    /// lossless Latin-1 reading (every byte maps) rather than being dropped (§8).
    private static func decodeANSIString(_ bytes: Data, charSet: UInt8) -> String {
        guard !bytes.isEmpty else { return "" }
        let codepage = windowsCodepage(forCharSet: charSet)
        let cfEncoding = CFStringConvertWindowsCodepageToEncoding(codepage)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding)) {
                return decoded
            }
        }
        return String(data: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Maps a CharSet ([MS-WMF] §2.1.1.5) to its Windows codepage ([MS-WMF]
    /// §2.3.3.5's table). ANSI/DEFAULT/SYMBOL and any unlisted value use 1252.
    private static func windowsCodepage(forCharSet charSet: UInt8) -> UInt32 {
        switch charSet {
        case 128: return 932     // SHIFTJIS
        case 129: return 949     // HANGUL / HANGEUL
        case 130: return 1361    // JOHAB
        case 134: return 936     // GB2312
        case 136: return 950     // CHINESEBIG5
        case 161: return 1253    // GREEK
        case 162: return 1254    // TURKISH
        case 163: return 1258    // VIETNAMESE
        case 177: return 1255    // HEBREW
        case 178: return 1256    // ARABIC
        case 186: return 1257    // BALTIC
        case 204: return 1251    // RUSSIAN
        case 222: return 874     // THAI
        case 238: return 1250    // EASTEUROPE
        case 255: return 437     // OEM
        default:  return 1252    // ANSI / DEFAULT / SYMBOL / others
        }
    }

    // MARK: - Bitmaps ([MS-WMF] §2.3.1)

    private static let identityXForm = XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 0, dy: 0)

    /// META_STRETCHDIB ([MS-WMF] §2.3.1.6): a stretched DIB blit. The packed DIB
    /// decodes through the shared decoder and plays as EMR_STRETCHDIBITS.
    private static func stretchDIB(
        _ body: WMFByteReader,
        payloadBytes: Int,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let rop = body.readUInt32(at: 0),
              let colorUsage = body.readUInt16(at: 4),
              let srcH = body.readInt16(at: 6), let srcW = body.readInt16(at: 8),
              let ySrc = body.readInt16(at: 10), let xSrc = body.readInt16(at: 12),
              let destH = body.readInt16(at: 14), let destW = body.readInt16(at: 16),
              let yDst = body.readInt16(at: 18), let xDst = body.readInt16(at: 20)
        else { return }
        guard let dib = extractDIB(body, offset: 22, payloadBytes: payloadBytes) else {
            payloads.append(.unimplemented(type: UInt32(Function.stretchDIB)))
            return
        }
        payloads.append(.stretchDIBits(StretchDIBitsPayload(
            bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
            dest: PointL(x: Int32(xDst), y: Int32(yDst)),
            destSize: SizeL(cx: Int32(destW), cy: Int32(destH)),
            src: PointL(x: Int32(xSrc), y: Int32(ySrc)),
            srcSize: SizeL(cx: Int32(srcW), cy: Int32(srcH)),
            usageSrc: UInt32(colorUsage),
            rasterOperation: rop,
            dib: dib
        )))
    }

    /// META_SETDIBTODEV ([MS-WMF] §2.3.1.4): sets a block of scanlines from a DIB.
    /// All geometry fields are unsigned.
    private static func setDIBToDev(
        _ body: WMFByteReader,
        payloadBytes: Int,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let colorUsage = body.readUInt16(at: 0),
              let scanCount = body.readUInt16(at: 2),
              let startScan = body.readUInt16(at: 4),
              let yDib = body.readUInt16(at: 6), let xDib = body.readUInt16(at: 8),
              let height = body.readUInt16(at: 10), let width = body.readUInt16(at: 12),
              let yDest = body.readUInt16(at: 14), let xDest = body.readUInt16(at: 16)
        else { return }
        guard let dib = extractDIB(body, offset: 18, payloadBytes: payloadBytes) else {
            payloads.append(.unimplemented(type: UInt32(Function.setDIBToDev)))
            return
        }
        payloads.append(.setDIBitsToDevice(SetDIBitsToDevicePayload(
            bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
            dest: PointL(x: Int32(xDest), y: Int32(yDest)),
            src: PointL(x: Int32(xDib), y: Int32(yDib)),
            srcSize: SizeL(cx: Int32(width), cy: Int32(height)),
            usageSrc: UInt32(colorUsage),
            startScan: UInt32(startScan),
            scanCount: UInt32(scanCount),
            dib: dib
        )))
    }

    /// META_DIBBITBLT / META_DIBSTRETCHBLT ([MS-WMF] §2.3.1.2/.3): a DIB blit,
    /// with-bitmap (EMR_BITBLT/EMR_STRETCHBLT) or without-bitmap (a sourceless
    /// rop fill, dib = nil).
    private static func dibBlt(
        _ body: WMFByteReader,
        record: WMFRawRecord,
        stretch: Bool,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let geometry = readBltGeometry(body, record: record, stretch: stretch) else { return }
        var dib: DIB? = nil
        if geometry.hasBitmap {
            guard let decoded = extractDIB(body, offset: geometry.dibOffset, payloadBytes: record.payloadByteCount) else {
                payloads.append(.unimplemented(type: UInt32(record.function)))
                return
            }
            dib = decoded
        }
        emitBlt(geometry, dib: dib, stretch: stretch, into: &payloads)
    }

    /// META_BITBLT / META_STRETCHBLT ([MS-WMF] §2.3.1.1/.5): a DDB blit carrying
    /// a Bitmap16 (§2.2.2.1). The source is converted to the shared DIB model for
    /// the well-defined depths; unsupported depths are logged and skipped.
    private static func ddbBlt(
        _ body: WMFByteReader,
        record: WMFRawRecord,
        stretch: Bool,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let geometry = readBltGeometry(body, record: record, stretch: stretch) else { return }
        var dib: DIB? = nil
        if geometry.hasBitmap {
            guard let converted = ddbToDIB(body, offset: geometry.dibOffset, payloadBytes: record.payloadByteCount) else {
                payloads.append(.unimplemented(type: UInt32(record.function)))
                return
            }
            dib = converted
        }
        emitBlt(geometry, dib: dib, stretch: stretch, into: &payloads)
    }

    /// The shared geometry of the four blt records ([MS-WMF] §2.3.1.1–.3/.5):
    /// RasterOperation, source/destination origins and sizes, and the offset of
    /// the embedded bitmap. The without-bitmap form replaces the source origin
    /// with a Reserved WORD, shifting the later fields by one WORD.
    private struct BltGeometry {
        var rop: UInt32
        var src: PointL
        var dest: PointL
        var destSize: SizeL
        var srcSize: SizeL?
        var dibOffset: Int
        var hasBitmap: Bool
    }

    private static func readBltGeometry(_ body: WMFByteReader, record: WMFRawRecord, stretch: Bool) -> BltGeometry? {
        let hasBitmap = !isSourceless(record)
        guard let rop = body.readUInt32(at: 0) else { return nil }
        if stretch {
            guard let srcH = body.readInt16(at: 4), let srcW = body.readInt16(at: 6),
                  let ySrc = body.readInt16(at: 8), let xSrc = body.readInt16(at: 10)
            else { return nil }
            let d = hasBitmap ? 12 : 14   // a Reserved WORD precedes dest when sourceless
            guard let destH = body.readInt16(at: d), let destW = body.readInt16(at: d + 2),
                  let yDest = body.readInt16(at: d + 4), let xDest = body.readInt16(at: d + 6)
            else { return nil }
            return BltGeometry(
                rop: rop,
                src: PointL(x: Int32(xSrc), y: Int32(ySrc)),
                dest: PointL(x: Int32(xDest), y: Int32(yDest)),
                destSize: SizeL(cx: Int32(destW), cy: Int32(destH)),
                srcSize: SizeL(cx: Int32(srcW), cy: Int32(srcH)),
                dibOffset: d + 8, hasBitmap: hasBitmap
            )
        } else {
            let s = hasBitmap ? 4 : 6   // a Reserved WORD precedes the source when sourceless
            guard let ySrc = body.readInt16(at: s), let xSrc = body.readInt16(at: s + 2),
                  let height = body.readInt16(at: s + 4), let width = body.readInt16(at: s + 6),
                  let yDest = body.readInt16(at: s + 8), let xDest = body.readInt16(at: s + 10)
            else { return nil }
            return BltGeometry(
                rop: rop,
                src: PointL(x: Int32(xSrc), y: Int32(ySrc)),
                dest: PointL(x: Int32(xDest), y: Int32(yDest)),
                destSize: SizeL(cx: Int32(width), cy: Int32(height)),
                srcSize: nil,
                dibOffset: s + 12, hasBitmap: hasBitmap
            )
        }
    }

    private static func emitBlt(
        _ geometry: BltGeometry, dib: DIB?, stretch: Bool, into payloads: inout [EMFRecordPayload]
    ) {
        let payload = BitBltPayload(
            bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
            dest: geometry.dest,
            destSize: geometry.destSize,
            rasterOperation: geometry.rop,
            src: geometry.src,
            xformSrc: identityXForm,
            bkColorSrc: ColorRef(red: 0, green: 0, blue: 0),
            usageSrc: 0,
            srcSize: geometry.srcSize,
            dib: dib
        )
        payloads.append(stretch ? .stretchBlt(payload) : .bitBlt(payload))
    }

    /// The RecordSize/RecordFunction test for the without-bitmap blt form
    /// ([MS-WMF] §2.3.1.1–.3/.5): a source bitmap is absent when
    /// `RecordSize == (RecordFunction >> 8) + 3`.
    private static func isSourceless(_ record: WMFRawRecord) -> Bool {
        record.sizeWords == UInt32(record.function >> 8) + 3
    }

    /// Slices the packed DIB tail of a bitmap record ([MS-WMF] §2.2.2.9) and
    /// decodes it through the shared DIB decoder. Returns nil when the tail is
    /// absent or the DIB is malformed (the caller logs and skips).
    private static func extractDIB(_ body: WMFByteReader, offset: Int, payloadBytes: Int) -> DIB? {
        guard offset >= 0, offset <= payloadBytes,
              let data = body.data(at: offset, length: payloadBytes - offset)
        else { return nil }
        if case .decoded(let dib) = EMFFile.decodePackedDIB(data) { return dib }
        return nil
    }

    /// Converts the Bitmap16 Object ([MS-WMF] §2.2.2.1) tail of a DDB blit into
    /// the shared DIB model for the well-defined depths: 1 bpp mono expanded to
    /// 24-bit (a set bit → white, a clear bit → black), and 24/32 bpp mapped
    /// straight through (BGR / BGRX, top-down). Other depths return nil. All
    /// dimensions are validated against the §8 caps before any allocation.
    private static func ddbToDIB(_ body: WMFByteReader, offset: Int, payloadBytes: Int) -> DIB? {
        guard let width16 = body.readInt16(at: offset + 2),
              let height16 = body.readInt16(at: offset + 4),
              let widthBytes16 = body.readInt16(at: offset + 6),
              let planes = body.readUInt8(at: offset + 8),
              let bitsPixel = body.readUInt8(at: offset + 9)
        else { return nil }
        let width = Int(width16), height = Int(height16), stride = Int(widthBytes16)
        guard planes == 1, width > 0, height > 0, stride > 0,
              width <= ddbDimensionCap, height <= ddbDimensionCap,
              width <= ddbAreaCap / height
        else { return nil }
        // Bits length per §2.2.2.1; validated against the record before reading.
        guard let bits = body.data(at: offset + 10, length: stride * height) else { return nil }

        switch bitsPixel {
        case 24:
            return DIB(width: Int32(width), height: Int32(-height), bitCount: 24,
                       compression: .rgb, content: .pixels(bytes: bits, stride: stride, palette: []))
        case 32:
            return DIB(width: Int32(width), height: Int32(-height), bitCount: 32,
                       compression: .rgb, content: .pixels(bytes: bits, stride: stride, palette: []))
        case 1:
            return expandMonoDDB(Array(bits), width: width, height: height, stride: stride)
        default:
            return nil
        }
    }

    /// Expands a 1 bpp top-down mono Bitmap16 to a 24-bit top-down DIB (a set bit
    /// → white, a clear bit → black). Rows are repacked to a 4-byte DIB stride.
    private static func expandMonoDDB(_ bits: [UInt8], width: Int, height: Int, stride: Int) -> DIB? {
        let outStride = ((width * 24 + 31) / 32) * 4
        var out = [UInt8](repeating: 0, count: outStride * height)
        for row in 0 ..< height {
            let rowBase = row * stride
            let outBase = row * outStride
            for x in 0 ..< width {
                let byteIndex = rowBase + (x >> 3)
                guard byteIndex < bits.count else { continue }
                let value: UInt8 = (bits[byteIndex] >> (7 - (x & 7))) & 1 == 1 ? 255 : 0
                let o = outBase + x * 3
                out[o] = value; out[o + 1] = value; out[o + 2] = value
            }
        }
        return DIB(width: Int32(width), height: Int32(-height), bitCount: 24,
                   compression: .rgb, content: .pixels(bytes: Data(out), stride: outStride, palette: []))
    }

    // MARK: - Pattern brushes ([MS-WMF] §2.3.4.4/.8)

    /// META_CREATEPATTERNBRUSH / META_DIBCREATEPATTERNBRUSH: the shared model has
    /// no pattern brush, so — exactly as the EMF path does for an unsupported
    /// brush style — a non-solid brush is created in the slot and the renderer's
    /// ObjectResolver logs it and falls back to a solid fill. The approximation
    /// colour is a neutral mid-grey (a pattern averaged to one tone).
    private static func createPatternBrush(
        function: UInt16,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let index = objects.allocate(renderable: true, into: &payloads) else { return }
        // BS_PATTERN (3) / BS_DIBPATTERNPT (5): both are unsupported styles the
        // ObjectResolver logs and degrades to a solid fill.
        let style: UInt32 = function == Function.createPatternBrush ? 3 : 5
        payloads.append(.createBrushIndirect(CreateBrushPayload(
            ihBrush: UInt32(index + 1),
            style: style,
            color: ColorRef(red: 0x80, green: 0x80, blue: 0x80),
            hatch: 0
        )))
    }

    // MARK: - Regions ([MS-WMF] §2.2.1.5, §2.3.3/.4)

    /// Stock handles ([MS-EMF] §2.1.31) used while painting a region: NULL_PEN
    /// suppresses the outline, GRAY_BRUSH approximates an inversion.
    private static let nullPenHandle: UInt32 = 0x8000_0008
    private static let grayBrushHandle: UInt32 = 0x8000_0002

    /// META_CREATEREGION ([MS-WMF] §2.3.4.6): parses the Region Object's scans
    /// into a rectangle union stored in the slot it consumes, for the region
    /// records to reference. The slot is inert in the DC (regions are not
    /// pen/brush/font objects); creating a region draws nothing.
    private static func createRegion(
        _ body: WMFByteReader,
        payloadBytes: Int,
        objects: inout ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let index = objects.allocate(renderable: false, into: &payloads) else { return }
        if let shape = readRegion(body, payloadBytes: payloadBytes) {
            objects.regions[index] = shape
        }
    }

    /// Decodes a Region Object ([MS-WMF] §2.2.1.5): a 22-byte fixed part then
    /// ScanCount Scan Objects (§2.2.2.21). Each scan is a band [Top, Bottom) with
    /// (Left, Right) x-spans; the result is their rectangle union. Every count is
    /// validated against the remaining bytes before a rect is appended, and the
    /// union is capped at `regionRectCap` (§8).
    private static func readRegion(_ body: WMFByteReader, payloadBytes: Int) -> RegionShape? {
        guard payloadBytes >= 22,
              let scanCount16 = body.readInt16(at: 10), scanCount16 >= 0,
              let left = body.readInt16(at: 14), let top = body.readInt16(at: 16),
              let right = body.readInt16(at: 18), let bottom = body.readInt16(at: 20)
        else { return nil }
        let bounds = RectL(left: Int32(left), top: Int32(top), right: Int32(right), bottom: Int32(bottom))
        var rects: [RectL] = []
        var offset = 22
        for _ in 0 ..< Int(scanCount16) {
            // Scan header: Count(2), Top(2), Bottom(2), then Count x-coords, then
            // a trailing Count2(2).
            guard offset + 6 <= payloadBytes,
                  let count = body.readUInt16(at: offset),
                  let scanTop = body.readUInt16(at: offset + 2),
                  let scanBottom = body.readUInt16(at: offset + 4)
            else { break }
            let points = Int(count)
            guard offset + 6 + points * 2 + 2 <= payloadBytes else { break }
            var pair = 0
            while pair + 1 < points {
                guard let l = body.readUInt16(at: offset + 6 + pair * 2),
                      let r = body.readUInt16(at: offset + 6 + pair * 2 + 2)
                else { break }
                rects.append(RectL(left: Int32(l), top: Int32(scanTop), right: Int32(r), bottom: Int32(scanBottom)))
                if rects.count >= regionRectCap { return RegionShape(bounds: bounds, rects: rects) }
                pair += 2
            }
            offset += 6 + points * 2 + 2
        }
        return RegionShape(bounds: bounds, rects: rects)
    }

    /// Resolves a Region index field to its stored shape, or nil when the index
    /// is a stock handle, out of range, or names no region.
    private static func resolveRegion(_ body: WMFByteReader, at offset: Int, objects: ObjectTable) -> RegionShape? {
        guard let raw = body.readUInt16(at: offset), raw & 0x8000 == 0 else { return nil }
        return objects.regions[Int(raw)]
    }

    /// META_SELECTCLIPREGION ([MS-WMF] §2.3.4.9): replaces the clip with the
    /// referenced region (RGN_COPY). An unknown slot is logged and skipped.
    private static func selectClipRegion(
        _ body: WMFByteReader,
        objects: ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let region = resolveRegion(body, at: 0, objects: objects) else {
            payloads.append(.unimplemented(type: UInt32(Function.selectClipRegion)))
            return
        }
        payloads.append(.extSelectClipRgn(ExtSelectClipRgnPayload(
            mode: .copy, bounds: region.bounds, rects: region.rects
        )))
    }

    /// META_PAINTREGION ([MS-WMF] §2.3.3.11): fills the region with the CURRENT
    /// brush — a save / NULL_PEN / filled-rects / restore sequence that leaves no
    /// outline and restores the DC.
    private static func paintRegion(
        _ body: WMFByteReader,
        objects: ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let region = resolveRegion(body, at: 0, objects: objects) else { return }
        emitRegionFill(region.rects, brushSelect: nil, into: &payloads)
    }

    /// META_FILLREGION ([MS-WMF] §2.3.3.6): fills the region with the specified
    /// brush (Region index, then Brush index).
    private static func fillRegion(
        _ body: WMFByteReader,
        objects: ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let region = resolveRegion(body, at: 0, objects: objects) else { return }
        emitRegionFill(region.rects, brushSelect: selectHandle(for: body.readUInt16(at: 2)), into: &payloads)
    }

    /// META_FRAMEREGION ([MS-WMF] §2.3.3.8): draws a Height×Width border around
    /// the region with the specified brush, approximated by filling the four
    /// border strips of each region rectangle.
    private static func frameRegion(
        _ body: WMFByteReader,
        objects: ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let region = resolveRegion(body, at: 0, objects: objects),
              let height = body.readInt16(at: 4), let width = body.readInt16(at: 6)
        else { return }
        var borderRects: [RectL] = []
        for rect in region.rects {
            borderRects.append(contentsOf: frameRects(rect, frameW: Int32(width), frameH: Int32(height)))
            if borderRects.count >= regionRectCap { break }
        }
        emitRegionFill(borderRects, brushSelect: selectHandle(for: body.readUInt16(at: 2)), into: &payloads)
    }

    /// META_INVERTREGION ([MS-WMF] §2.3.3.9): colour inversion has no exact
    /// expression in the shared raster model, so it is APPROXIMATED by painting
    /// the region in a neutral mid-grey (GRAY_BRUSH) — a visible best-effort
    /// marker, the same way the EMF path degrades a rop it cannot honour (§8).
    private static func invertRegion(
        _ body: WMFByteReader,
        objects: ObjectTable,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard let region = resolveRegion(body, at: 0, objects: objects) else { return }
        emitRegionFill(
            region.rects,
            brushSelect: .selectObject(ObjectHandle(raw: grayBrushHandle)),
            into: &payloads
        )
    }

    /// The four border strips (top, bottom, left, right) of `rect` for a frame of
    /// the given logical thickness. 16-bit operands widen before adding so a
    /// corner cannot overflow (§8).
    private static func frameRects(_ rect: RectL, frameW: Int32, frameH: Int32) -> [RectL] {
        let fw = max(0, frameW), fh = max(0, frameH)
        guard fw > 0 || fh > 0 else { return [] }
        return [
            RectL(left: rect.left, top: rect.top, right: rect.right, bottom: rect.top &+ fh),
            RectL(left: rect.left, top: rect.bottom &- fh, right: rect.right, bottom: rect.bottom),
            RectL(left: rect.left, top: rect.top, right: rect.left &+ fw, bottom: rect.bottom),
            RectL(left: rect.right &- fw, top: rect.top, right: rect.right, bottom: rect.bottom),
        ]
    }

    /// Emits a balanced save / NULL_PEN (+ optional brush) / filled-rectangles /
    /// restore sequence that paints `rects` with no outline and restores the DC.
    /// The save/restore pair is net-zero on the DC save stack.
    private static func emitRegionFill(
        _ rects: [RectL],
        brushSelect: EMFRecordPayload?,
        into payloads: inout [EMFRecordPayload]
    ) {
        guard !rects.isEmpty else { return }
        payloads.append(.saveDC)
        payloads.append(.selectObject(ObjectHandle(raw: nullPenHandle)))
        if let brushSelect { payloads.append(brushSelect) }
        for rect in rects { payloads.append(.rectangle(box: rect)) }
        payloads.append(.restoreDC(savedDC: -1))
    }

    /// A SELECTOBJECT payload for a WMF object index (a stock handle when the
    /// high bit is set; otherwise the EMF table slot index + 1).
    private static func selectHandle(for raw: UInt16?) -> EMFRecordPayload? {
        guard let raw else { return nil }
        if raw & 0x8000 != 0 {
            return .selectObject(ObjectHandle(raw: 0x8000_0000 | UInt32(raw & 0x7FFF)))
        }
        return .selectObject(.table(index: UInt32(Int(raw) + 1)))
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
