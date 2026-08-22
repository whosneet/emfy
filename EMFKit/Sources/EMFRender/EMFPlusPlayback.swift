import CoreGraphics
import CoreText
import EMFParse
import Foundation

/// The EMF+ playback engine ([MS-EMFPLUS] §1.3.1). Walks `EMFFile.records` in
/// file order: EMF+ records (carried in EMR_COMMENT_EMFPLUS) drive output, and
/// GDI records play through the existing GDI machinery only inside a GetDC
/// window. Playback NEVER fails — an unsupported record or an unresolvable
/// object is a logged skip plus best partial output (primer §8).
///
/// Coordinates flow world → page → device → target. The world transform
/// (logical → page) and page transform (page → device) are EMF+ state; the
/// device → target `base` is the renderer's existing canvas mapping (with its
/// single y-flip). The composed `full` is applied at path-construction time,
/// exactly as the GDI `PathBuilder` does, so no CTM is set and the GDI
/// GetDC-window path is undisturbed.
struct EMFPlusPlayback {

    // MARK: - Record type constants ([MS-EMFPLUS] §2.1.1.1)
    private static let getDC: UInt16 = 0x4004
    private static let object: UInt16 = 0x4008
    // EMR_COMMENT / EMR_HEADER / EMR_EOF ([MS-EMF] §2.1.1).
    private static let emrComment: UInt32 = 70
    private static let emrHeader: UInt32 = 1
    private static let emrEOF: UInt32 = 14

    // MARK: - Graphics state

    /// The saveable EMF+ graphics state — what Save/Restore and Begin/End
    /// container snapshot. The object table is NOT here (it lives for the whole
    /// playback, like GDI's object table).
    struct State {
        /// World transform: logical → page.
        var world = CGAffineTransform.identity
        /// Page transform: page → device (SetPageTransform scale).
        var page = CGAffineTransform.identity
        /// Clip in DEVICE space (world→device applied at set time), replayed
        /// through `base` per draw — the same model as the GDI `ClipRegion`.
        var clip = ClipRegion.none
        var antialias = true
    }

    /// A fill source for a drawing record: a direct ARGB colour (S flag set) or
    /// an object-table brush.
    private enum Fill {
        case color(EMFPlusARGB)
        case brush(EMFPlusBrush)
    }

    let context: CGContext
    let base: CGAffineTransform
    private var state = State()
    /// Index-keyed saved states for EmfPlusSave/Restore ([MS-EMFPLUS] §2.3.7.4/5).
    private var savedStates: [UInt32: State] = [:]
    /// Index-keyed saved states for graphics containers (§2.3.7.1–3), kept
    /// separate so a container index cannot collide with a save index.
    private var savedContainers: [UInt32: State] = [:]
    private var table = ObjectTable()
    /// Per-object decoded-image cache (audit H1 / A1): each bound image object
    /// is decoded AT MOST ONCE, no matter how many DrawImage records reference
    /// it; a rebind of the slot invalidates its entry (see the object dispatch).
    /// Struct-local to this playback instance — never static — because Quick
    /// Look renders files concurrently.
    private var imageCache = DecodedImageCache()

    /// world → page → device → target.
    private var full: CGAffineTransform {
        state.world.concatenating(state.page).concatenating(base)
    }

    /// world → device (the space clip primitives are stored in).
    private var worldToDevice: CGAffineTransform {
        state.world.concatenating(state.page)
    }

    // MARK: - Entry point

    static func run(
        file: EMFFile,
        stream: EMFPlusStream,
        into context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        var player = EMFPlusPlayback(context: context, base: base)
        player.walk(file: file, stream: stream, dc: &dc, log: &log)
    }

    // MARK: - File-order walk with GetDC arbitration

    private mutating func walk(
        file: EMFFile,
        stream: EMFPlusStream,
        dc: inout DeviceContext,
        log: inout EMFRenderLog
    ) {
        // Group the reassembled EMF+ records by the file record (comment) their
        // header starts in. Records are already in stream order.
        var byComment: [Int: [EMFPlusRecord]] = [:]
        for record in stream.records {
            byComment[record.sourceRecordIndex, default: []].append(record)
        }

        // A GetDC opens a window in which subsequent GDI records play, until the
        // next EMF+ record of any type closes it (§1.3.1).
        var gdiWindowOpen = false

        for (index, record) in file.records.enumerated() {
            if let plusRecords = byComment[index] {
                for plusRecord in plusRecords {
                    if plusRecord.type == Self.getDC {
                        gdiWindowOpen = true
                    } else {
                        gdiWindowOpen = false
                        play(plusRecord, log: &log)
                    }
                }
                continue
            }

            // A non-sourcing EMF+/other comment, and the control records, never
            // render.
            if record.type == Self.emrComment { continue }
            if record.type == Self.emrHeader || record.type == Self.emrEOF { continue }

            if gdiWindowOpen {
                EMFRenderer.playGDIRecord(
                    file.payload(of: record),
                    into: context,
                    dc: &dc,
                    base: base,
                    log: &log
                )
            }
        }
    }

    // MARK: - EMF+ record dispatch

    private mutating func play(_ record: EMFPlusRecord, log: inout EMFRenderLog) {
        let flags = record.flags
        switch record.type {
        // Control — no output.
        case 0x4001, 0x4002, 0x4003:   // Header, EndOfFile, Comment
            break
        case Self.object:              // 0x4008 EmfPlusObject
            // A rebind of a slot invalidates any image cached for it (A1).
            if let boundID = table.apply(record) { imageCache.invalidate(Int(boundID)) }

        // Transforms (§2.3.9).
        case 0x402A: setWorldTransform(record)
        case 0x402B: state.world = .identity                      // ResetWorldTransform
        case 0x402C: multiplyWorldTransform(record, flags: flags)
        case 0x402D: translateWorldTransform(record, flags: flags)
        case 0x402E: scaleWorldTransform(record, flags: flags)
        case 0x402F: rotateWorldTransform(record, flags: flags)
        case 0x4030: setPageTransform(record, flags: flags, log: &log)

        // Save / restore / containers (§2.3.7).
        case 0x4025: if let idx = firstU32(record) { savedStates[idx] = state }
        case 0x4026: if let idx = firstU32(record), let saved = savedStates[idx] { state = saved; savedStates[idx] = nil }
        case 0x4027: beginContainer(record, log: &log)
        case 0x4028: if let idx = firstU32(record) { savedContainers[idx] = state }
        case 0x4029: if let idx = firstU32(record), let saved = savedContainers[idx] { state = saved; savedContainers[idx] = nil }

        // Clipping (§2.3.1).
        case 0x4031: state.clip = .none                           // ResetClip
        case 0x4032: setClipRect(record, flags: flags, log: &log)
        case 0x4033: setClipPath(record, flags: flags, log: &log)
        case 0x4034: setClipRegion(record, flags: flags, log: &log)
        case 0x4035: log.noteEMFPlusApproximated(.offsetClip)     // OffsetClip

        // Property records (§2.3.6): antialias honoured; the rest ignored.
        case 0x401E: state.antialias = (flags & 0x0001) != 0
        case 0x4023: if (flags & 0x00FF) != 0 { log.noteEMFPlusApproximated(.compositingMode) }
        case 0x401D, 0x401F, 0x4020, 0x4021, 0x4022, 0x4024:
            break

        // Drawing (§2.3.4).
        case 0x4009 ... 0x401C, 0x4036:
            playDrawing(record, flags: flags, log: &log)

        // Everything else — MultiFormat, SerializableObject, terminal-server,
        // and any unknown type — is a logged skip (P4/out of scope).
        default:
            log.noteEMFPlusUnsupported(type: record.type)
        }
    }

    // MARK: - Drawing dispatch

    private mutating func playDrawing(_ record: EMFPlusRecord, flags: UInt16, log: inout EMFRenderLog) {
        let sBit = (flags & 0x8000) != 0
        let cBit = (flags & 0x4000) != 0
        let relative = (flags & 0x0800) != 0    // P: relative points (unsupported)
        let objectID = Int(flags & 0x00FF)
        var reader = PlusReader(record.data)

        switch record.type {
        case 0x4009:   // Clear
            if let color = reader.u32() { clear(argb(color), log: &log) }

        case 0x400A:   // FillRects
            guard let brushId = reader.u32(), let count = reader.u32(),
                  let fill = fillSource(sBit: sBit, brushId: brushId) else { return }
            let path = CGMutablePath()
            for _ in 0 ..< Int(count) {
                guard let rect = reader.rect(compressed: cBit) else { break }
                path.addRect(rect.standardized, transform: full)
            }
            fillTargetPath(path, fill: fill, rule: .evenOdd, log: &log)

        case 0x400B:   // DrawRects
            guard let count = reader.u32() else { return }
            let path = CGMutablePath()
            for _ in 0 ..< Int(count) {
                guard let rect = reader.rect(compressed: cBit) else { break }
                path.addRect(rect.standardized, transform: full)
            }
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x400C:   // FillPolygon
            guard !relative, let brushId = reader.u32(), let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit),
                  let fill = fillSource(sBit: sBit, brushId: brushId) else {
                if relative { log.noteEMFPlusUnsupported(type: record.type) }
                return
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendPolygon(points, to: path, transform: full)
            fillTargetPath(path, fill: fill, rule: .evenOdd, log: &log)

        case 0x400D:   // DrawLines
            let lBit = (flags & 0x2000) != 0
            guard !relative, let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit) else {
                if relative { log.noteEMFPlusUnsupported(type: record.type) }
                return
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendPolyline(points, to: path, transform: full, close: lBit)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x400E:   // FillEllipse
            guard let brushId = reader.u32(), let rect = reader.rect(compressed: cBit),
                  let fill = fillSource(sBit: sBit, brushId: brushId) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendEllipse(in: rect.standardized, to: path, transform: full)
            fillTargetPath(path, fill: fill, rule: .evenOdd, log: &log)

        case 0x400F:   // DrawEllipse
            guard let rect = reader.rect(compressed: cBit) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendEllipse(in: rect.standardized, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x4010:   // FillPie
            guard let brushId = reader.u32(), let start = reader.f32(), let sweep = reader.f32(),
                  let rect = reader.rect(compressed: cBit),
                  let fill = fillSource(sBit: sBit, brushId: brushId) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendArc(rect: rect.standardized, startDegrees: start, sweepDegrees: sweep, pie: true, to: path, transform: full)
            fillTargetPath(path, fill: fill, rule: .evenOdd, log: &log)

        case 0x4011:   // DrawPie
            guard let start = reader.f32(), let sweep = reader.f32(), let rect = reader.rect(compressed: cBit) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendArc(rect: rect.standardized, startDegrees: start, sweepDegrees: sweep, pie: true, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x4012:   // DrawArc
            guard let start = reader.f32(), let sweep = reader.f32(), let rect = reader.rect(compressed: cBit) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendArc(rect: rect.standardized, startDegrees: start, sweepDegrees: sweep, pie: false, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x4013:   // FillRegion
            guard let brushId = reader.u32(), let fill = fillSource(sBit: sBit, brushId: brushId),
                  let region = table.region(objectID) else { return }
            let path = EMFPlusGeometry.regionPath(region.root, transform: full, log: &log)
            fillTargetPath(path, fill: fill, rule: .winding, log: &log)

        case 0x4014:   // FillPath
            guard let brushId = reader.u32(), let fill = fillSource(sBit: sBit, brushId: brushId),
                  let plusPath = table.path(objectID) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendPath(plusPath, to: path, transform: full)
            fillTargetPath(path, fill: fill, rule: .evenOdd, log: &log)

        case 0x4015:   // DrawPath
            guard let penId = reader.u32(), let plusPath = table.path(objectID) else { return }
            let path = CGMutablePath()
            EMFPlusGeometry.appendPath(plusPath, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(Int(penId & 0xFF)), log: &log)

        case 0x4016:   // FillClosedCurve
            let winding = (flags & 0x2000) != 0
            guard !relative, let brushId = reader.u32(), let tension = reader.f32(), let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit),
                  let fill = fillSource(sBit: sBit, brushId: brushId) else {
                if relative { log.noteEMFPlusUnsupported(type: record.type) }
                return
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendCardinalSpline(points, tension: tension, closed: true, to: path, transform: full)
            fillTargetPath(path, fill: fill, rule: winding ? .winding : .evenOdd, log: &log)

        case 0x4017:   // DrawClosedCurve
            guard !relative, let tension = reader.f32(), let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit) else {
                if relative { log.noteEMFPlusUnsupported(type: record.type) }
                return
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendCardinalSpline(points, tension: tension, closed: true, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x4018:   // DrawCurve
            // Tension, Offset, NumSegments, Count, then points ([MS-EMFPLUS]
            // §2.3.4.4). The whole open cardinal spline is drawn; a non-zero
            // Offset or a NumSegments short of the spline's segment count
            // (points − 1) selects a partial run we do not honour — note it.
            guard let tension = reader.f32(), let offset = reader.u32(),
                  let numSegments = reader.u32(), let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit) else { return }
            let fullSegments = points.count > 1 ? points.count - 1 : 0
            if offset != 0 || Int(numSegments) < fullSegments {
                log.noteEMFPlusApproximated(.curveSegmentRange)
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendCardinalSpline(points, tension: tension, closed: false, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x4019:   // DrawBeziers
            guard !relative, let count = reader.u32(),
                  let points = reader.points(count: Int(count), compressed: cBit) else {
                if relative { log.noteEMFPlusUnsupported(type: record.type) }
                return
            }
            let path = CGMutablePath()
            EMFPlusGeometry.appendBeziers(points, to: path, transform: full)
            strokeTargetPath(path, pen: table.pen(objectID), log: &log)

        case 0x401A:   // DrawImage
            drawImage(record, objectID: objectID, cBit: cBit, log: &log)

        case 0x401B:   // DrawImagePoints
            drawImagePoints(record, objectID: objectID, cBit: cBit, relative: relative, log: &log)

        case 0x401C:   // DrawString
            drawString(record, sBit: sBit, fontID: objectID, log: &log)

        case 0x4036:   // DrawDriverString
            drawDriverString(record, sBit: sBit, fontID: objectID, log: &log)

        default:
            log.noteEMFPlusUnsupported(type: record.type)
        }
    }

    // MARK: - Text (§2.3.4.14 / §2.3.4.6)

    /// EmfPlusDrawString ([MS-EMFPLUS] §2.3.4.14): a UTF-16 string drawn with the
    /// ObjectID font, painted in the S-flag colour or the BrushId brush, laid out
    /// within the LayoutRect by the optional StringFormat's alignment. Only string
    /// ALIGNMENT is honoured; trimming/wrap/tabs/hotkey/ranges and RTL/vertical
    /// direction are simplified to a single left-to-right line with one note.
    private func drawString(_ record: EMFPlusRecord, sBit: Bool, fontID: Int, log: inout EMFRenderLog) {
        guard let decoded = EMFPlusText.decodeString(record.data),
              !decoded.string.isEmpty,
              let font = table.font(fontID),
              let color = textFillColor(sBit: sBit, brushID: decoded.brushId, log: &log) else { return }

        // Optional StringFormat: alignment is honoured; other formatting is not.
        let format = table.stringFormat(Int(decoded.formatId & 0xFF))
        if let format, Self.formatSimplified(format) {
            log.noteEMFPlusApproximated(.stringFormatSimplified)
        }
        let horizontal = format?.stringAlignment ?? 0   // StringAlignmentNear
        let vertical = format?.lineAlign ?? 0

        let sized = sizedFont(font, log: &log)
        guard let line = makeCTLine(decoded.string, font: sized, color: color) else { return }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // LayoutRect (world) → device. An axis-aligned world transform (the common
        // case) maps exactly; a rotated/sheared transform yields its bounding box
        // (best-effort — glyphs stay upright, the same approximation family as the
        // GDI text path's average-scale sizing).
        let rectDevice = decoded.layoutRect.applying(worldToDevice)
        let origin = EMFPlusText.drawStringOrigin(
            rectDevice: rectDevice, lineWidth: lineWidth, ascent: ascent, descent: descent,
            horizontal: horizontal, vertical: vertical)

        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(state.antialias)
        // Enter device space (base carries the canvas fit + single y-flip), move to
        // the baseline origin, then flip y so glyphs render UPRIGHT through base's
        // y-down→y-up flip — the same discipline as the GDI TextDrawer.
        context.concatenate(base)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    /// EmfPlusDrawDriverString ([MS-EMFPLUS] §2.3.4.6): per-glyph positioned text.
    /// With CmapLookup the values are characters drawn through the mapped font;
    /// without it they are raw font glyph indices drawn via CTFontDrawGlyphs. Each
    /// GlyphPos is a baseline origin in world space. Vertical and realized-advance
    /// options are simplified to a horizontal, advance-computed run.
    private func drawDriverString(_ record: EMFPlusRecord, sBit: Bool, fontID: Int, log: inout EMFRenderLog) {
        guard let decoded = EMFPlusText.decodeDriverString(record.data),
              !decoded.values.isEmpty,
              let font = table.font(fontID),
              let color = textFillColor(sBit: sBit, brushID: decoded.brushId, log: &log) else { return }
        if decoded.vertical || decoded.realizedAdvance {
            log.noteEMFPlusApproximated(.stringFormatSimplified)
        }

        let sized = sizedFont(font, log: &log)
        let glyphs = mapDriverGlyphs(decoded.values, cmapLookup: decoded.cmapLookup, font: sized)

        // Positions: world → device (optional per-glyph matrix first). Under
        // RealizedAdvance only the first origin is present; the rest advance by the
        // font's own device-space horizontal advances.
        let toDevice = (decoded.matrix ?? .identity).concatenating(worldToDevice)
        let devicePositions: [CGPoint]
        if decoded.realizedAdvance {
            devicePositions = realizedAdvancePositions(glyphs: glyphs, font: sized, firstWorld: decoded.positions.first, toDevice: toDevice)
        } else {
            devicePositions = decoded.positions.map { $0.applying(toDevice) }
        }
        guard !glyphs.isEmpty, devicePositions.count == glyphs.count else { return }
        // In the flipped device frame (after scaleBy(1,-1)) a device point (px, py)
        // sits at local (px, -py); the flip makes the glyph outlines upright.
        let localPositions = devicePositions.map { CGPoint(x: $0.x, y: -$0.y) }

        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(state.antialias)
        context.setFillColor(color)
        context.concatenate(base)
        context.scaleBy(x: 1, y: -1)
        glyphs.withUnsafeBufferPointer { glyphBuffer in
            localPositions.withUnsafeBufferPointer { positionBuffer in
                guard let glyphBase = glyphBuffer.baseAddress,
                      let positionBase = positionBuffer.baseAddress else { return }
                CTFontDrawGlyphs(sized, glyphBase, positionBase, glyphs.count, context)
            }
        }
    }

    /// Maps DrawDriverString values to glyphs: CmapLookup treats them as Unicode
    /// characters (one glyph per UTF-16 unit, .notdef for a lone surrogate half);
    /// otherwise they are already font glyph indices.
    private func mapDriverGlyphs(_ values: [UInt16], cmapLookup: Bool, font: CTFont) -> [CGGlyph] {
        guard cmapLookup else { return values.map { CGGlyph($0) } }
        var glyphs = [CGGlyph](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { charBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let charBase = charBuffer.baseAddress,
                      let glyphBase = glyphBuffer.baseAddress else { return }
                CTFontGetGlyphsForCharacters(font, charBase, glyphBase, values.count)
            }
        }
        return glyphs
    }

    /// The device-space baseline origins for a RealizedAdvance run: the first
    /// origin (world → device), then each subsequent glyph advanced by the font's
    /// own horizontal advance ([MS-EMFPLUS] §2.3.4.6 remarks).
    private func realizedAdvancePositions(
        glyphs: [CGGlyph], font: CTFont, firstWorld: CGPoint?, toDevice: CGAffineTransform
    ) -> [CGPoint] {
        guard let firstWorld else { return [] }
        let start = firstWorld.applying(toDevice)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        _ = glyphs.withUnsafeBufferPointer { glyphBuffer -> Double in
            advances.withUnsafeMutableBufferPointer { advanceBuffer -> Double in
                guard let glyphBase = glyphBuffer.baseAddress,
                      let advanceBase = advanceBuffer.baseAddress else { return 0 }
                return CTFontGetAdvancesForGlyphs(font, .horizontal, glyphBase, advanceBase, glyphs.count)
            }
        }
        var result: [CGPoint] = []
        result.reserveCapacity(glyphs.count)
        var penX = start.x
        for advance in advances {
            result.append(CGPoint(x: penX, y: start.y))
            penX += advance.width
        }
        return result
    }

    /// The DC font resolved through the shared `FontMapper` substitution machinery
    /// (family + bold/italic traits) and sized to DEVICE units. EmSize is
    /// interpreted per its SizeUnit ([MS-EMFPLUS] §2.1.1.32): World/Display units
    /// scale by the world→device average scale (the same basis as pen widths and
    /// GDI text); Pixel is already device pixels. Guarded like
    /// FontMapper.devicePointSize — floored at 1 and capped so a hostile EmSize
    /// cannot feed CoreText an enormous outline-flatten size (§8).
    private func sizedFont(_ font: EMFPlusFont, log: inout EMFRenderLog) -> CTFont {
        let scale: CGFloat = font.sizeUnit == 0x02 ? 1 : StrokeMapper.averageScale(worldToDevice)
        var size = CGFloat(font.emSize) * scale
        if !size.isFinite || size < 1 { size = FontMapper.defaultHeight }
        size = min(size, FontMapper.maxDevicePointSize)
        let base = FontMapper.resolveFamily(font.familyName, bold: font.isBold, italic: font.isItalic, log: &log)
        return CTFontCreateCopyWithAttributes(base, size, nil, nil)
    }

    /// A CTLine carrying the font and foreground colour, or nil if the attributed
    /// string cannot be built (hostile content never traps the render path, §8).
    private func makeCTLine(_ string: String, font: CTFont, color: CGColor) -> CTLine? {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return nil }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// The foreground colour for a text run: a direct ARGB colour (S flag set) or
    /// the object-table brush's colour. A non-solid brush contributes a
    /// representative solid with its existing approximation note (a linear gradient
    /// uses its start colour, which needs no separate note); an unbound brush
    /// (S clear) returns nil so the run is skipped — best-effort partial output.
    private func textFillColor(sBit: Bool, brushID: UInt32, log: inout EMFRenderLog) -> CGColor? {
        if sBit { return EMFPlusGeometry.cgColor(argb(brushID)) }
        guard let brush = table.brush(Int(brushID & 0xFF)) else { return nil }
        switch brush.data {
        case .solid(let color):
            return EMFPlusGeometry.cgColor(color)
        case .linearGradient(let gradient):
            return EMFPlusGeometry.cgColor(gradient.startColor)
        case .hatch(_, let foreColor, _):
            log.noteEMFPlusApproximated(.hatchBrush)
            return EMFPlusGeometry.cgColor(foreColor)
        case .pathGradient(let gradient):
            log.noteEMFPlusApproximated(.pathGradientBrush)
            return EMFPlusGeometry.cgColor(gradient.centerColor)
        case .texture:
            log.noteEMFPlusApproximated(.textureBrush)
            return EMFPlusGeometry.cgColor(EMFPlusARGB(blue: 0, green: 0, red: 0, alpha: 255))
        }
    }

    /// True when a StringFormat carries a non-default feature the single-line,
    /// left-to-right playback ignores: a right-to-left or vertical direction flag
    /// ([MS-EMFPLUS] §2.1.2.8), an ellipsis trimming mode (§2.1.1.30, which would
    /// insert "…"), defined tab stops or character ranges, or hotkey-prefix
    /// processing (§2.1.1.14). Plain alignment/None-trimming formats return false
    /// (nothing was simplified), so the common case logs nothing.
    private static func formatSimplified(_ format: EMFPlusStringFormat) -> Bool {
        let flags = format.stringFormatFlags
        let rtl = flags & 0x0001 != 0
        let vertical = flags & 0x0002 != 0
        let ellipsisTrimming = format.trimming >= 3
        return rtl || vertical || ellipsisTrimming
            || !format.tabStops.isEmpty
            || !format.characterRanges.isEmpty
            || format.hotkeyPrefix != 0
    }

    // MARK: - Images (§2.3.4.8 / §2.3.4.9)

    /// EmfPlusDrawImage ([MS-EMFPLUS] §2.3.4.8): ImageAttributesID (u32), SrcUnit
    /// (i32), SrcRect (EmfPlusRectF), RectData (EmfPlusRect if the C flag is set,
    /// else EmfPlusRectF). The dest rect's three defining corners become the
    /// (axis-aligned) parallelogram the SrcRect portion is scaled to fill. A
    /// negative dest extent mirrors the image (its sign carries through).
    private mutating func drawImage(_ record: EMFPlusRecord, objectID: Int, cBit: Bool, log: inout EMFRenderLog) {
        var reader = PlusReader(record.data)
        guard let attributesID = reader.u32(), let srcUnit = reader.i32(),
              let srcRect = reader.rectF(), let dest = reader.rect(compressed: cBit) else { return }
        // Raw origin/size (not standardized) so a negative extent still mirrors.
        let x = dest.origin.x, y = dest.origin.y
        let w = dest.size.width, h = dest.size.height
        drawImageMapped(
            objectID: objectID, srcRect: srcRect, srcUnit: srcUnit,
            upperLeft: CGPoint(x: x, y: y),
            upperRight: CGPoint(x: x + w, y: y),
            lowerLeft: CGPoint(x: x, y: y + h),
            attributesID: attributesID, log: &log
        )
    }

    /// EmfPlusDrawImagePoints ([MS-EMFPLUS] §2.3.4.9): ImageAttributesID (u32),
    /// SrcUnit (i32), SrcRect (EmfPlusRectF), Count (u32, MUST be 3), PointData —
    /// the upper-left, upper-right, and lower-left corners of a parallelogram
    /// (the fourth corner is extrapolated). The P flag (relative points) is
    /// unsupported like every other relative-encoded record.
    private mutating func drawImagePoints(_ record: EMFPlusRecord, objectID: Int, cBit: Bool, relative: Bool, log: inout EMFRenderLog) {
        if relative { log.noteEMFPlusUnsupported(type: record.type); return }
        var reader = PlusReader(record.data)
        guard let attributesID = reader.u32(), let srcUnit = reader.i32(),
              let srcRect = reader.rectF(), let count = reader.u32(),
              let points = reader.points(count: Int(count), compressed: cBit),
              points.count >= 3 else { return }
        drawImageMapped(
            objectID: objectID, srcRect: srcRect, srcUnit: srcUnit,
            upperLeft: points[0], upperRight: points[1], lowerLeft: points[2],
            attributesID: attributesID, log: &log
        )
    }

    /// Draws the SrcRect portion of the object-`objectID` image into the
    /// parallelogram whose three defining corners are given (in WORLD space).
    /// Mirrors the GDI bitmap drawer's flip: the placement affine maps the
    /// top-down unit image square to the parallelogram, then an in-square y-flip
    /// lands image row 0 (top) on the upper-left→upper-right edge — upright
    /// through `base`'s canvas flip.
    private mutating func drawImageMapped(
        objectID: Int,
        srcRect: CGRect,
        srcUnit: Int32,
        upperLeft: CGPoint,
        upperRight: CGPoint,
        lowerLeft: CGPoint,
        attributesID: UInt32,
        log: inout EMFRenderLog
    ) {
        // Placement: unit square [0,1]² → parallelogram (world space), with
        // upper-left at the origin, upper-right along +x, lower-left along +y.
        let placement = CGAffineTransform(
            a: upperRight.x - upperLeft.x, b: upperRight.y - upperLeft.y,
            c: lowerLeft.x - upperLeft.x, d: lowerLeft.y - upperLeft.y,
            tx: upperLeft.x, ty: upperLeft.y
        )

        // Decode AT MOST ONCE per bound image object (audit H1 / A1), at a
        // resolution bounded by the image's device-space footprint (audit H1 /
        // A2). Many draws share one decode; an out-of-range slot is a clean
        // no-op; an undecodable image still re-notes its skip PER DRAW below.
        guard let decoded = decodedImage(objectID: objectID, destTargetRect: imageFootprint(placement: placement)) else { return }
        guard let cgFull = decoded.image else {
            if let skip = decoded.skip { note(imageSkip: skip, log: &log) }
            return
        }
        // A pixel bitmap decoded below native to fit the destination — re-noted
        // per draw so the coalesced count stays meaningful (audit H1 / A2).
        if decoded.downsampled { log.noteEMFPlusApproximated(.imageDownsampled) }
        // SrcUnit MUST be UnitTypePixel (2); anything else is treated as pixels.
        if srcUnit != 2 { log.noteEMFPlusApproximated(.imageSrcUnit) }
        // ImageAttributes are not applied in phase-4-A; note a tiling wrap.
        if let attributes = table.imageAttributes(Int(attributesID & 0xFF)),
           Self.wrapModeTiles(Int32(bitPattern: attributes.wrapMode)) {
            log.noteEMFPlusApproximated(.imageAttributes)
        }

        let cgImage = cropped(cgFull, toSrcRect: srcRect)

        let determinant = placement.a * placement.d - placement.b * placement.c
        guard placement.a.isFinite, placement.b.isFinite, placement.c.isFinite,
              placement.d.isFinite, placement.tx.isFinite, placement.ty.isFinite,
              determinant != 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(state.antialias)
        // InterpolationMode is not tracked; nearest-neighbor keeps the decode
        // deterministic and matches the GDI bitmap path's chunky-pixel policy.
        context.interpolationQuality = .none
        context.concatenate(full)
        context.concatenate(placement)
        context.translateBy(x: 0, y: 1)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The image square's device/target footprint: the unit square [0,1]² mapped
    /// by `placement ∘ full`, bounding-boxed — the EMF+ analogue of the GDI
    /// bitmap path's `destTargetRect`, driving the decode budget (audit H1 / A2).
    /// A non-finite corner (a hostile transform) yields a non-finite rect, which
    /// `decodeBudget` treats as "no bound" → native decode (§8: never trap).
    private func imageFootprint(placement: CGAffineTransform) -> CGRect {
        let toTarget = placement.concatenating(full)
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        ].map { $0.applying(toTarget) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The decoded image for object slot `objectID`, decoded once and cached
    /// (audit H1 / A1) at a resolution bounded by `destTargetRect` (audit H1 /
    /// A2); a rebind of the slot invalidates the entry (see the object
    /// dispatch). Returns `nil` only for an out-of-range slot. An in-range slot
    /// holding no image object caches a nil-image entry, so a repeated draw of
    /// an unbound slot stays a cheap, silent no-op.
    private mutating func decodedImage(objectID: Int, destTargetRect: CGRect) -> CachedImage? {
        if let cached = imageCache.cached(objectID) { return cached }
        guard (0 ..< 64).contains(objectID) else { return nil }
        let value: CachedImage
        if let plusImage = table.image(objectID) {
            let (image, skip, downsampled) = EMFPlusImageDecoder.decode(plusImage, destTargetRect: destTargetRect)
            value = CachedImage(image: image, skip: skip, downsampled: downsampled)
        } else {
            value = CachedImage(image: nil, skip: nil)
        }
        imageCache.store(objectID, value)
        return value
    }

    /// Crops `image` to the SrcRect sub-rectangle (SOURCE pixels, top-down). A
    /// whole-image, degenerate, or non-finite SrcRect passes the image through.
    /// SrcRect is a file-derived float rect, so it is finiteness-guarded and
    /// clamped to the image before any Int conversion (§8: no trapping casts).
    private func cropped(_ image: CGImage, toSrcRect srcRect: CGRect) -> CGImage {
        let width = image.width, height = image.height
        guard srcRect.origin.x.isFinite, srcRect.origin.y.isFinite,
              srcRect.size.width.isFinite, srcRect.size.height.isFinite else { return image }
        // Clamp to the image in float space first, so the Int casts are bounded.
        let fx = min(max(srcRect.origin.x, 0), CGFloat(width))
        let fy = min(max(srcRect.origin.y, 0), CGFloat(height))
        let fw = min(max(srcRect.size.width, 0), CGFloat(width))
        let fh = min(max(srcRect.size.height, 0), CGFloat(height))
        let x = Int(fx), y = Int(fy)
        let w = min(Int(fw.rounded()), width - x)
        let h = min(Int(fh.rounded()), height - y)
        // Whole image (or a rect that covers it) → no crop.
        if x == 0, y == 0, w >= width, h >= height { return image }
        guard w > 0, h > 0 else { return image }
        return image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) ?? image
    }

    /// Maps an image-decode `Skip` to its render-log note.
    private func note(imageSkip: EMFPlusImageDecoder.Skip, log: inout EMFRenderLog) {
        switch imageSkip {
        case .pixelFormat(let format): log.noteEMFPlusApproximated(.imageBitmapPixelFormat(format))
        case .invalid: log.noteEMFPlusApproximated(.imageInvalid)
        case .compressed: log.noteEMFPlusApproximated(.imageCompressed)
        case .metafile: log.noteEMFPlusApproximated(.imageMetafile)
        case .oversized: log.noteEMFPlusApproximated(.imageOversized)
        }
    }

    // MARK: - Fill / stroke primitives

    private func fillTargetPath(_ path: CGPath, fill: Fill, rule: CGPathFillRule, log: inout EMFRenderLog) {
        guard !path.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(state.antialias)

        switch fill {
        case .color(let color):
            context.setFillColor(EMFPlusGeometry.cgColor(color))
            context.addPath(path)
            context.fillPath(using: rule)
        case .brush(let brush):
            fillBrush(brush, path: path, rule: rule, log: &log)
        }
    }

    private func fillBrush(_ brush: EMFPlusBrush, path: CGPath, rule: CGPathFillRule, log: inout EMFRenderLog) {
        func solid(_ color: EMFPlusARGB) {
            context.setFillColor(EMFPlusGeometry.cgColor(color))
            context.addPath(path)
            context.fillPath(using: rule)
        }
        switch brush.data {
        case .solid(let color):
            solid(color)
        case .linearGradient(let gradient):
            if let cgGradient = EMFPlusPaint.linearGradient(gradient),
               let axis = EMFPlusPaint.linearGradientAxis(gradient, full: full) {
                // The fill clamps to the axis (drawsBefore/AfterEndLocation), so
                // a tiling wrap mode ([MS-EMFPLUS] §2.1.1.33) is not reproduced;
                // Clamp (0x04) is honoured exactly.
                if Self.wrapModeTiles(gradient.wrapMode) { log.noteEMFPlusApproximated(.linearGradientWrapMode) }
                context.addPath(path)
                context.clip(using: rule)
                context.drawLinearGradient(
                    cgGradient, start: axis.start, end: axis.end,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                solid(gradient.startColor)
            }
        case .hatch(_, let foreColor, _):
            log.noteEMFPlusApproximated(.hatchBrush)
            solid(foreColor)
        case .pathGradient(let gradient):
            log.noteEMFPlusApproximated(.pathGradientBrush)
            solid(gradient.centerColor)
        case .texture:
            log.noteEMFPlusApproximated(.textureBrush)
        }
    }

    private func strokeTargetPath(_ path: CGPath, pen: EMFPlusPen?, log: inout EMFRenderLog) {
        guard let pen, !path.isEmpty else { return }
        let style = EMFPlusPaint.strokeStyle(pen, full: full, log: &log)
        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(state.antialias)
        context.setStrokeColor(style.color)
        context.setLineWidth(style.width)
        context.setLineCap(style.cap)
        context.setLineJoin(style.join)
        context.setMiterLimit(style.miterLimit)
        context.setLineDash(phase: style.dash.isEmpty ? 0 : style.dashPhase, lengths: style.dash)
        context.addPath(path)
        context.strokePath()
    }

    /// EmfPlusClear (§2.3.4.1): paint the whole output surface with `color`,
    /// under the current clip, ignoring the transforms. The fill covers a
    /// rectangle far larger than any canvas so the entire clipped area is
    /// cleared.
    private func clear(_ color: EMFPlusARGB, log: inout EMFRenderLog) {
        context.saveGState()
        defer { context.restoreGState() }
        state.clip.apply(to: context, deviceToTarget: base)
        context.setShouldAntialias(false)
        context.setFillColor(EMFPlusGeometry.cgColor(color))
        context.fill(CGRect(x: -10_000_000, y: -10_000_000, width: 20_000_000, height: 20_000_000))
    }

    // MARK: - Transform handlers

    private mutating func setWorldTransform(_ record: EMFPlusRecord) {
        if let m = readMatrix(record) { state.world = m }
    }

    private mutating func multiplyWorldTransform(_ record: EMFPlusRecord, flags: UInt16) {
        guard let m = readMatrix(record) else { return }
        applyWorld(m, postMultiply: (flags & 0x2000) != 0)
    }

    private mutating func translateWorldTransform(_ record: EMFPlusRecord, flags: UInt16) {
        var reader = PlusReader(record.data)
        guard let dx = reader.f32(), let dy = reader.f32() else { return }
        applyWorld(CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy)), postMultiply: (flags & 0x2000) != 0)
    }

    private mutating func scaleWorldTransform(_ record: EMFPlusRecord, flags: UInt16) {
        var reader = PlusReader(record.data)
        guard let sx = reader.f32(), let sy = reader.f32() else { return }
        applyWorld(CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)), postMultiply: (flags & 0x2000) != 0)
    }

    private mutating func rotateWorldTransform(_ record: EMFPlusRecord, flags: UInt16) {
        var reader = PlusReader(record.data)
        guard let angle = reader.f32() else { return }
        applyWorld(CGAffineTransform(rotationAngle: CGFloat(angle) * .pi / 180), postMultiply: (flags & 0x2000) != 0)
    }

    /// Composes `m` into the world transform. The A flag (§2.3.9): clear =
    /// pre-multiply / prepend (m applied FIRST, the GDI+ default), set =
    /// post-multiply / append (m applied LAST). CG's row-vector
    /// `a.concatenating(b)` means "apply a then b".
    private mutating func applyWorld(_ m: CGAffineTransform, postMultiply: Bool) {
        state.world = postMultiply ? state.world.concatenating(m) : m.concatenating(state.world)
    }

    private mutating func setPageTransform(_ record: EMFPlusRecord, flags: UInt16, log: inout EMFRenderLog) {
        var reader = PlusReader(record.data)
        guard let scale = reader.f32() else { return }
        // PageUnit is the low byte of Flags; only UnitTypePixel (2) is honoured
        // exactly. Other units are treated as pixels (§2.3.9.5) with a note.
        let pageUnit = flags & 0x00FF
        if pageUnit != 0x02 && pageUnit != 0x00 { log.noteEMFPlusApproximated(.pageUnit) }
        let s = CGFloat(scale)
        state.page = CGAffineTransform(scaleX: s, y: s)
    }

    private mutating func beginContainer(_ record: EMFPlusRecord, log: inout EMFRenderLog) {
        var reader = PlusReader(record.data)
        guard let dest = reader.rectF(), let src = reader.rectF(), let index = reader.u32() else { return }
        savedContainers[index] = state
        // Apply the src → dest mapping as an additional world transform. The
        // page-unit conversion is not modelled, so this is a logged
        // approximation (§2.3.7.1).
        log.noteEMFPlusApproximated(.container)
        guard src.width != 0, src.height != 0 else { return }
        let sx = dest.width / src.width
        let sy = dest.height / src.height
        let mapping = CGAffineTransform(translationX: -src.minX, y: -src.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: dest.minX, y: dest.minY))
        applyWorld(mapping, postMultiply: false)
    }

    // MARK: - Clip handlers

    private mutating func setClipRect(_ record: EMFPlusRecord, flags: UInt16, log: inout EMFRenderLog) {
        var reader = PlusReader(record.data)
        guard let rect = reader.rectF() else { return }
        let deviceRect = rect.standardized.applying(worldToDevice)
        combineClip(.rects([deviceRect]), mode: (UInt32(flags) >> 8) & 0x0F, log: &log)
    }

    private mutating func setClipPath(_ record: EMFPlusRecord, flags: UInt16, log: inout EMFRenderLog) {
        guard let plusPath = table.path(Int(flags & 0x00FF)) else { return }
        let path = CGMutablePath()
        EMFPlusGeometry.appendPath(plusPath, to: path, transform: worldToDevice)
        combineClip(.path(path), mode: (UInt32(flags) >> 8) & 0x0F, log: &log)
    }

    private mutating func setClipRegion(_ record: EMFPlusRecord, flags: UInt16, log: inout EMFRenderLog) {
        guard let region = table.region(Int(flags & 0x00FF)) else { return }
        let path = EMFPlusGeometry.regionPath(region.root, transform: worldToDevice, log: &log)
        combineClip(.path(path), mode: (UInt32(flags) >> 8) & 0x0F, log: &log)
    }

    /// Combines `primitive` into the clip per a CombineMode ([MS-EMFPLUS]
    /// §2.1.1.4). Replace and Intersect are exact; Union/XOR/Exclude/Complement
    /// cannot be expressed by CoreGraphics' monotonic-intersection clip and are
    /// applied as an intersection (best effort) with a note.
    private mutating func combineClip(_ primitive: ClipRegion.Primitive, mode: UInt32, log: inout EMFRenderLog) {
        switch mode {
        case 0x00:   // Replace
            state.clip.replace(with: primitive)
        case 0x01:   // Intersect
            state.clip.intersect(primitive)
        default:     // Union / XOR / Exclude / Complement
            log.noteEMFPlusApproximated(.clipCombineMode)
            state.clip.intersect(primitive)
        }
    }

    // MARK: - Small readers / helpers

    /// The first u32 of a record's data (a StackIndex).
    private func firstU32(_ record: EMFPlusRecord) -> UInt32? {
        var reader = PlusReader(record.data)
        return reader.u32()
    }

    /// A 24-byte EmfPlusTransformMatrix (§2.2.2.47) as a CGAffineTransform.
    private func readMatrix(_ record: EMFPlusRecord) -> CGAffineTransform? {
        var reader = PlusReader(record.data)
        guard let m11 = reader.f32(), let m12 = reader.f32(), let m21 = reader.f32(),
              let m22 = reader.f32(), let dx = reader.f32(), let dy = reader.f32() else { return nil }
        return CGAffineTransform(
            a: CGFloat(m11), b: CGFloat(m12), c: CGFloat(m21), d: CGFloat(m22),
            tx: CGFloat(dx), ty: CGFloat(dy)
        )
    }

    /// An EmfPlusARGB (§2.2.2.1) from a little-endian u32 (0xAARRGGBB).
    private func argb(_ value: UInt32) -> EMFPlusARGB {
        EMFPlusARGB(
            blue: UInt8(value & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            red: UInt8((value >> 16) & 0xFF),
            alpha: UInt8((value >> 24) & 0xFF)
        )
    }

    /// True for the four tiling WrapMode values ([MS-EMFPLUS] §2.1.1.33):
    /// 0x00 Tile and 0x01–0x03 tile-with-flip. 0x04 Clamp (and any undefined
    /// value) is not treated as tiling.
    private static func wrapModeTiles(_ wrapMode: Int32) -> Bool { (0 ... 3).contains(wrapMode) }

    /// The fill source for a drawing record: a direct colour when the S flag is
    /// set, else the object-table brush. Nil (skip the fill) when the S flag is
    /// clear and the brush id is unbound (best-effort partial output).
    private func fillSource(sBit: Bool, brushId: UInt32) -> Fill? {
        if sBit { return .color(argb(brushId)) }
        guard let brush = table.brush(Int(brushId & 0xFF)) else { return nil }
        return .brush(brush)
    }
}

// MARK: - Decoded-image cache (audit H1 / A1)

/// One decoded EMF+ image, cached per object slot. `image == nil` with a `skip`
/// is a remembered decode FAILURE, and `image == nil` with no `skip` is "the
/// slot holds no image object" — neither is retried, but the playback still
/// re-emits the per-draw skip note so log counts stay meaningful. `downsampled`
/// records that the pixel decode fell below native resolution (audit H1 / A2),
/// re-noted per draw for the same reason.
struct CachedImage {
    let image: CGImage?
    let skip: EMFPlusImageDecoder.Skip?
    let downsampled: Bool

    init(image: CGImage?, skip: EMFPlusImageDecoder.Skip?, downsampled: Bool = false) {
        self.image = image
        self.skip = skip
        self.downsampled = downsampled
    }
}

/// A per-object-slot cache of decoded EMF+ images: the decode runs AT MOST ONCE
/// per bound image object; `invalidate(_:)` drops a slot when the object table
/// rebinds it, so a redefined id re-decodes. Kept struct-local to a playback
/// instance — never static — because Quick Look renders files concurrently.
struct DecodedImageCache {
    private var slots: [CachedImage?]
    /// How many decodes have been STORED — test-visible (via `@testable`) proof
    /// that N draws over one object decode once, not N times.
    private(set) var storeCount = 0

    init(capacity: Int = 64) {
        slots = Array(repeating: nil, count: max(0, capacity))
    }

    /// The cached decode for `id`, or `nil` when the slot has not been decoded
    /// yet (or `id` is out of range).
    func cached(_ id: Int) -> CachedImage? {
        slots.indices.contains(id) ? slots[id] : nil
    }

    /// Stores `value` for `id` (an out-of-range id is ignored).
    mutating func store(_ id: Int, _ value: CachedImage) {
        guard slots.indices.contains(id) else { return }
        slots[id] = value
        storeCount += 1
    }

    /// Drops any cached decode for `id` (called when the slot is rebound).
    mutating func invalidate(_ id: Int) {
        guard slots.indices.contains(id) else { return }
        slots[id] = nil
    }
}

// MARK: - Object table

/// The 64-slot EMF+ object table ([MS-EMFPLUS] §3.1.2), bound DURING playback
/// at each EmfPlusObject record's STREAM POSITION so an id redefined mid-stream
/// takes effect from that point (real files reuse ids). Continuation framing
/// (the C flag) is reassembled here, mirroring the arbitrated wire format in
/// EMFParse's `EMFPlusStream.objectDefinitions()`: every chunk repeats a 4-byte
/// TotalObjectSize prefix, and a sequence completes once the accumulated
/// `DataSize − 4` bytes reach TotalObjectSize (C is advisory). The typed decode
/// itself is delegated to `EMFPlusObjectDefinition.decodedValue()`.
private struct ObjectTable {
    private var slots: [EMFPlusObjectValue?] = Array(repeating: nil, count: 64)

    private struct Pending {
        let id: UInt8
        let rawType: UInt8
        let total: Int
        var data: Data
    }
    private var pending: Pending?

    /// Applies an EmfPlusObject record, returning the slot id it BOUND (wrote),
    /// or `nil` when the record only accumulated a continuation chunk or named
    /// an out-of-range slot. The caller uses the returned id to invalidate any
    /// image cached for that slot (A1).
    mutating func apply(_ record: EMFPlusRecord) -> UInt8? {
        let flags = record.flags
        let continues = (flags & 0x8000) != 0
        let rawType = UInt8((flags >> 8) & 0x7F)
        let id = UInt8(flags & 0x00FF)

        // Resolve any in-progress continued sequence first.
        if var p = pending {
            if continues, id == p.id, rawType == p.rawType {
                let chunk = [UInt8](record.data)
                guard chunk.count >= 4 else { pending = nil; return nil }
                p.data.append(contentsOf: chunk[4...])
                if p.data.count >= p.total {
                    let bound = bind(id: p.id, rawType: p.rawType, data: Data(p.data.prefix(p.total)))
                    pending = nil
                    return bound
                } else {
                    pending = p
                    return nil
                }
            }
            pending = nil   // sequence can no longer complete; reprocess fresh
        }

        if continues {
            let chunk = [UInt8](record.data)
            guard chunk.count >= 4 else { return nil }
            let total = Int(UInt32(chunk[0]) | (UInt32(chunk[1]) << 8) | (UInt32(chunk[2]) << 16) | (UInt32(chunk[3]) << 24))
            let objectBytes = Data(chunk[4...])
            if objectBytes.count >= total {
                return bind(id: id, rawType: rawType, data: Data(objectBytes.prefix(total)))
            } else {
                pending = Pending(id: id, rawType: rawType, total: total, data: objectBytes)
                return nil
            }
        } else {
            return bind(id: id, rawType: rawType, data: record.data)
        }
    }

    /// Binds a decoded object into `id`'s slot, returning `id` on success or
    /// `nil` for an out-of-range slot.
    private mutating func bind(id: UInt8, rawType: UInt8, data: Data) -> UInt8? {
        guard id < 64 else { return nil }
        let definition = EMFPlusObjectDefinition(
            objectID: id, objectType: EMFPlusObjectType(rawValue: rawType), data: data
        )
        slots[Int(id)] = definition.decodedValue()
        return id
    }

    private func value(_ id: Int) -> EMFPlusObjectValue? {
        (0 ..< 64).contains(id) ? slots[id] : nil
    }

    func brush(_ id: Int) -> EMFPlusBrush? { if case .brush(let value)? = value(id) { return value }; return nil }
    func pen(_ id: Int) -> EMFPlusPen? { if case .pen(let value)? = value(id) { return value }; return nil }
    func path(_ id: Int) -> EMFPlusPath? { if case .path(let value)? = value(id) { return value }; return nil }
    func region(_ id: Int) -> EMFPlusRegion? { if case .region(let value)? = value(id) { return value }; return nil }
    func image(_ id: Int) -> EMFPlusImage? { if case .image(let value)? = value(id) { return value }; return nil }
    func imageAttributes(_ id: Int) -> EMFPlusImageAttributes? { if case .imageAttributes(let value)? = value(id) { return value }; return nil }
    func font(_ id: Int) -> EMFPlusFont? { if case .font(let value)? = value(id) { return value }; return nil }
    func stringFormat(_ id: Int) -> EMFPlusStringFormat? { if case .stringFormat(let value)? = value(id) { return value }; return nil }
}
