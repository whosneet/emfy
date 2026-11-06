import CoreGraphics
import CoreText
import EMFParse
import Foundation

/// The page background a bitmap render starts from (S1a Export › PNG
/// background). `.white` fills the canvas opaque white first, exactly as every
/// render did before this option existed — a metafile carries no page
/// background of its own, so white is the default and preserves byte-identical
/// output. `.transparent` skips that fill, leaving the canvas's alpha channel
/// clear so the drawing sits on transparency. Bitmap renders only; the PDF path
/// and in-context playback are unchanged.
public enum RenderBackground: Sendable {
    case white
    case transparent
}

/// The EMF playback engine, phase-2 record set: DC state, object table, and
/// core + 16-bit geometry played into a caller-supplied `CGContext`.
///
/// Rendering NEVER fails. Every record the renderer cannot fully honour —
/// unimplemented types, malformed payloads, unsupported styles or modes,
/// deferred clipping — is a log entry plus the best partial output
/// (primer §8, §10.8).
public enum EMFRenderer {

    /// `makeImage` canvas cap per side: hostile headers can declare absurd
    /// bounds; anything larger is clamped with a `canvasClamped` log entry.
    public static let canvasDimensionCap = 16_384

    /// `makeImage` canvas cap on TOTAL area, in pixels. The per-side cap alone
    /// still permits a ~16384×16384 ≈ 268 Mpx (≈1 GiB RGBA) allocation from a
    /// hostile header; this bounds the whole canvas to 32 Mpx (≈128 MiB RGBA).
    /// When the per-side-clamped canvas still exceeds this, both sides scale
    /// down together (aspect ratio preserved) and a `canvasClamped` entry
    /// records it (primer §8).
    public static let canvasAreaCap = 32_000_000

    // MARK: - Public API

    /// Plays `file`'s records into `context`, mapping the file's device space
    /// (header `rclBounds`, inclusive-inclusive) onto `target`.
    ///
    /// The context's state is saved and restored around playback; nothing but
    /// pixels leaks into the caller's context. The single y-flip between
    /// EMF's y-down device space and CoreGraphics' y-up space happens here,
    /// once, at canvas level.
    public static func render(
        _ file: EMFFile,
        into context: CGContext,
        target: CGRect,
        options: RenderOptions = .default,
        observer: RenderObserver? = nil,
        emfPlusDrawFilter: Set<Int>? = nil
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let base = deviceToTarget(header: file.header, target: target, log: &log)
        var dc = DeviceContext(header: file.header, fontSubstitutions: options.fontSubstitutions)

        context.saveGState()
        defer { context.restoreGState() }

        // Crisp antialiasing (option 1): turn it off once at canvas level, inside
        // the outer save. The GDI draw helpers each save/restore their own gstate,
        // so they inherit and preserve this; EMF+ draws re-assert it per draw
        // (overriding any file SetAntiAliasMode). Set only for `.crisp`, so
        // `.smooth` output stays byte-identical.
        if options.antialiasing == .crisp {
            context.setShouldAntialias(false)
        }

        // EMF+ arbitration ([MS-EMFPLUS] §1.3.1): when the EMF+ stream carries
        // at least one DRAWING record, the file plays in EMF+ mode regardless of
        // the Dual flag — EMF+ records drive output and GDI records play only
        // inside a GetDC window. A file with no EMF+ drawing records (a pure-GDI
        // file, or an EMF+ shell) takes the unchanged GDI path below, so every
        // existing output stays byte-identical.
        let plus = file.emfPlusStream()
        // Surface EMF+ stream reassembly/walk diagnostics REGARDLESS of branch
        // (audit M7): a dual file whose EMF+ stream died still renders its GDI
        // fallback, but the log must say the EMF+ half was broken. A pure-GDI
        // file has no EMF+ comments → no diagnostics → this is a no-op.
        for diagnostic in plus.diagnostics {
            log.noteEMFPlusStreamIssue(EMFPlusStreamIssueKind(diagnostic))
        }
        // Option 3 `.gdi`: on an EMF+ DUAL file (EmfPlusHeader Flags Dual bit
        // 0x0001, [MS-EMFPLUS] §2.3.3.3) play the GDI records and ignore EMF+
        // drawing. For an EMF+-only (non-dual) file it has no effect — there is
        // no complete GDI copy — so the EMF+ path still runs. `.emfPlus` (default)
        // leaves `forceGDI` false, so existing output is byte-identical.
        let forceGDI = options.emfPlusArbitration == .gdi && (plus.header?.isDual ?? false)
        if !forceGDI, plus.records.contains(where: \.isDrawing) {
            // EMF+ drives output. When an import observer is attached (slice
            // E1a2), it rides along: EMF+ drawing records lift into `plusEntries`
            // and GDI draws inside a GetDC window attach through `dc.observer`.
            // `emfPlusDrawFilter`, when set, restricts which EMF+ stream indices
            // draw — the scene renderer's per-element replay. Both are nil on a
            // normal render, so output stays byte-identical.
            dc.observer = observer
            observer?.plusMode = true
            EMFPlusPlayback.run(file: file, stream: plus, into: context, dc: &dc, base: base, options: options, log: &log, observer: observer, drawFilter: emfPlusDrawFilter)
            observer?.finalize()
            return log
        }

        // Attach the observer only for the GDI loop (above the EMF+ return), so
        // a GetDC-window GDI draw inside EMF+ playback never reports a stale op.
        dc.observer = observer
        // records[0] is EMR_HEADER — already consumed as file.header, never
        // a playback record. The index is into `file.records` so the import can
        // map an op back to its source record (0 = header).
        for index in file.records.indices.dropFirst() {
            observer?.currentRecordIndex = index
            playGDIRecord(file.payload(of: file.records[index]), into: context, dc: &dc, base: base, log: &log)
        }
        observer?.finalize()
        return log
    }

    /// Plays one already-decoded GDI record into `context`: a state mutation
    /// consumed by the DC, or a drawing record dispatched to `draw`. Shared by
    /// the pure-GDI loop and the EMF+ GetDC-window path so both interpret GDI
    /// records identically (§1.3.1).
    static func playGDIRecord(
        _ payload: EMFRecordPayload,
        into context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        if dc.apply(payload, log: &log) { return }
        draw(payload, into: context, dc: &dc, base: base, log: &log)
    }

    /// Renders `file` into a fresh sRGB 8-bit bitmap sized from the header
    /// bounds (width = right−left+1, height = bottom−top+1, times `scale`),
    /// on a white background.
    ///
    /// The canvas is capped at 16384 per side AND at 32 Mpx total area (the
    /// latter preserving aspect ratio) — hostile headers declaring absurd
    /// bounds are clamped with a log entry. Returns `nil` only if the bitmap
    /// context itself cannot be created (allocation failure); rendering
    /// itself never fails.
    public static func makeImage(
        _ file: EMFFile,
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default
    ) -> (CGImage, EMFRenderLog)? {
        var log = EMFRenderLog()

        // Header bounds are Int32; do the +1 arithmetic in Int64 so a
        // full-range rectangle cannot overflow (§8: no unchecked arithmetic).
        let bounds = file.header.bounds
        let deviceWidth = Int64(bounds.right) - Int64(bounds.left) + 1
        let deviceHeight = Int64(bounds.bottom) - Int64(bounds.top) + 1

        // Caller-supplied scale is sanitised, not logged: garbage in the
        // parameter is not hostile file data.
        let safeScale = scale.isFinite && scale > 0 ? Double(scale) : 1

        let requestedWidth = Double(deviceWidth) * safeScale
        let requestedHeight = Double(deviceHeight) * safeScale
        // Per-side clamp first, then the total-area clamp on the result: a
        // header near the per-side cap on both axes (≈268 Mpx) is brought under
        // the area cap with its aspect ratio preserved.
        let sideWidth = clampDimension(requestedWidth)
        let sideHeight = clampDimension(requestedHeight)
        let (width, height) = clampArea(width: sideWidth, height: sideHeight)
        if Double(width) != requestedWidth || Double(height) != requestedHeight {
            log.note(.canvasClamped(
                requestedWidth: saturatingInt(requestedWidth),
                requestedHeight: saturatingInt(requestedHeight),
                renderedWidth: width,
                renderedHeight: height
            ))
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // A metafile has no page background of its own: `.white` paints one
        // (the historical, byte-identical default); `.transparent` leaves the
        // premultiplied-alpha canvas clear so the drawing sits on transparency.
        if background == .white {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        let renderLog = render(
            file,
            into: context,
            target: CGRect(x: 0, y: 0, width: width, height: height),
            options: options
        )
        // The clamp entry (if any) precedes playback entries. Re-feed the
        // coalesced families through their coalescing helpers so a preceding
        // clamp entry cannot split them into two counted lines.
        for entry in renderLog.entries {
            switch entry {
            case .unimplementedRecord(let type, let count):
                for _ in 0 ..< count { log.noteUnimplemented(type: type) }
            case .unsupportedROP2(let rawMode, let count):
                for _ in 0 ..< count { log.noteUnsupportedROP2(rawMode: rawMode) }
            case .fontSubstituted(let requested, let used, let count):
                for _ in 0 ..< count { log.noteFontSubstituted(requested: requested, used: used) }
            case .stockFontUsed(let rawValue, let count):
                for _ in 0 ..< count { log.noteStockFontUsed(rawValue: rawValue) }
            case .glyphIndexTextSkipped(let count):
                for _ in 0 ..< count { log.noteGlyphIndexTextSkipped() }
            case .unsupportedDIB(let reason, let count):
                for _ in 0 ..< count { log.noteUnsupportedDIB(reason: reason) }
            case .unsupportedRasterOp(let op, let count):
                for _ in 0 ..< count { log.noteUnsupportedRasterOp(rasterOperation: op) }
            case .xformSrcIgnored(let count):
                for _ in 0 ..< count { log.noteXformSrcIgnored() }
            case .dibDownsampled(let count, let worstNative, let worstDecoded):
                for _ in 0 ..< count { log.noteDIBDownsampled(nativePixels: worstNative, decodedPixels: worstDecoded) }
            case .emfPlusUnsupportedRecord(let type, let count):
                for _ in 0 ..< count { log.noteEMFPlusUnsupported(type: type) }
            case .emfPlusApproximated(let feature, let count):
                for _ in 0 ..< count { log.noteEMFPlusApproximated(feature) }
            case .emfPlusStreamIssue(let kind, let count):
                for _ in 0 ..< count { log.noteEMFPlusStreamIssue(kind) }
            case .emfPlusRecordUndecodable(let type, let count):
                for _ in 0 ..< count { log.noteEMFPlusRecordUndecodable(type: type) }
            case .emfPlusObjectIssue(let kind, let count):
                for _ in 0 ..< count { log.noteEMFPlusObjectIssue(kind) }
            case .emfPlusSaveStackCapped(let count):
                for _ in 0 ..< count { log.noteEMFPlusSaveStackCapped() }
            default:
                log.note(entry)
            }
        }
        // Carry the non-Entry EMF+ records-played stat across the re-feed (M17).
        log.addEMFPlusRecordsPlayed(renderLog.emfPlusRecordsPlayed)

        guard let image = context.makeImage() else { return nil }
        return (image, log)
    }

    // MARK: - Canvas mapping

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
    /// [1, canvasDimensionCap], so `width * height` fits Int with no overflow
    /// risk. A no-op when the canvas is already within the area budget.
    private static func clampArea(width: Int, height: Int) -> (width: Int, height: Int) {
        let area = width * height
        guard area > canvasAreaCap else { return (width, height) }
        // scale = sqrt(cap / area) applied to each side keeps the ratio.
        let scale = (Double(canvasAreaCap) / Double(area)).squareRoot()
        let scaledWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        return (scaledWidth, scaledHeight)
    }

    /// A Double → Int conversion that saturates instead of trapping — needed
    /// for log payloads built from hostile arithmetic. `Int(_: Double)` traps
    /// on non-finite input and on values at or beyond 2^63 (note that
    /// `Double(Int.max)` itself rounds up to exactly 2^63, so `>=` is the
    /// correct guard).
    private static func saturatingInt(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? Int.max : Int.min }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    /// The device→target transform: fits the header's device-space rectangle
    /// (inclusive-inclusive, y down) onto `target` (CG space, y up) — the one
    /// place the y-flip happens. Degenerate header bounds fall back to a unit
    /// scale with a `zeroExtentMapping` log entry so the division below is
    /// always sound. Shared with the WMF playback path in `MetafileRenderer`.
    static func deviceToTarget(
        header: EMFHeader,
        target: CGRect,
        log: inout EMFRenderLog
    ) -> CGAffineTransform {
        let bounds = header.bounds
        let rawWidth = Int64(bounds.right) - Int64(bounds.left) + 1
        let rawHeight = Int64(bounds.bottom) - Int64(bounds.top) + 1
        var deviceWidth = Double(rawWidth)
        var deviceHeight = Double(rawHeight)
        if rawWidth <= 0 || rawHeight <= 0 {
            log.note(.zeroExtentMapping)
            deviceWidth = max(deviceWidth, 1)
            deviceHeight = max(deviceHeight, 1)
        }

        let sx = target.width / deviceWidth
        let sy = target.height / deviceHeight
        // Device (left, top) → target (minX, maxY); y negates so device-down
        // becomes CG-up.
        return CGAffineTransform(
            a: sx, b: 0,
            c: 0, d: -sy,
            tx: target.minX - sx * Double(bounds.left),
            ty: target.maxY + sy * Double(bounds.top)
        )
    }

    // MARK: - Drawing dispatch

    /// Draws one geometry record. `base` is the device→target transform;
    /// composed with the DC's logical→device transform it yields the full
    /// logical→target mapping applied at path-construction time.
    private static func draw(
        _ payload: EMFRecordPayload,
        into context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // The FILL/STROKE closers consume the current path; dispatch them
        // separately (they run whether or not a bracket is open — a closer with
        // no current path logs and skips).
        switch payload {
        case .fillPath:
            drawPathCloser(fill: true, stroke: false, into: context, dc: &dc, base: base, log: &log)
            return
        case .strokePath:
            drawPathCloser(fill: false, stroke: true, into: context, dc: &dc, base: base, log: &log)
            return
        case .strokeAndFillPath:
            drawPathCloser(fill: true, stroke: true, into: context, dc: &dc, base: base, log: &log)
            return

        // Text and bitmap records draw directly regardless of path-bracket
        // state — GDI does not record EXTTEXTOUTW or the blits into a path
        // bracket, so an open bracket does not capture them.
        case .extTextOutW(let text):
            // Capture BEFORE drawing: the anchor is the pre-draw current
            // position under TA_UPDATECP.
            if dc.observer != nil { captureTextOp(text, dc: dc) }
            TextDrawer.draw(text, into: context, dc: &dc, base: base, log: &log)
            return
        case .stretchDIBits(let payload):
            BitmapDrawer.drawStretchDIBits(payload, into: context, dc: dc, base: base, log: &log)
            if dc.observer != nil {
                captureImageOp(destOrigin: payload.dest, destSize: payload.destSize, dib: payload.dib, payload: .stretchDIBits(payload), dc: dc)
            }
            return
        case .bitBlt(let payload):
            BitmapDrawer.drawBitBlt(payload, stretch: false, into: context, dc: dc, base: base, log: &log)
            if dc.observer != nil {
                captureImageOp(destOrigin: payload.dest, destSize: payload.destSize, dib: payload.dib, payload: .bitBlt(payload), dc: dc)
            }
            return
        case .stretchBlt(let payload):
            BitmapDrawer.drawBitBlt(payload, stretch: true, into: context, dc: dc, base: base, log: &log)
            if dc.observer != nil {
                captureImageOp(destOrigin: payload.dest, destSize: payload.destSize, dib: payload.dib, payload: .stretchBlt(payload), dc: dc)
            }
            return
        case .setDIBitsToDevice(let payload):
            BitmapDrawer.drawSetDIBitsToDevice(payload, into: context, dc: dc, base: base, log: &log)
            if dc.observer != nil {
                captureImageOp(destOrigin: payload.dest, destSize: payload.srcSize, dib: payload.dib, payload: .setDIBitsToDevice(payload), dc: dc)
            }
            return

        // WMF-sourced direct draws ([MS-WMF] §2.3.3.12/.19). Like text and
        // bitmaps they are never captured into a path bracket.
        case .setPixel(let point, let color):
            drawSetPixel(point: point, color: color, into: context, dc: dc, base: base)
            if dc.observer != nil {
                let rect = CGRect(x: CGFloat(point.x), y: CGFloat(point.y), width: 1, height: 1)
                capturePassthroughOp(deviceRect: rect, payload: .setPixel(point: point, color: color), dc: dc)
            }
            return
        case .patBlt(let bounds, let rasterOperation):
            drawPatBlt(bounds: bounds, rasterOperation: rasterOperation, into: context, dc: dc, base: base, log: &log)
            if dc.observer != nil {
                capturePassthroughOp(deviceRect: PathBuilder.cgRect(bounds), payload: .patBlt(bounds: bounds, rasterOperation: rasterOperation), dc: dc)
            }
            return

        default:
            break
        }

        // Inside a path bracket, geometry records APPEND to the path (in device
        // space, with the transform in effect now) instead of drawing.
        if dc.isRecordingPath {
            recordIntoPath(payload, dc: &dc)
            return
        }

        let full = dc.resolvedTransform.concatenating(base)
        let path = CGMutablePath()
        // The …To consumers mutate the current position; capture its pre-draw
        // value so an import can rebuild their device geometry (E1).
        let startPosition = dc.state.currentPosition

        switch payload {
        // MARK: Filled shapes — fill with brush, then stroke with pen.
        case .polygon(let poly):
            PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: path, transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .polygon16(let poly):
            PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: path, transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .polyPolygon16(let poly):
            // All sub-polygons form ONE path so the polyfill rule composes
            // across them, exactly like GDI's PolyPolygon.
            forEachSlice(of: poly) { slice in
                PathBuilder.appendPolygon(slice.map(PathBuilder.cgPoint), to: path, transform: full)
            }
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .rectangle(let box):
            path.addRect(PathBuilder.cgRect(box), transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .ellipse(let box):
            path.addEllipse(in: PathBuilder.cgRect(box), transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .roundRect(let payload):
            PathBuilder.appendRoundRect(
                box: payload.box,
                corner: payload.corner,
                to: path,
                transform: full
            )
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        // MARK: Open strokes — pen only, no fill.
        case .polyline(let poly):
            PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: path, transform: full)
            stroke(path, context: context, dc: dc, base: base, full: full)

        case .polyline16(let poly):
            PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: path, transform: full)
            stroke(path, context: context, dc: dc, base: base, full: full)

        case .polyPolyline16(let poly):
            forEachSlice(of: poly) { slice in
                PathBuilder.appendPolyline(slice.map(PathBuilder.cgPoint), to: path, transform: full)
            }
            stroke(path, context: context, dc: dc, base: base, full: full)

        case .polyBezier(let poly):
            appendValidatedBezier(poly.points.map(PathBuilder.cgPoint), to: path, transform: full, log: &log)
            stroke(path, context: context, dc: dc, base: base, full: full)

        case .polyBezier16(let poly):
            appendValidatedBezier(poly.points.map(PathBuilder.cgPoint), to: path, transform: full, log: &log)
            stroke(path, context: context, dc: dc, base: base, full: full)

        case .arc(let arc):
            // Stroke only; does NOT move the current position (that is
            // EMR_ARCTO, outside the phase-2 set).
            PathBuilder.appendArc(box: arc.box, start: arc.start, end: arc.end, to: path, transform: full)
            stroke(path, context: context, dc: dc, base: base, full: full)

        // MARK: Filled arc figures ([MS-WMF] §2.3.3.13/.2) — brush then pen.
        case .pie(let arc):
            PathBuilder.appendPie(box: arc.box, start: arc.start, end: arc.end, to: path, transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        case .chord(let arc):
            PathBuilder.appendChord(box: arc.box, start: arc.start, end: arc.end, to: path, transform: full)
            fillAndStroke(path, context: context, dc: dc, base: base, full: full)

        // MARK: Current-position consumers.
        case .lineTo(let point):
            path.move(to: PathBuilder.cgPoint(dc.state.currentPosition), transform: full)
            path.addLine(to: PathBuilder.cgPoint(point), transform: full)
            stroke(path, context: context, dc: dc, base: base, full: full)
            dc.state.currentPosition = point

        case .polylineTo(let poly):
            drawPolylineTo(poly.points.map(PathBuilder.cgPoint), last: poly.points.last.map { PointL(x: $0.x, y: $0.y) },
                           context: context, dc: &dc, base: base, full: full)

        case .polylineTo16(let poly):
            drawPolylineTo(poly.points.map(PathBuilder.cgPoint), last: poly.points.last.map { PointL(x: Int32($0.x), y: Int32($0.y)) },
                           context: context, dc: &dc, base: base, full: full)

        case .polyBezierTo(let poly):
            drawPolyBezierTo(poly.points.map(PathBuilder.cgPoint),
                             logicalPoints: poly.points.map { PointL(x: $0.x, y: $0.y) },
                             context: context, dc: &dc, base: base, full: full, log: &log)

        case .polyBezierTo16(let poly):
            drawPolyBezierTo(poly.points.map(PathBuilder.cgPoint),
                             logicalPoints: poly.points.map { PointL(x: Int32($0.x), y: Int32($0.y)) },
                             context: context, dc: &dc, base: base, full: full, log: &log)

        default:
            // Unreachable: DeviceContext.apply consumed every non-drawing
            // payload. Kept exhaustive-safe rather than trapping (§8).
            break
        }

        // Scene-import capture (E1): rebuild the device-space geometry from the
        // payload and record the resolved op. No-op when no observer is attached,
        // so normal rendering is byte-identical.
        if dc.observer != nil {
            captureGeometryOp(payload, startPosition: startPosition, dc: dc)
        }
    }

    // MARK: - Path bracket recording

    /// Appends one geometry record to the open path bracket, in DEVICE space,
    /// using the transform in effect now (transform changes mid-bracket affect
    /// only subsequent records — the GDI advanced-mode behaviour). The
    /// figure-continuation records (lineTo / polylineTo / polyBezierTo) seed
    /// from and advance the current position; the self-contained figures
    /// (polygons, rectangle, ellipse, roundRect, arc, open polylines/beziers)
    /// add their own subpath and do neither.
    private static func recordIntoPath(_ payload: EMFRecordPayload, dc: inout DeviceContext) {
        // This record contributes geometry to the open bracket (E1 provenance).
        dc.observer?.noteBracketRecord()
        switch payload {
        // Continue the current figure from the current position.
        case .lineTo(let point):
            dc.appendToPath(seedFromCurrentPosition: true) { path, t in
                path.addLine(to: PathBuilder.cgPoint(point), transform: t)
                return point
            }

        case .polylineTo(let poly):
            appendPolyLineToPath(poly.points.map(PathBuilder.cgPoint),
                                 last: poly.points.last.map { PointL(x: $0.x, y: $0.y) }, dc: &dc)

        case .polylineTo16(let poly):
            appendPolyLineToPath(poly.points.map(PathBuilder.cgPoint),
                                 last: poly.points.last.map { PointL(x: Int32($0.x), y: Int32($0.y)) }, dc: &dc)

        case .polyBezierTo(let poly):
            appendPolyBezierToPath(poly.points.map(PathBuilder.cgPoint),
                                   logicalPoints: poly.points.map { PointL(x: $0.x, y: $0.y) }, dc: &dc)

        case .polyBezierTo16(let poly):
            appendPolyBezierToPath(poly.points.map(PathBuilder.cgPoint),
                                   logicalPoints: poly.points.map { PointL(x: Int32($0.x), y: Int32($0.y)) }, dc: &dc)

        // Self-contained figures.
        case .polygon(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: path, transform: t) }
        case .polygon16(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: path, transform: t) }
        case .polyPolygon16(let poly):
            dc.appendFigureToPath { path, t in forEachSlice(of: poly) { slice in PathBuilder.appendPolygon(slice.map(PathBuilder.cgPoint), to: path, transform: t) } }
        case .polyline(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: path, transform: t) }
        case .polyline16(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: path, transform: t) }
        case .polyPolyline16(let poly):
            dc.appendFigureToPath { path, t in forEachSlice(of: poly) { slice in PathBuilder.appendPolyline(slice.map(PathBuilder.cgPoint), to: path, transform: t) } }
        case .polyBezier(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendBezier(prefixOfBezier(poly.points.map(PathBuilder.cgPoint), continues: false), to: path, transform: t) }
        case .polyBezier16(let poly):
            dc.appendFigureToPath { path, t in PathBuilder.appendBezier(prefixOfBezier(poly.points.map(PathBuilder.cgPoint), continues: false), to: path, transform: t) }
        case .rectangle(let box):
            dc.appendFigureToPath { path, t in path.addRect(PathBuilder.cgRect(box), transform: t) }
        case .ellipse(let box):
            dc.appendFigureToPath { path, t in path.addEllipse(in: PathBuilder.cgRect(box), transform: t) }
        case .roundRect(let payload):
            dc.appendFigureToPath { path, t in PathBuilder.appendRoundRect(box: payload.box, corner: payload.corner, to: path, transform: t) }
        case .arc(let arc):
            dc.appendFigureToPath { path, t in PathBuilder.appendArc(box: arc.box, start: arc.start, end: arc.end, to: path, transform: t) }

        default:
            // Not a geometry record — nothing to record.
            break
        }
    }

    /// The well-formed prefix of a poly-bezier's points (start + triples, or
    /// triples for the …To variants), used when recording into a path — the
    /// malformed-suffix log is emitted only on the drawing path, not here.
    private static func prefixOfBezier(_ points: [CGPoint], continues: Bool) -> [CGPoint] {
        let shape = PathBuilder.bezierShape(pointCount: points.count, continuesFromCurrentPosition: continues)
        return Array(points.prefix(shape.usableCount))
    }

    /// EMR_POLYLINETO into a bracket: continue the current figure through all
    /// points, advancing the current position to the last.
    private static func appendPolyLineToPath(_ points: [CGPoint], last: PointL?, dc: inout DeviceContext) {
        guard !points.isEmpty, let last else { return }
        dc.appendToPath(seedFromCurrentPosition: true) { path, t in
            for point in points { path.addLine(to: point, transform: t) }
            return last
        }
    }

    /// EMR_POLYBEZIERTO into a bracket: continue the current figure through the
    /// well-formed triple prefix, advancing the current position to its end.
    private static func appendPolyBezierToPath(_ points: [CGPoint], logicalPoints: [PointL], dc: inout DeviceContext) {
        let prefix = prefixOfBezier(points, continues: true)
        guard !prefix.isEmpty else { return }
        dc.appendToPath(seedFromCurrentPosition: true) { path, t in
            PathBuilder.appendBezierTriples(prefix, to: path, transform: t)
            return logicalPoints[prefix.count - 1]
        }
    }

    // MARK: - Path closers

    /// EMR_FILLPATH / EMR_STROKEPATH / EMR_STROKEANDFILLPATH: consume the DC's
    /// current path (device space) and paint it under the current clip. Fill
    /// uses the current brush + polyfill mode; stroke uses the current pen;
    /// STROKEANDFILLPATH fills THEN strokes. The record's own Bounds field is
    /// advisory and NOT used to clip. A closer with no current path logs and
    /// skips.
    private static func drawPathCloser(
        fill: Bool,
        stroke: Bool,
        into context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // FILLPATH/STROKEANDFILLPATH implicitly close open figures; an ENDPATH
        // has already moved the path to `currentPath`, but if a bracket is
        // still open (no ENDPATH), fold it in so a BEGINPATH…FILLPATH without an
        // explicit ENDPATH still paints (GDI closes the bracket implicitly).
        if dc.isRecordingPath {
            dc.foldOpenBracketIntoCurrentPath()
        }
        guard let devicePath = dc.consumeCurrentPath(), !devicePath.isEmpty else {
            log.note(.noCurrentPath(record: fill && stroke ? 63 : (fill ? 62 : 64)))
            return
        }
        // Scene-import capture (E1): the path bracket is already DEVICE space.
        // Provenance spans BEGINPATH … this closer.
        if let observer = dc.observer {
            observer.append(makeOp(
                kind: .path,
                recordIndices: observer.consumePathForDraw(),
                deviceGeometry: devicePath,
                fill: fill, stroke: stroke, text: nil, image: nil,
                payload: nil, dc: dc
            ))
        }
        // Transform the device-space path to target space (the same space the
        // geometry drawing path uses) once, then paint under the clip.
        let targetPath = CGMutablePath()
        targetPath.addPath(devicePath, transform: base)

        if fill, case .solid(let color) = dc.state.brush {
            context.saveGState()
            dc.state.clip.apply(to: context, deviceToTarget: base)
            context.setFillColor(cgColor(color))
            context.addPath(targetPath)
            context.fillPath(using: dc.state.polyFillMode == .winding ? .winding : .evenOdd)
            context.restoreGState()
        }
        if stroke, case .stroke(let pen) = dc.state.pen {
            let full = dc.resolvedTransform.concatenating(base)
            context.saveGState()
            dc.state.clip.apply(to: context, deviceToTarget: base)
            applyStrokeParameters(pen, on: context, full: full, base: base, miterLimit: dc.state.miterLimit)
            context.addPath(targetPath)
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: - Record helpers

    /// Iterates a polyPoly payload's per-polygon point slices. The decoder
    /// guarantees `pointCounts` sums exactly to `points.count`, but the
    /// slicing stays clamped anyway — defence in depth over a public
    /// initialiser.
    private static func forEachSlice(of poly: PolyPoly16Payload, _ body: (ArraySlice<PointS>) -> Void) {
        var start = 0
        for count in poly.pointCounts {
            let length = min(Int(count), poly.points.count - start)
            guard length > 0 else { continue }
            body(poly.points[start ..< start + length])
            start += length
        }
    }

    /// Appends a plain poly-bezier (start point + triples), logging and
    /// rendering only the well-formed prefix when the count is not ≡ 1
    /// (mod 3).
    private static func appendValidatedBezier(
        _ points: [CGPoint],
        to path: CGMutablePath,
        transform: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        let shape = PathBuilder.bezierShape(
            pointCount: points.count,
            continuesFromCurrentPosition: false
        )
        if shape.isMalformed {
            log.note(.malformedBezier(pointCount: points.count))
        }
        PathBuilder.appendBezier(Array(points.prefix(shape.usableCount)), to: path, transform: transform)
    }

    /// EMR_POLYLINETO: starts at the current position, strokes through all
    /// points, and leaves the current position at the last point.
    private static func drawPolylineTo(
        _ points: [CGPoint],
        last: PointL?,
        context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        full: CGAffineTransform
    ) {
        guard !points.isEmpty, let last else { return }
        let path = CGMutablePath()
        path.move(to: PathBuilder.cgPoint(dc.state.currentPosition), transform: full)
        for point in points {
            path.addLine(to: point, transform: full)
        }
        stroke(path, context: context, dc: dc, base: base, full: full)
        dc.state.currentPosition = last
    }

    /// EMR_POLYBEZIERTO: triples continuing from the current position. A
    /// count not ≡ 0 (mod 3) logs and renders the well-formed prefix; the
    /// current position advances to the end of what was actually drawn.
    private static func drawPolyBezierTo(
        _ points: [CGPoint],
        logicalPoints: [PointL],
        context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        full: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        let shape = PathBuilder.bezierShape(
            pointCount: points.count,
            continuesFromCurrentPosition: true
        )
        if shape.isMalformed {
            log.note(.malformedBezier(pointCount: points.count))
        }
        guard shape.usableCount > 0 else { return }

        let path = CGMutablePath()
        path.move(to: PathBuilder.cgPoint(dc.state.currentPosition), transform: full)
        PathBuilder.appendBezierTriples(points.prefix(shape.usableCount), to: path, transform: full)
        stroke(path, context: context, dc: dc, base: base, full: full)
        dc.state.currentPosition = logicalPoints[shape.usableCount - 1]
    }

    // MARK: - WMF-sourced direct draws

    /// META_SETPIXEL ([MS-WMF] §2.3.3.19): paint a single device pixel at
    /// `point` (logical units) in `color`, under the current clip.
    private static func drawSetPixel(
        point: PointL,
        color: ColorRef,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform
    ) {
        let full = dc.resolvedTransform.concatenating(base)
        let p = PathBuilder.cgPoint(point).applying(full)
        context.saveGState()
        dc.state.clip.apply(to: context, deviceToTarget: base)
        context.setFillColor(cgColor(color))
        context.fill(CGRect(x: p.x, y: p.y, width: 1, height: 1))
        context.restoreGState()
    }

    /// META_PATBLT ([MS-WMF] §2.3.3.12): fill `bounds` with the current brush
    /// under a ternary raster op — no outline. PATCOPY copies the brush;
    /// BLACKNESS/WHITENESS force black/white; any other rop falls back to a
    /// brush copy with a log entry (best partial output, §8). A NULL brush under
    /// a brush-copy rop paints nothing.
    private static func drawPatBlt(
        bounds: RectL,
        rasterOperation: UInt32,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        let fillColor: ColorRef?
        switch rasterOperation {
        case 0x00F0_0021:                       // PATCOPY
            fillColor = patBltBrushColor(dc)
        case 0x0000_0042:                       // BLACKNESS
            fillColor = ColorRef(red: 0, green: 0, blue: 0)
        case 0x00FF_0062:                       // WHITENESS
            fillColor = ColorRef(red: 255, green: 255, blue: 255)
        default:
            log.noteUnsupportedRasterOp(rasterOperation: rasterOperation)
            fillColor = patBltBrushColor(dc)
        }
        guard let fillColor else { return }
        let full = dc.resolvedTransform.concatenating(base)
        let path = CGMutablePath()
        path.addRect(PathBuilder.cgRect(bounds), transform: full)
        guard !path.isEmpty else { return }
        context.saveGState()
        dc.state.clip.apply(to: context, deviceToTarget: base)
        context.setFillColor(cgColor(fillColor))
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// The current brush's solid colour for a PATBLT copy, or `nil` for a NULL
    /// brush (nothing to paint).
    private static func patBltBrushColor(_ dc: DeviceContext) -> ColorRef? {
        if case .solid(let color) = dc.state.brush { return color }
        return nil
    }

    // MARK: - Paint

    private static func cgColor(_ color: ColorRef) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    /// Filled-shape semantics: fill with the current brush under the current
    /// polyfill rule (ALTERNATE → even-odd, WINDING → winding), THEN stroke
    /// the outline with the current pen. A NULL brush or pen skips its half.
    /// The fill and the stroke each paint inside their own gstate save/restore
    /// with the DC's clip applied, so CoreGraphics' monotonic gstate clip never
    /// leaks between records or past a RestoreDC.
    private static func fillAndStroke(
        _ path: CGPath,
        context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        full: CGAffineTransform
    ) {
        if case .solid(let color) = dc.state.brush, !path.isEmpty {
            context.saveGState()
            dc.state.clip.apply(to: context, deviceToTarget: base)
            context.setFillColor(cgColor(color))
            context.addPath(path)
            context.fillPath(using: dc.state.polyFillMode == .winding ? .winding : .evenOdd)
            context.restoreGState()
        }
        stroke(path, context: context, dc: dc, base: base, full: full)
    }

    /// Strokes `path` with the current pen inside a gstate save/restore that
    /// applies the DC's clip.
    private static func stroke(
        _ path: CGPath,
        context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        full: CGAffineTransform
    ) {
        guard case .stroke(let pen) = dc.state.pen, !path.isEmpty else { return }
        context.saveGState()
        dc.state.clip.apply(to: context, deviceToTarget: base)
        applyStrokeParameters(pen, on: context, full: full, base: base, miterLimit: dc.state.miterLimit)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Sets the stroke colour, width, cap, join, miter limit, and dash on
    /// `context` from a resolved pen. Shared by `stroke` and the STROKEPATH
    /// closer; the caller manages the gstate save/restore and clip and adds the
    /// path.
    private static func applyStrokeParameters(
        _ pen: ResolvedStroke,
        on context: CGContext,
        full: CGAffineTransform,
        base: CGAffineTransform,
        miterLimit: UInt32
    ) {
        let parameters = StrokeMapper.deviceStroke(
            for: pen,
            logicalToTarget: full,
            deviceToTarget: base
        )
        context.setStrokeColor(cgColor(pen.color))
        context.setLineWidth(parameters.width)
        context.setLineCap(parameters.cap)
        context.setLineJoin(parameters.join)
        // GDI's floor for the miter limit is 1.
        context.setMiterLimit(max(1, CGFloat(miterLimit)))
        context.setLineDash(phase: 0, lengths: parameters.dash)
    }

    // MARK: - Scene-import capture (E1)
    //
    // These run only when `dc.observer != nil` (an import). They rebuild the
    // resolved op in DEVICE space from the same payload the drawing used, so a
    // lifted element carries exactly what was drawn.

    /// Builds a `ResolvedDrawOp` from the current DC state. Fill/stroke flags say
    /// which halves a primitive paints; the brush/pen are read from the DC.
    static func makeOp(
        kind: ResolvedDrawOp.Kind,
        recordIndices: [Int],
        deviceGeometry: CGPath,
        fill: Bool,
        stroke: Bool,
        text: LiftedText?,
        image: LiftedImage?,
        payload: EMFRecordPayload?,
        dc: DeviceContext
    ) -> ResolvedDrawOp {
        let fillColor: ColorRef?
        if fill, case .solid(let color) = dc.state.brush { fillColor = color } else { fillColor = nil }
        let liftedStroke: LiftedStroke?
        if stroke, case .stroke(let pen) = dc.state.pen {
            liftedStroke = liftStroke(pen, miterLimit: dc.state.miterLimit)
        } else {
            liftedStroke = nil
        }
        return ResolvedDrawOp(
            recordIndices: recordIndices,
            kind: kind,
            deviceGeometry: deviceGeometry,
            deviceTransform: dc.resolvedTransform,
            clipDeviceGeometry: dc.state.clip.devicePath(),
            fillColor: fillColor,
            fillIsEvenOdd: dc.state.polyFillMode != .winding,
            stroke: liftedStroke,
            text: text,
            image: image,
            replayState: dc.state,
            replayHeader: dc.header,
            replayPayload: payload
        )
    }

    static func liftStroke(_ pen: ResolvedStroke, miterLimit: UInt32) -> LiftedStroke {
        let dash: LiftedStroke.Dash
        switch pen.lineStyle {
        case .solid: dash = .solid
        case .dash: dash = .dash
        case .dot: dash = .dot
        case .dashDot: dash = .dashDot
        case .dashDotDot: dash = .dashDotDot
        case .userStyle(let entries): dash = .userStyle(entries)
        }
        return LiftedStroke(
            color: pen.color,
            isCosmetic: pen.isCosmetic,
            width: pen.width,
            dash: dash,
            cap: pen.cap,
            join: pen.join,
            miterLimit: miterLimit
        )
    }

    /// Rebuilds the device-space geometry for a geometry payload and records the
    /// op. `startPosition` is the pre-draw current position (the …To consumers
    /// seed from it). Matches the shapes `draw` paints; non-geometry payloads are
    /// ignored (text/images/direct draws capture elsewhere).
    private static func captureGeometryOp(
        _ payload: EMFRecordPayload,
        startPosition: PointL,
        dc: DeviceContext
    ) {
        guard let observer = dc.observer else { return }
        let t = dc.resolvedTransform
        let device = CGMutablePath()
        let kind: ResolvedDrawOp.Kind
        var fill = false
        var stroke = false

        switch payload {
        case .polygon(let poly):
            PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: device, transform: t)
            kind = .polygon; fill = true; stroke = true
        case .polygon16(let poly):
            PathBuilder.appendPolygon(poly.points.map(PathBuilder.cgPoint), to: device, transform: t)
            kind = .polygon; fill = true; stroke = true
        case .polyPolygon16(let poly):
            forEachSlice(of: poly) { slice in
                PathBuilder.appendPolygon(slice.map(PathBuilder.cgPoint), to: device, transform: t)
            }
            kind = .polyPolygon; fill = true; stroke = true
        case .rectangle(let box):
            device.addRect(PathBuilder.cgRect(box), transform: t)
            kind = .rectangle; fill = true; stroke = true
        case .ellipse(let box):
            device.addEllipse(in: PathBuilder.cgRect(box), transform: t)
            kind = .ellipse; fill = true; stroke = true
        case .roundRect(let rr):
            PathBuilder.appendRoundRect(box: rr.box, corner: rr.corner, to: device, transform: t)
            kind = .roundRect; fill = true; stroke = true
        case .pie(let arc):
            PathBuilder.appendPie(box: arc.box, start: arc.start, end: arc.end, to: device, transform: t)
            kind = .pie; fill = true; stroke = true
        case .chord(let arc):
            PathBuilder.appendChord(box: arc.box, start: arc.start, end: arc.end, to: device, transform: t)
            kind = .chord; fill = true; stroke = true
        case .polyline(let poly):
            PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: device, transform: t)
            kind = .polyline; stroke = true
        case .polyline16(let poly):
            PathBuilder.appendPolyline(poly.points.map(PathBuilder.cgPoint), to: device, transform: t)
            kind = .polyline; stroke = true
        case .polyPolyline16(let poly):
            forEachSlice(of: poly) { slice in
                PathBuilder.appendPolyline(slice.map(PathBuilder.cgPoint), to: device, transform: t)
            }
            kind = .polyPolyline; stroke = true
        case .polyBezier(let poly):
            PathBuilder.appendBezier(prefixOfBezier(poly.points.map(PathBuilder.cgPoint), continues: false), to: device, transform: t)
            kind = .bezier; stroke = true
        case .polyBezier16(let poly):
            PathBuilder.appendBezier(prefixOfBezier(poly.points.map(PathBuilder.cgPoint), continues: false), to: device, transform: t)
            kind = .bezier; stroke = true
        case .arc(let arc):
            PathBuilder.appendArc(box: arc.box, start: arc.start, end: arc.end, to: device, transform: t)
            kind = .arc; stroke = true
        case .lineTo(let point):
            device.move(to: PathBuilder.cgPoint(startPosition), transform: t)
            device.addLine(to: PathBuilder.cgPoint(point), transform: t)
            kind = .line; stroke = true
        case .polylineTo(let poly):
            captureLineToDevice(device, startPosition: startPosition, points: poly.points.map(PathBuilder.cgPoint), transform: t)
            kind = .polyline; stroke = true
        case .polylineTo16(let poly):
            captureLineToDevice(device, startPosition: startPosition, points: poly.points.map(PathBuilder.cgPoint), transform: t)
            kind = .polyline; stroke = true
        case .polyBezierTo(let poly):
            captureBezierToDevice(device, startPosition: startPosition, points: poly.points.map(PathBuilder.cgPoint), transform: t)
            kind = .bezier; stroke = true
        case .polyBezierTo16(let poly):
            captureBezierToDevice(device, startPosition: startPosition, points: poly.points.map(PathBuilder.cgPoint), transform: t)
            kind = .bezier; stroke = true
        default:
            return
        }

        observer.append(makeOp(
            kind: kind,
            recordIndices: [observer.currentRecordIndex],
            deviceGeometry: device,
            fill: fill, stroke: stroke, text: nil, image: nil,
            payload: payload, dc: dc
        ))
    }

    private static func captureLineToDevice(
        _ device: CGMutablePath, startPosition: PointL, points: [CGPoint], transform t: CGAffineTransform
    ) {
        guard !points.isEmpty else { return }
        device.move(to: PathBuilder.cgPoint(startPosition), transform: t)
        for point in points { device.addLine(to: point, transform: t) }
    }

    private static func captureBezierToDevice(
        _ device: CGMutablePath, startPosition: PointL, points: [CGPoint], transform t: CGAffineTransform
    ) {
        let prefix = prefixOfBezier(points, continues: true)
        guard !prefix.isEmpty else { return }
        device.move(to: PathBuilder.cgPoint(startPosition), transform: t)
        PathBuilder.appendBezierTriples(prefix, to: device, transform: t)
    }

    /// Lifts an EXTTEXTOUTW run to a `LiftedText`. The font family is the
    /// RESOLVED macOS family (post-substitution), matching what was drawn.
    static func liftText(_ text: ExtTextPayload, dc: DeviceContext) -> LiftedText {
        let resolved = dc.state.font
        let baseFont = resolved?.base ?? FontMapper.systemBaseFont()
        let family = CTFontCopyFamilyName(baseFont) as String
        let traits = CTFontGetSymbolicTraits(baseFont)
        let reference = dc.state.textAlign.updatesCurrentPosition ? dc.state.currentPosition : text.reference
        return LiftedText(
            string: text.string,
            fontFamily: family,
            requestedFamily: resolved?.requestedFamily ?? "",
            logicalHeight: resolved?.logicalHeight ?? 0,
            bold: traits.contains(.traitBold),
            italic: traits.contains(.traitItalic),
            underline: resolved?.underline ?? false,
            strikeOut: resolved?.strikeOut ?? false,
            escapementTenths: resolved?.escapementTenths ?? 0,
            color: dc.state.textColor,
            referenceLogical: reference,
            alignRawValue: dc.state.textAlign.rawValue
        )
    }

    /// Captures a text op after EXTTEXTOUTW drew. Skips glyph-index runs and
    /// empty strings (which draw no lift-able text) — they remain passthrough.
    private static func captureTextOp(_ text: ExtTextPayload, dc: DeviceContext) {
        guard let observer = dc.observer else { return }
        // A glyph-index or empty run isn't lift-able to editable text; keep it as
        // a passthrough op so it still replays (an ETO_OPAQUE background rect).
        guard !text.options.glyphIndex, !text.string.isEmpty else {
            capturePassthroughOp(deviceRect: PathBuilder.cgRect(text.rectangle), payload: .extTextOutW(text), dc: dc)
            return
        }
        let t = dc.resolvedTransform
        let device = CGMutablePath()
        let rect = PathBuilder.cgRect(text.rectangle)
        if rect.width > 0, rect.height > 0 {
            device.addRect(rect, transform: t)
        }
        observer.append(makeOp(
            kind: .text,
            recordIndices: [observer.currentRecordIndex],
            deviceGeometry: device,
            fill: false, stroke: false,
            text: liftText(text, dc: dc), image: nil,
            payload: .extTextOutW(text), dc: dc
        ))
    }

    /// Captures an image op after a blit drew. `dib` is nil for a sourceless rop
    /// fill, which lifts as a passthrough op (it painted, but has no image to
    /// edit). Dest is in LOGICAL units.
    private static func captureImageOp(
        destOrigin: PointL, destSize: SizeL, dib: DIB?, payload: EMFRecordPayload, dc: DeviceContext
    ) {
        guard let observer = dc.observer else { return }
        let rect = CGRect(
            x: CGFloat(destOrigin.x), y: CGFloat(destOrigin.y),
            width: CGFloat(destSize.cx), height: CGFloat(destSize.cy)
        )
        // A sourceless blit (dib == nil — a PATCOPY-style BITBLT/STRETCHBLT) draws
        // no bitmap to lift as an image, but it DID paint the dest rect with the
        // current brush. Capture it as a passthrough op carrying its payload so the
        // scene replays the fill; returning here (the old behaviour) silently
        // dropped it, leaving brush-filled regions blank on re-render. Mirrors
        // `capturePassthroughOp` for PATBLT.
        guard let dib else {
            capturePassthroughOp(deviceRect: rect, payload: payload, dc: dc)
            return
        }
        let device = CGMutablePath()
        device.addRect(rect.standardized, transform: dc.resolvedTransform)
        observer.append(makeOp(
            kind: .image,
            recordIndices: [observer.currentRecordIndex],
            deviceGeometry: device,
            fill: false, stroke: false,
            text: nil,
            image: LiftedImage(destOrigin: destOrigin, destSize: destSize, sourceDIB: dib),
            payload: payload, dc: dc
        ))
    }

    /// Captures a passthrough op for a drawn record v1 does not lift to an
    /// editable element (SETPIXEL, PATBLT, glyph-index text). It carries its
    /// payload so replay reproduces it exactly.
    private static func capturePassthroughOp(deviceRect: CGRect, payload: EMFRecordPayload, dc: DeviceContext) {
        guard let observer = dc.observer else { return }
        let device = CGMutablePath()
        if deviceRect.width != 0 || deviceRect.height != 0 {
            device.addRect(deviceRect.standardized, transform: dc.resolvedTransform)
        }
        observer.append(makeOp(
            kind: .passthrough,
            recordIndices: [observer.currentRecordIndex],
            deviceGeometry: device,
            fill: false, stroke: false, text: nil, image: nil,
            payload: payload, dc: dc
        ))
    }

    // MARK: - Op replay (E1 scene render / passthrough)

    /// Re-runs a captured op's ORIGINAL draw into `context`, so a lifted or
    /// passthrough element renders pixel-identical to the source. `base` is the
    /// device→target transform. A no-op observer is never attached here.
    public static func replay(
        _ op: ResolvedDrawOp,
        into context: CGContext,
        deviceToTarget base: CGAffineTransform,
        options: RenderOptions = .default
    ) {
        var log = EMFRenderLog()
        var dc = DeviceContext(header: op.replayHeader, fontSubstitutions: options.fontSubstitutions)
        dc.state = op.replayState

        if let payload = op.replayPayload {
            playGDIRecord(payload, into: context, dc: &dc, base: base, log: &log)
            return
        }
        // Path op: fill/stroke the captured device geometry under the clip,
        // exactly as `drawPathCloser` does.
        let targetPath = CGMutablePath()
        targetPath.addPath(op.deviceGeometry, transform: base)
        if op.fillColor != nil, case .solid(let color) = dc.state.brush {
            context.saveGState()
            dc.state.clip.apply(to: context, deviceToTarget: base)
            context.setFillColor(cgColor(color))
            context.addPath(targetPath)
            context.fillPath(using: dc.state.polyFillMode == .winding ? .winding : .evenOdd)
            context.restoreGState()
        }
        if op.stroke != nil, case .stroke(let pen) = dc.state.pen {
            let full = dc.resolvedTransform.concatenating(base)
            context.saveGState()
            dc.state.clip.apply(to: context, deviceToTarget: base)
            applyStrokeParameters(pen, on: context, full: full, base: base, miterLimit: dc.state.miterLimit)
            context.addPath(targetPath)
            context.strokePath()
            context.restoreGState()
        }
    }
}

