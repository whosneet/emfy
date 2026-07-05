import CoreGraphics
import EMFParse
import Foundation

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
        target: CGRect
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let base = deviceToTarget(header: file.header, target: target, log: &log)
        var dc = DeviceContext(header: file.header)

        context.saveGState()
        defer { context.restoreGState() }

        // records[0] is EMR_HEADER — already consumed as file.header, never
        // a playback record.
        for record in file.records.dropFirst() {
            let payload = file.payload(of: record)
            if dc.apply(payload, log: &log) { continue }
            draw(payload, into: context, dc: &dc, base: base, log: &log)
        }
        return log
    }

    /// Renders `file` into a fresh sRGB 8-bit bitmap sized from the header
    /// bounds (width = right−left+1, height = bottom−top+1, times `scale`),
    /// on a white background.
    ///
    /// The canvas is capped at 16384×16384 — hostile headers declaring absurd
    /// bounds are clamped with a log entry. Returns `nil` only if the bitmap
    /// context itself cannot be created (allocation failure); rendering
    /// itself never fails.
    public static func makeImage(
        _ file: EMFFile,
        scale: CGFloat = 1
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
        let width = clampDimension(requestedWidth)
        let height = clampDimension(requestedHeight)
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

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let renderLog = render(
            file,
            into: context,
            target: CGRect(x: 0, y: 0, width: width, height: height)
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
            default:
                log.note(entry)
            }
        }

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
    /// always sound.
    private static func deviceToTarget(
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
            TextDrawer.draw(text, into: context, dc: &dc, base: base, log: &log)
            return
        case .stretchDIBits(let payload):
            BitmapDrawer.drawStretchDIBits(payload, into: context, dc: dc, base: base, log: &log)
            return
        case .bitBlt(let payload):
            BitmapDrawer.drawBitBlt(payload, stretch: false, into: context, dc: dc, base: base, log: &log)
            return
        case .stretchBlt(let payload):
            BitmapDrawer.drawBitBlt(payload, stretch: true, into: context, dc: dc, base: base, log: &log)
            return
        case .setDIBitsToDevice(let payload):
            BitmapDrawer.drawSetDIBitsToDevice(payload, into: context, dc: dc, base: base, log: &log)
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
}

