import CoreGraphics
import CoreText
import EMFParse
import Foundation

/// EMR_EXTTEXTOUTW playback ([MS-EMF] §2.3.5.8, EmrText §2.2.5). Draws a
/// UTF-16LE run with the DC's current font and text colour.
///
/// Positioning model: the reference point (logical) is mapped through the full
/// logical→target transform to an ANCHOR in canvas space; the font is sized to
/// the device by that transform's average scale (same approximation family as
/// geometric pen widths, `FontMapper.devicePointSize`). Glyphs are drawn around
/// the anchor with an explicit y-flip so they come out UPRIGHT through the
/// canvas transform's y-down→y-up flip — the mirrored-text trap the snapshot
/// tests catch. Escapement rotates the baseline about the anchor.
enum TextDrawer {

    static func draw(
        _ text: ExtTextPayload,
        into context: CGContext,
        dc: inout DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // ETO_GLYPH_INDEX: the string holds Windows glyph ids, which do not map
        // to the substituted macOS font — skip the run with a coalesced log.
        if text.options.glyphIndex {
            log.noteGlyphIndexTextSkipped()
            return
        }
        guard !text.string.isEmpty else {
            // An empty string can still carry an ETO_OPAQUE background rect.
            paintOpaqueRectIfNeeded(text, into: context, dc: dc, base: base)
            return
        }

        // Everything below works in DEVICE space: `context.concatenate(base)`
        // enters it (base carries the canvas fit + the single y-down→y-up flip),
        // so the font is sized by the LOGICAL→DEVICE scale and the anchor mapped
        // by the LOGICAL→DEVICE transform. `base` then scales device→canvas
        // uniformly, glyphs included — the composed-average-scale approximation
        // (same family as geometric pen widths) applies once, here.
        let logicalToDevice = dc.resolvedTransform
        let font = sizedFont(dc: dc, logicalToDevice: logicalToDevice)
        let color = cgColor(dc.state.textColor)

        // The anchor in DEVICE space: reference point, or the current position
        // under TA_UPDATECP.
        let align = dc.state.textAlign
        let anchorLogical: CGPoint
        if align.updatesCurrentPosition {
            anchorLogical = PathBuilder.cgPoint(dc.state.currentPosition)
        } else {
            anchorLogical = PathBuilder.cgPoint(text.reference)
        }
        let anchor = anchorLogical.applying(logicalToDevice)

        // Build the line for width/metrics (used by alignment and non-Dx draw).
        // Underline is a CoreText attribute on the CTLine path (kCTUnderline…);
        // the Dx path can't use it and draws its own underline below. A nil line
        // (attributed-string build failure on hostile content) skips the run.
        guard let line = makeLine(text.string, font: font, color: color, underline: dc.state.font?.underline == true) else {
            return
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // Horizontal offset of the drawing origin from the anchor.
        let horizontalOffset: CGFloat
        switch align.horizontal {
        case .left: horizontalOffset = 0
        case .center: horizontalOffset = -lineWidth / 2
        case .right: horizontalOffset = -lineWidth
        }

        // Vertical: the anchor's relation to the BASELINE, in the run's local
        // y-UP frame (after the `scale(1,-1)` below): TOP → the baseline sits
        // `ascent` below the top-anchor → local −ascent; BOTTOM → `descent`
        // above the bottom-anchor → local +descent; BASELINE → the anchor IS
        // the baseline (local 0).
        let baselineDrop: CGFloat
        switch align.vertical {
        case .top: baselineDrop = -ascent
        case .bottom: baselineDrop = descent
        case .baseline: baselineDrop = 0
        }

        // Escapement: tenths of a degree, counterclockwise ([MS-EMF] §2.2.13).
        let escapementRadians = Double(dc.state.font?.escapementTenths ?? 0) * .pi / 1800

        // Optional background paint (ETO_OPAQUE rect, or bkMode OPAQUE run box).
        paintBackground(
            text, into: context, dc: dc, base: base,
            anchor: anchor, horizontalOffset: horizontalOffset,
            baselineDrop: baselineDrop,
            ascent: ascent, descent: descent, lineWidth: lineWidth,
            escapementRadians: escapementRadians
        )

        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)

        // Enter device space (base = device→canvas, y-flip included).
        context.concatenate(base)

        // ETO_CLIPPED: clip to the payload rectangle (logical → device).
        if text.options.clipped {
            let clipRect = PathBuilder.cgRect(text.rectangle)
            let path = CGMutablePath()
            path.addRect(clipRect, transform: logicalToDevice)
            context.addPath(path)
            context.clip()
        }

        // Move to the device anchor, rotate for escapement, then flip y so the
        // glyphs (whose ascenders point +y) render UPRIGHT against device y-down.
        // Escapement is CCW ON SCREEN; the rotation is applied in device space
        // (y-down) BEFORE the y-flip, so screen-CCW is a NEGATIVE device-space
        // angle (worked through in TextDrawer's header note).
        context.translateBy(x: anchor.x, y: anchor.y)
        if escapementRadians != 0 {
            context.rotate(by: CGFloat(-escapementRadians))
        }
        context.scaleBy(x: 1, y: -1)
        // Origin of the run's baseline, relative to the (now local, y-up) anchor.
        let originX = horizontalOffset
        let originY = baselineDrop

        // Dx advances are LOGICAL units, scaled to device by the logical→device
        // average scale (the font's own sizing basis).
        let dxScale = StrokeMapper.averageScale(logicalToDevice)

        if let dx = text.dx, !dx.isEmpty {
            drawWithDx(
                text.string, dx: dx, pdy: text.options.pdy,
                font: font, color: color,
                originX: originX, originY: originY,
                scale: dxScale,
                into: context
            )
            // Dx path draws bare glyphs; underline is drawn manually too.
            if dc.state.font?.underline == true {
                drawUnderline(font: font, color: color, originX: originX, originY: originY, width: lineWidth, into: context)
            }
        } else {
            context.textPosition = CGPoint(x: originX, y: originY)
            CTLineDraw(line, context)
        }

        // Strike-out: CoreText has no strikethrough attribute, so draw a manual
        // line through the run (≈ half the x-height above the baseline).
        if dc.state.font?.strikeOut == true {
            drawStrikeOut(font: font, color: color, originX: originX, originY: originY, width: lineWidth, into: context)
        }

        // TA_UPDATECP: advance the current position by the run's typographic
        // width (in logical units — divide the device width back out). The
        // advance is clamped end to end: a hostile font size + long string can
        // make it astronomically large, so the Double is clamped into Int32
        // range and the sum done in Int64 with a saturating narrow — no trap,
        // no silent wrap for ANY finite Double (§8).
        if align.updatesCurrentPosition {
            let advanceLogical = dxScale > 0 ? lineWidth / dxScale : 0
            let advance = clampedInt32(advanceLogical.rounded())
            dc.state.currentPosition = PointL(
                x: Int32(clamping: Int64(dc.state.currentPosition.x) + Int64(advance)),
                y: dc.state.currentPosition.y
            )
        }
    }

    /// A finite Double rounded and saturated into Int32 range. `Int32(_: Double)`
    /// traps on non-finite input and on magnitudes at/beyond 2^31; this returns
    /// the nearest representable Int32 instead (0 for NaN).
    private static func clampedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value)
    }

    // MARK: - Font + line

    /// The DC's selected font sized to DEVICE units, or the system font when
    /// none is selected. Underline is applied as a CoreText attribute on the
    /// line; strike-out is drawn manually (CoreText has no strikethrough
    /// attribute).
    private static func sizedFont(dc: DeviceContext, logicalToDevice: CGAffineTransform) -> CTFont {
        let resolved = dc.state.font
        let base = resolved?.base ?? FontMapper.systemBaseFont()
        let size = FontMapper.devicePointSize(
            logicalHeight: resolved?.logicalHeight ?? 0,
            logicalToTarget: logicalToDevice
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, nil)
    }

    /// A CTLine carrying the font, foreground colour, and (if the DC font asks
    /// for it) a single underline. Returns `nil` if the attributed string
    /// cannot be built — hostile string content never traps the render path
    /// (primer §8: this parser feeds a Quick Look preview).
    private static func makeLine(_ string: String, font: CTFont, color: CGColor, underline: Bool = false) -> CTLine? {
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        if underline {
            attributes[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
        }
        guard let attributed = CFAttributedStringCreate(
            nil, string as CFString, attributes as CFDictionary
        ) else { return nil }
        return CTLineCreateWithAttributedString(attributed)
    }

    // MARK: - Dx positioning

    /// Draws the run positioning each code unit from the Dx advance array
    /// ([MS-EMF] §2.2.5). BMP-exact: one glyph per UTF-16 code unit;
    /// ETO_PDY pairs are (dx, dy) per unit. Surrogate pairs collapse to one
    /// glyph plus a zero glyph — Dx handling is per-code-unit (approximation
    /// beyond the BMP). Advances are LOGICAL units, scaled to device by `scale`.
    private static func drawWithDx(
        _ string: String,
        dx: [UInt32],
        pdy: Bool,
        font: CTFont,
        color: CGColor,
        originX: CGFloat,
        originY: CGFloat,
        scale: CGFloat,
        into context: CGContext
    ) {
        let units = Array(string.utf16)
        guard !units.isEmpty else { return }

        // Map each UTF-16 unit to a glyph. CTFontGetGlyphsForCharacters returns
        // 0 (the .notdef glyph) for the trailing half of a surrogate pair.
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        units.withUnsafeBufferPointer { chars in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let charsBase = chars.baseAddress,
                      let glyphBase = glyphBuffer.baseAddress else { return }
                CTFontGetGlyphsForCharacters(font, charsBase, glyphBase, units.count)
            }
        }

        // Accumulate positions from the advance array. Each unit's advance is
        // dx[i] (single) or (dx[2i], dy[2i+1]) (PDY). Positions are baseline
        // origins in the run's local, y-flipped frame.
        var positions = [CGPoint]()
        positions.reserveCapacity(units.count)
        var penX = originX
        var penY = originY
        for index in 0 ..< units.count {
            positions.append(CGPoint(x: penX, y: penY))
            let advanceX: CGFloat
            let advanceY: CGFloat
            if pdy {
                let dxIndex = index * 2
                advanceX = dxIndex < dx.count ? CGFloat(dx[dxIndex]) : 0
                advanceY = dxIndex + 1 < dx.count ? CGFloat(dx[dxIndex + 1]) : 0
            } else {
                advanceX = index < dx.count ? CGFloat(dx[index]) : 0
                advanceY = 0
            }
            penX += advanceX * scale
            // dy advances DOWN in device y; in the y-flipped run frame that is
            // negative local y.
            penY -= advanceY * scale
        }

        context.setFillColor(color)
        glyphs.withUnsafeBufferPointer { glyphBuffer in
            positions.withUnsafeBufferPointer { positionBuffer in
                guard let glyphBase = glyphBuffer.baseAddress,
                      let positionBase = positionBuffer.baseAddress else { return }
                CTFontDrawGlyphs(font, glyphBase, positionBase, units.count, context)
            }
        }
    }

    // MARK: - Manual underline / strike-out

    /// Draws a single underline for the Dx path (the non-Dx path uses CoreText's
    /// underline attribute). In the run's local y-flipped frame the baseline is
    /// at local y = `originY` and above-baseline is POSITIVE local y, so the
    /// underline (below the baseline) is at a NEGATIVE offset.
    private static func drawUnderline(
        font: CTFont, color: CGColor,
        originX: CGFloat, originY: CGFloat, width: CGFloat,
        into context: CGContext
    ) {
        let thickness = max(1, CTFontGetUnderlineThickness(font))
        let position = CTFontGetUnderlinePosition(font)   // negative (below baseline)
        let y = originY + position
        context.setFillColor(color)
        context.fill(CGRect(x: originX, y: y - thickness / 2, width: width, height: thickness))
    }

    /// Draws a manual strike-through — CoreText has no strikethrough attribute.
    /// Placed ≈ half the x-height above the baseline (positive local y in the
    /// y-flipped run frame), thickness from the font's underline thickness.
    private static func drawStrikeOut(
        font: CTFont, color: CGColor,
        originX: CGFloat, originY: CGFloat, width: CGFloat,
        into context: CGContext
    ) {
        let thickness = max(1, CTFontGetUnderlineThickness(font))
        let xHeight = CTFontGetXHeight(font)
        let y = originY + xHeight / 2
        context.setFillColor(color)
        context.fill(CGRect(x: originX, y: y - thickness / 2, width: width, height: thickness))
    }

    // MARK: - Background

    /// Fills the ETO_OPAQUE rectangle with the DC background colour, if set, and
    /// nothing else. Used for the empty-string path (a run with no glyphs).
    private static func paintOpaqueRectIfNeeded(
        _ text: ExtTextPayload,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform
    ) {
        guard text.options.opaque else { return }
        let full = dc.resolvedTransform.concatenating(base)
        let rect = PathBuilder.cgRect(text.rectangle)
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)
        let path = CGMutablePath()
        path.addRect(rect, transform: full)
        context.addPath(path)
        context.setFillColor(cgColor(dc.state.bkColor))
        context.fillPath()
    }

    /// Paints the text background before the glyphs:
    /// - ETO_OPAQUE → fill the payload Rectangle with bkColor;
    /// - otherwise, bkMode OPAQUE → fill the run's typographic extent with
    ///   bkColor.
    /// Works in DEVICE space (via `base`), matching the glyph draw's frame.
    private static func paintBackground(
        _ text: ExtTextPayload,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        anchor: CGPoint,
        horizontalOffset: CGFloat,
        baselineDrop: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        lineWidth: CGFloat,
        escapementRadians: Double
    ) {
        if text.options.opaque {
            let rect = PathBuilder.cgRect(text.rectangle)
            guard rect.width > 0, rect.height > 0 else { return }
            context.saveGState()
            defer { context.restoreGState() }
            dc.state.clip.apply(to: context, deviceToTarget: base)
            let path = CGMutablePath()
            path.addRect(rect, transform: dc.resolvedTransform.concatenating(base))
            context.addPath(path)
            context.setFillColor(cgColor(dc.state.bkColor))
            context.fillPath()
            return
        }

        // bkMode OPAQUE: fill the run's typographic box (in the run's local,
        // y-up frame after the flip) behind the glyphs. The box spans the
        // baseline ± ascent/descent; `baselineDrop` places the baseline
        // relative to the anchor for the current vertical alignment.
        guard dc.state.bkMode == .opaque else { return }
        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)
        context.concatenate(base)
        context.translateBy(x: anchor.x, y: anchor.y)
        if escapementRadians != 0 {
            context.rotate(by: CGFloat(-escapementRadians))
        }
        context.scaleBy(x: 1, y: -1)
        let box = CGRect(
            x: horizontalOffset,
            y: baselineDrop - descent,
            width: lineWidth,
            height: ascent + descent
        )
        context.setFillColor(cgColor(dc.state.bkColor))
        context.fill(box)
    }

    private static func cgColor(_ color: ColorRef) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
