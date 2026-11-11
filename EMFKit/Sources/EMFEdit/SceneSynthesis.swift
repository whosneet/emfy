import CoreGraphics
import EMFParse
import EMFWrite
import Foundation

/// Turns an edited or new scene element into the records that draw it — the
/// shared core of the exporter (which writes them into the file) and the
/// renderer (which replays them so an edited element shows its new value).
///
/// The device-space mapping discipline (docs/v3-plan §11.1): a synthesised block
/// is self-contained. It saves the DC, puts it into a known DEVICE-space mapping
/// (logical units == device pixels — the space the scene stores geometry in),
/// creates its pen/brush/font in free handle slots, draws, deletes those
/// objects, and restores the DC. Surrounding records see no change, so an edit
/// never disturbs another element.
///
/// A synthesised shape re-uses the record that matches the element's KIND
/// (RECTANGLE, ELLIPSE, POLYGON/POLYPOLYGON, POLYLINE, POLYBEZIER), transformed
/// into device space, so a translated rect re-imports as a rect (E2 resize
/// handles rely on it). Kinds whose parameters the scene does not retain
/// (ROUNDRECT, ARC/PIE/CHORD) or geometry a record cannot hold (a rotated rect,
/// a curve in WMF) fall back to a path bracket / flattened polygon, with a
/// `kindFallback` warning.
enum SceneSynthesis {

    // MARK: - GDI PenStyle bits ([MS-EMF] §2.2.20, verified in RenderObjects)

    private enum Pen {
        static let geometric: UInt32 = 0x0001_0000
        static let solid: UInt32 = 0x0000
        static let dash: UInt32 = 0x0001
        static let dot: UInt32 = 0x0002
        static let dashDot: UInt32 = 0x0003
        static let dashDotDot: UInt32 = 0x0004
        static let userStyle: UInt32 = 0x0007
        static let endCapSquare: UInt32 = 0x0000_0100
        static let endCapFlat: UInt32 = 0x0000_0200
        static let joinBevel: UInt32 = 0x0000_1000
        static let joinMiter: UInt32 = 0x0000_2000
    }
    private enum Brush { static let solid: UInt32 = 0x0000 }   // BS_SOLID
    private static let srcCopy: UInt32 = 0x00CC_0020           // SRCCOPY ternary rop
    private static let anisotropic: UInt16 = 8                 // MM_ANISOTROPIC

    // MARK: - Alpha loss (GDI/WMF cannot hold sub-1 alpha)

    /// True when `element` carries alpha a GDI/WMF container cannot express: element
    /// opacity below 1, or a fill/stroke/text paint colour with alpha below 1 (GDI's
    /// `ColorRef` and WMF's colours are opaque). Both are flattened to the opaque
    /// colour with an `opacityDropped` warning. The EMF+ dual route discards this
    /// warning (it carries the alpha); the GDI-only and WMF routes surface it.
    static func droppedAlpha(_ element: Element) -> Bool {
        if element.style.opacity < 1 { return true }
        if let fill = element.style.fill, fill.color.alpha < 1 { return true }
        if let stroke = element.style.stroke, stroke.color.alpha < 1 { return true }
        if let text = element.text, (element.style.fill?.color ?? text.color).alpha < 1 { return true }
        return false
    }

    // MARK: - EMF element block

    /// The device-space EMR block that draws `element`, using object handles
    /// `baseHandle`…`baseHandle+2` (pen, brush, font) — all created and deleted
    /// within the block. Empty for an element that draws nothing.
    static func emfBlock(for element: Element, baseHandle: UInt32, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        switch element.kind {
        case .text:  return emfTextBlock(element, fontHandle: baseHandle, warnings: &warnings)
        case .image: return emfImageBlock(element, warnings: &warnings)
        case .passthrough, .group: return []
        default:     return emfGeometryBlock(element, penHandle: baseHandle, brushHandle: baseHandle + 1, warnings: &warnings)
        }
    }

    private static let identityXForm = XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 0, dy: 0)

    /// SAVEDC + reset to MM_TEXT / identity world / zero origins (logical==device).
    private static func emfReset() -> [EMFRecordPayload] {
        [
            .saveDC,
            .setMapMode(.text),
            .setWorldTransform(identityXForm),
            .setWindowOrgEx(origin: PointL(x: 0, y: 0)),
            .setViewportOrgEx(origin: PointL(x: 0, y: 0)),
        ]
    }

    private static func emfGeometryBlock(_ element: Element, penHandle: UInt32, brushHandle: UInt32, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        guard !element.geometryDevice.isEmpty else { return [] }
        let fill = element.style.fill
        let stroke = element.style.stroke

        // Build the shape first (into a scratch warnings list, so a no-paint shape
        // we end up dropping leaves no stray kindFallback warning).
        var shapeWarnings: [ExportWarning] = []
        let shape = emfShapeRecords(element, warnings: &shapeWarnings)
        // A shape with no paint still round-trips as an editable element when it
        // recovered to a direct-draw record (RECTANGLE/ELLIPSE/POLYGON/…): it draws
        // invisibly under NULL_PEN/NULL_BRUSH, exactly as the source did (an
        // invisible shape the importer still lifts). A no-paint PATH bracket has no
        // terminal fill/stroke to re-lift, so there is nothing to preserve.
        let directDraw: Bool
        if let first = shape.first, case .beginPath = first { directDraw = false }
        else { directDraw = !shape.isEmpty }
        if fill == nil, stroke == nil, !directDraw {
            // Would be dropped (a no-paint path bracket has no terminal to re-lift).
            // A ZERO-AREA invisible element, though, must still round-trip — dropping
            // it on edit silently loses the element (corpus-local idx 150). Re-emit it
            // as a degenerate RECTANGLE under NULL_PEN/NULL_BRUSH: it draws nothing
            // (harmless) but re-imports as an element. (slice E1b2d item 5)
            let bbox = element.geometryDevice.boundingBox
            if !bbox.isNull, bbox.width == 0 || bbox.height == 0 {
                return emfDegenerateRect(bbox)
            }
            return []
        }
        warnings.append(contentsOf: shapeWarnings)
        if droppedAlpha(element) { warnings.append(.opacityDropped(elementID: element.id)) }
        if let fill, fill.gradient != nil { warnings.append(.gradientFlattened(elementID: element.id)) }

        var out = emfReset()
        let scale = averageScale(element.transform)
        if let stroke { out.append(.extCreatePen(penPayload(stroke, handle: penHandle, scale: scale))) }
        if let fill { out.append(.createBrushIndirect(CreateBrushPayload(ihBrush: brushHandle, style: Brush.solid, color: fill.color.colorRef, hatch: 0))) }
        if let fill { out.append(.setPolyFillMode(fill.evenOdd ? .alternate : .winding)) }
        out.append(.selectObject(stroke != nil ? .table(index: penHandle) : .stock(.nullPen)))
        out.append(.selectObject(fill != nil ? .table(index: brushHandle) : .stock(.nullBrush)))

        out.append(contentsOf: shape)

        out.append(.selectObject(.stock(.blackPen)))
        out.append(.selectObject(.stock(.whiteBrush)))
        if stroke != nil { out.append(.deleteObject(.table(index: penHandle))) }
        if fill != nil { out.append(.deleteObject(.table(index: brushHandle))) }
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    /// A degenerate (zero-area) RECTANGLE under NULL_PEN/NULL_BRUSH — the round-trip
    /// carrier for a zero-area invisible element that would otherwise be dropped on
    /// edit (item 5). It draws nothing but re-imports as an (invisible) element, so
    /// an edit never silently loses the element.
    private static func emfDegenerateRect(_ box: CGRect) -> [EMFRecordPayload] {
        var out = emfReset()
        out.append(.selectObject(.stock(.nullPen)))
        out.append(.selectObject(.stock(.nullBrush)))
        out.append(.rectangle(box: rectL(box)))
        out.append(.selectObject(.stock(.blackPen)))
        out.append(.selectObject(.stock(.whiteBrush)))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    /// The draw record(s) that reproduce `element`'s geometry, matching its kind
    /// where possible, else a path bracket.
    private static func emfShapeRecords(_ element: Element, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        let path = element.geometryDevice
        let fillable = element.style.fill != nil
        switch element.kind {
        case .rect:
            if let box = axisAlignedRect(path) { return [.rectangle(box: rectL(box))] }
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        case .ellipse:
            if !hasRotation(element.transform), !path.boundingBox.isNull { return [.ellipse(box: rectL(path.boundingBox))] }
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        case .polygon:
            if let subs = lineSubpaths(path) {
                if subs.count == 1 { return [.polygon(PolyPointsPayload(bounds: rectL(path.boundingBox), points: subs[0].map(pointL)))] }
                if let poly = polyPoly16(subs) { return [.polyPolygon16(poly)] }
            }
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        case .polyline, .line:
            if let subs = lineSubpaths(path), subs.count == 1 {
                if fillable { return [.polygon(PolyPointsPayload(bounds: rectL(path.boundingBox), points: subs[0].map(pointL)))] }
                return [.polyline(PolyPointsPayload(bounds: rectL(path.boundingBox), points: subs[0].map(pointL)))]
            }
            return emfPathBracket(element, kindFallback: element.kind != .line, warnings: &warnings)
        case .bezier:
            if let pts = bezierControlPoints(path) {
                return [.polyBezier(PolyPointsPayload(bounds: rectL(path.boundingBox), points: pts.map(pointL)))]
            }
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        case .roundRect:
            // Re-emit EMR_ROUNDRECT when the geometry is an axis-aligned rounded
            // rectangle (the corner radius is recovered from the path, so both a
            // tool-made and a re-imported round rect round-trip as a round rect —
            // [MS-EMF] §2.3.5.35; the Corner SizeL is the rounding ELLIPSE size, i.e.
            // twice the radius). A rotated one falls back to a path bracket.
            if !hasRotation(element.transform), let rr = roundRectBoxAndRadius(path) {
                let diameter = SceneNumeric.int32(rr.radius * 2)
                return [.roundRect(RoundRectPayload(box: rectL(rr.box), corner: SizeL(cx: diameter, cy: diameter)))]
            }
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        case .path:
            return emfPathBracket(element, kindFallback: false, warnings: &warnings)
        default:
            // arc/pie/chord — parameters not retained by the scene.
            return emfPathBracket(element, kindFallback: true, warnings: &warnings)
        }
    }

    private static func emfPathBracket(_ element: Element, kindFallback: Bool, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        if kindFallback { warnings.append(.kindFallback(elementID: element.id, kind: element.kind)) }
        var out: [EMFRecordPayload] = [.beginPath]
        out.append(contentsOf: emfPathSegments(element.geometryDevice))
        out.append(.endPath)
        let bounds = rectL(element.geometryDevice.boundingBox)
        switch (element.style.fill != nil, element.style.stroke != nil) {
        case (true, true): out.append(.strokeAndFillPath(bounds: bounds))
        case (true, false): out.append(.fillPath(bounds: bounds))
        case (false, true): out.append(.strokePath(bounds: bounds))
        case (false, false): break
        }
        return out
    }

    private static func emfTextBlock(_ element: Element, fontHandle: UInt32, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        guard let text = element.text, !text.string.isEmpty else { return [] }
        if droppedAlpha(element) { warnings.append(.opacityDropped(elementID: element.id)) }
        let scale = averageScale(element.transform)
        let deviceHeight = SceneNumeric.int32(Double(text.logicalHeight) * scale)
        let reference = pointL(CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform))
        let color = (element.style.fill?.color ?? text.color).colorRef

        var out = emfReset()
        out.append(.setBkMode(.transparent))
        out.append(.setTextColor(color))
        out.append(.setTextAlign(TextAlign(rawValue: text.alignRawValue)))
        out.append(.extCreateFontIndirectW(ExtCreateFontPayload(ihFonts: fontHandle, logFont: logFont(for: text, deviceHeight: deviceHeight), hasExtendedData: false)))
        out.append(.selectObject(.table(index: fontHandle)))
        out.append(.extTextOutW(ExtTextPayload(graphicsMode: 1, exScale: 1, eyScale: 1, reference: reference,
            rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0), string: text.string,
            options: ExtTextOutOptions(rawValue: 0), dx: deviceAdvances(text, scale: scale))))
        out.append(.selectObject(.stock(.systemFont)))
        out.append(.deleteObject(.table(index: fontHandle)))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    /// A text block that PRESERVES the element's world transform instead of baking
    /// it into integer device coordinates. For a GetDC-window run under a fractional
    /// world transform, baking the reference to device and rounding it quantises the
    /// baseline (slice E1b2e item 1); re-establishing the transform (MM_TEXT so the
    /// map mode is 1:1, then SetWorldTransform) and drawing at the run's own LOGICAL
    /// reference and font height reproduces the exact device baseline, because GDI
    /// applies the transform exactly as the source window did — the SAME engine that
    /// drew the original, so alignment (TA_BASELINE/TA_TOP), the font, and the
    /// condensed advances all match. Emitted in place inside the GetDC window, so the
    /// one record serves both the EMF+ GetDC replay and the GDI fallback (one copy in
    /// each arbitration mode); GM_ADVANCED is inherited from the window the SAVEDC
    /// nests in, so a spec-correct reader honours the SetWorldTransform
    /// ([MS-EMF] §2.2.26, §2.3.5.34; §2.2.9 GM_ADVANCED required for world transforms).
    static func emfTextBlockWorld(for element: Element, fontHandle: UInt32, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        guard let text = element.text, !text.string.isEmpty else { return [] }
        if droppedAlpha(element) { warnings.append(.opacityDropped(elementID: element.id)) }
        let color = (element.style.fill?.color ?? text.color).colorRef
        var out: [EMFRecordPayload] = [
            .saveDC,
            .setMapMode(.text),
            .setWorldTransform(xform(element.transform)),
            .setWindowOrgEx(origin: PointL(x: 0, y: 0)),
            .setViewportOrgEx(origin: PointL(x: 0, y: 0)),
        ]
        out.append(.setBkMode(.transparent))
        out.append(.setTextColor(color))
        out.append(.setTextAlign(TextAlign(rawValue: text.alignRawValue)))
        // The font height stays the run's SIGNED LOGICAL height; the world transform
        // scales it to the device size, as the source window did.
        out.append(.extCreateFontIndirectW(ExtCreateFontPayload(ihFonts: fontHandle, logFont: logFont(for: text, deviceHeight: text.logicalHeight), hasExtendedData: false)))
        out.append(.selectObject(.table(index: fontHandle)))
        // GM_ADVANCED (2): the exScale/eyScale are ignored and the world transform
        // governs the reference and glyphs; the reference and Dx stay in LOGICAL units.
        out.append(.extTextOutW(ExtTextPayload(graphicsMode: 2, exScale: 1, eyScale: 1, reference: pointL(text.referenceLogical),
            rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0), string: text.string,
            options: ExtTextOutOptions(rawValue: 0), dx: logicalAdvances(text))))
        out.append(.selectObject(.stock(.systemFont)))
        out.append(.deleteObject(.table(index: fontHandle)))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    /// The run's intercharacter advances in LOGICAL units (the space
    /// `emfTextBlockWorld` draws in), or nil to use the font's natural advances when
    /// the captured array no longer matches the (possibly edited) string.
    private static func logicalAdvances(_ text: SceneText) -> [UInt32]? {
        let advances = text.advancesLogical
        guard !advances.isEmpty, advances.count == text.string.utf16.count else { return nil }
        return advances
    }

    /// `element.transform` as an EMR XForm ([MS-EMF] §2.2.28), saturating a
    /// non-finite edit to the identity so the parse/export path never traps (§8).
    private static func xform(_ t: CGAffineTransform) -> XForm {
        guard t.a.isFinite, t.b.isFinite, t.c.isFinite, t.d.isFinite, t.tx.isFinite, t.ty.isFinite else { return identityXForm }
        return XForm(m11: Float(t.a), m12: Float(t.b), m21: Float(t.c), m22: Float(t.d), dx: Float(t.tx), dy: Float(t.ty))
    }

    private static func emfImageBlock(_ element: Element, warnings: inout [ExportWarning]) -> [EMFRecordPayload] {
        // A GDI image carries its source DIB; an EMF+ image (dual-file GDI fallback)
        // carries none, so its pixels are decoded to a BI_RGB DIB for STRETCHDIBITS.
        guard let image = element.image,
              let dib = image.sourceDIB ?? SceneImageCoding.dib(for: image), !isUnsupported(dib) else {
            warnings.append(.imageDropped(elementID: element.id)); return []
        }
        // GDI has no image alpha (STRETCHDIBITS draws opaque), so a sub-1 element
        // opacity on an image is dropped with a report (not expressible in EMF+ here
        // either — slice E1b2b keeps the image a GDI draw).
        if element.style.opacity < 1 { warnings.append(.opacityDropped(elementID: element.id)) }
        // GDI STRETCHDIBITS fills an axis-aligned rect only; a rotated/sheared
        // parallelogram is dropped to its bounding box, with a warning.
        if image.destCornersDevice != nil { warnings.append(.imageRotated(elementID: element.id)) }
        return emfImageRecords(dib: dib, destDevice: image.destRectDevice)
    }

    /// A self-contained device-space EMR_STRETCHDIBITS block drawing `dib` into
    /// `destDevice` (SRCCOPY, [MS-EMF] §2.3.1.7). Shared by `emfImageBlock` and the
    /// cross-format rasteriser (`SceneRasterize`), which hands a bitmap of one
    /// element it could not re-synthesise.
    static func emfImageRecords(dib: DIB, destDevice: CGRect) -> [EMFRecordPayload] {
        let dest = destDevice.standardized
        var out = emfReset()
        out.append(.stretchDIBits(StretchDIBitsPayload(bounds: rectL(dest), dest: pointL(dest.origin),
            destSize: SizeL(cx: SceneNumeric.int32(dest.width), cy: SceneNumeric.int32(dest.height)),
            src: PointL(x: 0, y: 0), srcSize: SizeL(cx: dib.width, cy: abs(dib.height)),
            usageSrc: 0, rasterOperation: srcCopy, dib: dib)))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    /// Figure records that reproduce `path` inside a path bracket.
    private static func emfPathSegments(_ path: ScenePath) -> [EMFRecordPayload] {
        var out: [EMFRecordPayload] = []
        var current = CGPoint.zero
        let zeroBounds = RectL(left: 0, top: 0, right: 0, bottom: 0)
        for segment in path.segments {
            switch segment {
            case .move(let p): out.append(.moveToEx(point: pointL(p))); current = p
            case .line(let p): out.append(.lineTo(point: pointL(p))); current = p
            case .cubicCurve(let to, let c1, let c2):
                out.append(.polyBezierTo(PolyPointsPayload(bounds: zeroBounds, points: [pointL(c1), pointL(c2), pointL(to)]))); current = to
            case .quadCurve(let to, let c):
                let c1 = CGPoint(x: current.x + 2.0 / 3.0 * (c.x - current.x), y: current.y + 2.0 / 3.0 * (c.y - current.y))
                let c2 = CGPoint(x: to.x + 2.0 / 3.0 * (c.x - to.x), y: to.y + 2.0 / 3.0 * (c.y - to.y))
                out.append(.polyBezierTo(PolyPointsPayload(bounds: zeroBounds, points: [pointL(c1), pointL(c2), pointL(to)]))); current = to
            case .close: out.append(.closeFigure)
            }
        }
        return out
    }

    // MARK: - WMF element block (logical-space overlay block)

    /// The WMF block that draws `element`, using object slots `penSlot`/
    /// `brushSlot`/`fontSlot` (already allocated by the caller's slot model). WMF
    /// has no curve/path record, so curves flatten to a polygon (filled) or
    /// polyline (stroked).
    ///
    /// `element` here is already mapped into the WMF's LOGICAL space with an
    /// identity transform (the caller does this via `canvasToLogical`), so the
    /// geometry/reference/width logic below produces logical records; the block
    /// resets the DC to the page's base window (`winOrg`/`winExt`) but never the
    /// viewport, so the reader's own output frame maps the logical coords to full
    /// scale (see `wmfReset`).
    static func wmfBlock(for element: Element, winOrg: PointL, winExt: SizeL, penSlot: UInt16, brushSlot: UInt16, fontSlot: UInt16, emitDx: Bool = false, clip: RectL? = nil, warnings: inout [ExportWarning]) -> [WMFRecord] {
        var records: [WMFRecord]
        switch element.kind {
        case .text:  records = wmfTextBlock(element, winOrg: winOrg, winExt: winExt, fontSlot: fontSlot, emitDx: emitDx, warnings: &warnings)
        case .image: records = wmfImageBlock(element, winOrg: winOrg, winExt: winExt, warnings: &warnings)
        case .passthrough, .group: return []
        default:     records = wmfGeometryBlock(element, winOrg: winOrg, winExt: winExt, penSlot: penSlot, brushSlot: brushSlot, warnings: &warnings)
        }
        // Cross-format synthesis has no ambient clip state (unlike the verbatim
        // overlay, where the source's own clip records surround the element), so a
        // shape clipped in the source must be clipped here too — else its full,
        // unclipped geometry draws (e.g. a page-wide band clipped to a small rect
        // paints the whole band). Insert the clip INSIDE the block's window mapping,
        // right after the wmfReset's SetWindowExt (index 3), so it is scoped by the
        // block's own SAVEDC/RESTOREDC and uses the same logical coordinates.
        if let clip, records.count >= 4, case .setWindowExt = records[3] {
            records.insert(.intersectClipRect(clip), at: 4)
        }
        return records
    }

    /// How many object slots a WMF block for `element` allocates (so the caller's
    /// slot model reserves the right count): pen for a stroke, brush for a fill,
    /// font for text.
    static func wmfSlotNeeds(for element: Element) -> (pen: Bool, brush: Bool, font: Bool) {
        switch element.kind {
        case .text: return (false, false, element.text != nil)
        case .image, .passthrough, .group: return (false, false, false)
        default: return (element.style.stroke != nil, element.style.fill != nil, false)
        }
    }

    /// Restores the page's base window mapping for the block, which draws in the
    /// WMF's own LOGICAL space (`winOrg`/`winExt` are the preamble's window). The
    /// VIEWPORT is deliberately NOT set: it stays the reader's output frame (the
    /// placeable device extent for a standalone reader, the canvas for Emfy), so a
    /// logical coord `L` maps to `(L − winOrg) × (frame / winExt)` — full scale in
    /// every reader, exactly as the surrounding verbatim logical records draw.
    /// Setting the window/viewport to the device canvas (an earlier cut) coincided
    /// with Emfy's own canvas but shrank the block to `winExt/canvas` (~1/26) of a
    /// spec-correct reader's device frame ([MS-WMF] §2.3.5.26/.30, §3.1.4.2).
    private static func wmfReset(winOrg: PointL, winExt: SizeL) -> [WMFRecord] {
        [
            .saveDC,
            .setMapMode(anisotropic),
            .setWindowOrg(winOrg),
            .setWindowExt(winExt),
        ]
    }

    private static func wmfGeometryBlock(_ element: Element, winOrg: PointL, winExt: SizeL, penSlot: UInt16, brushSlot: UInt16, warnings: inout [ExportWarning]) -> [WMFRecord] {
        guard !element.geometryDevice.isEmpty else { return [] }
        let fill = element.style.fill
        let stroke = element.style.stroke
        guard fill != nil || stroke != nil else { return [] }
        if droppedAlpha(element) { warnings.append(.opacityDropped(elementID: element.id)) }
        if let fill, fill.gradient != nil { warnings.append(.gradientFlattened(elementID: element.id)) }

        var out = wmfReset(winOrg: winOrg, winExt: winExt)
        // The element is already in logical space with an identity transform, so
        // `scale` is 1 and the pen width stays the logical pen width.
        let scale = averageScale(element.transform)
        // Create only the objects the element uses (slots the caller reserved);
        // select a STOCK null object for the absent half.
        if let stroke {
            out.append(.createPenIndirect(style: UInt16(truncatingIfNeeded: dashStyleBits(stroke.dash)), width: stroke.isCosmetic ? 0 : SceneNumeric.int32(stroke.width * scale), color: stroke.color.colorRef))
            out.append(.selectObject(index: penSlot))
        } else {
            out.append(.selectObject(index: 0x8008))   // stock NULL_PEN
        }
        if let fill {
            out.append(.createBrushIndirect(style: 0x0000, color: fill.color.colorRef, hatch: 0))   // BS_SOLID
            out.append(.selectObject(index: brushSlot))
            out.append(.setPolyFillMode(fill.evenOdd ? 1 : 2))
        } else {
            out.append(.selectObject(index: 0x8005))   // stock NULL_BRUSH
        }

        out.append(contentsOf: wmfShapeRecords(element, warnings: &warnings))

        out.append(.selectObject(index: 0x8000))   // stock WHITE_BRUSH
        out.append(.selectObject(index: 0x8007))   // stock BLACK_PEN
        if fill != nil { out.append(.deleteObject(index: brushSlot)) }
        if stroke != nil { out.append(.deleteObject(index: penSlot)) }
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    private static func wmfShapeRecords(_ element: Element, warnings: inout [ExportWarning]) -> [WMFRecord] {
        let path = element.geometryDevice
        let fillable = element.style.fill != nil
        switch element.kind {
        case .rect:
            if let box = axisAlignedRect(path) { return [.rectangle(rectL(box))] }
        case .ellipse:
            if !hasRotation(element.transform), !path.boundingBox.isNull { return [.ellipse(rectL(path.boundingBox))] }
        case .polygon:
            if let subs = lineSubpaths(path) {
                if subs.count == 1 { return [.polygon(subs[0].map(pointL32))] }
                return [.polyPolygon(subs.map { $0.map(pointL32) })]
            }
        case .polyline, .line:
            if let subs = lineSubpaths(path), subs.count == 1 {
                return fillable ? [.polygon(subs[0].map(pointL32))] : [.polyline(subs[0].map(pointL32))]
            }
        default: break
        }
        // Flatten curves / unrepresentable kinds.
        if element.kind != .path && element.kind != .rect && element.kind != .ellipse && element.kind != .polygon && element.kind != .polyline && element.kind != .line {
            warnings.append(.kindFallback(elementID: element.id, kind: element.kind))
        } else if element.kind != .path {
            warnings.append(.kindFallback(elementID: element.id, kind: element.kind))
        }
        let subs = flatten(path)
        if fillable {
            let polys = subs.map { $0.points.map(pointL32) }
            return polys.count == 1 ? [.polygon(polys[0])] : [.polyPolygon(polys)]
        }
        return subs.map { sub in
            var pts = sub.points
            if sub.closed, let first = pts.first { pts.append(first) }
            return WMFRecord.polyline(pts.map(pointL32))
        }
    }

    private static func wmfTextBlock(_ element: Element, winOrg: PointL, winExt: SizeL, fontSlot: UInt16, emitDx: Bool, warnings: inout [ExportWarning]) -> [WMFRecord] {
        guard let text = element.text, !text.string.isEmpty else { return [] }
        if droppedAlpha(element) { warnings.append(.opacityDropped(elementID: element.id)) }
        if text.string.unicodeScalars.contains(where: { $0.value > 0xFF }) { warnings.append(.textNotLatin1(elementID: element.id)) }
        // WMF carries only a LOGFONT escapement angle, not a general text matrix, so a
        // run under a rotating/shearing world transform drops the rotation (the lift
        // of a WMF-source run maps to an identity transform, so this never fires there).
        if hasRotation(element.transform) { warnings.append(.textRotationDropped(elementID: element.id)) }
        let scale = averageScale(element.transform)
        let deviceHeight = SceneNumeric.int32(Double(text.logicalHeight) * scale)
        let reference = pointL32(CGPoint(x: text.referenceLogical.x, y: text.referenceLogical.y).applying(element.transform))
        let color = (element.style.fill?.color ?? text.color).colorRef
        var out = wmfReset(winOrg: winOrg, winExt: winExt)
        out.append(.setBkMode(1))
        out.append(.setTextColor(color))
        out.append(.setTextAlign(UInt16(truncatingIfNeeded: text.alignRawValue)))
        out.append(.createFontIndirect(logFont(for: text, deviceHeight: deviceHeight)))
        out.append(.selectObject(index: fontSlot))
        out.append(.extTextOut(point: reference, rectangle: nil, options: 0, string: text.string,
                               dx: emitDx ? wmfAdvances(text, scale: scale) : nil))
        out.append(.selectObject(index: 0x800D))   // stock SYSTEM_FONT
        out.append(.deleteObject(index: fontSlot))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    private static func wmfImageBlock(_ element: Element, winOrg: PointL, winExt: SizeL, warnings: inout [ExportWarning]) -> [WMFRecord] {
        // A GDI image carries its source DIB; an EMF+ image (cross-container EMF+→WMF)
        // carries none, so its pixels are decoded to a BI_RGB DIB for META_STRETCHDIB.
        guard let image = element.image,
              let dib = image.sourceDIB ?? SceneImageCoding.dib(for: image), !isUnsupported(dib) else {
            warnings.append(.imageDropped(elementID: element.id)); return []
        }
        if element.style.opacity < 1 { warnings.append(.opacityDropped(elementID: element.id)) }
        if image.destCornersDevice != nil { warnings.append(.imageRotated(elementID: element.id)) }
        return wmfImageRecords(dib: dib, destLogical: image.destRectDevice, winOrg: winOrg, winExt: winExt)
    }

    /// A self-contained logical-space META_STRETCHDIB block drawing `dib` into
    /// `destLogical` (SRCCOPY, [MS-WMF] §2.3.1.6). Shared by `wmfImageBlock` and the
    /// cross-format rasteriser; `destLogical` is already in the WMF's logical space.
    static func wmfImageRecords(dib: DIB, destLogical: CGRect, winOrg: PointL, winExt: SizeL) -> [WMFRecord] {
        let dest = destLogical.standardized
        var out = wmfReset(winOrg: winOrg, winExt: winExt)
        out.append(.stretchDIB(rop: srcCopy, colorUsage: 0, src: PointL(x: 0, y: 0),
            srcSize: SizeL(cx: dib.width, cy: abs(dib.height)), dest: pointL32(dest.origin),
            destSize: SizeL(cx: SceneNumeric.int32(dest.width), cy: SceneNumeric.int32(dest.height)), dib: dib))
        out.append(.restoreDC(savedDC: -1))
        return out
    }

    // MARK: - Shape recovery helpers

    /// The bounding rect if `path` is an axis-aligned rectangle outline (every
    /// vertex sits on a corner of the bounding box), else nil. Shared with the
    /// EMF+ synthesis (`SceneEMFPlusSynthesis`) so both re-emit the same kinds.
    static func axisAlignedRect(_ path: ScenePath) -> CGRect? {
        var pts: [CGPoint] = []
        for seg in path.segments {
            switch seg {
            case .move(let p), .line(let p): pts.append(p)
            case .close: continue
            case .quadCurve, .cubicCurve: return nil
            }
        }
        guard pts.count >= 4 else { return nil }
        let box = path.boundingBox
        guard box.width > 0, box.height > 0 else { return nil }
        let tol: CGFloat = 0.01
        for p in pts {
            let onX = abs(p.x - box.minX) <= tol || abs(p.x - box.maxX) <= tol
            let onY = abs(p.y - box.minY) <= tol || abs(p.y - box.maxY) <= tol
            if !(onX && onY) { return nil }
        }
        return box
    }

    /// The bounding box and corner radius of `path` when it is an axis-aligned rounded
    /// rectangle (a `CGPath.addRoundedRect`, which `SceneFactory.makeShape` and
    /// EMFRender's EMR_ROUNDRECT lift both produce), else nil. The radius is recovered
    /// from the segment anchor points: each straight edge is inset from the box by the
    /// radius, so a top-edge anchor's x gives the x radius and a left-edge anchor's y the
    /// y radius; the insets must be symmetric on all four sides. Shared so a tool-made
    /// and a re-imported round rect both re-emit EMR_ROUNDRECT (no `kindFallback`).
    static func roundRectBoxAndRadius(_ path: ScenePath) -> (box: CGRect, radius: CGFloat)? {
        let box = path.boundingBox
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        var anchors: [CGPoint] = []
        var hasCurve = false
        for seg in path.segments {
            switch seg {
            case .move(let p), .line(let p): anchors.append(p)
            case .quadCurve(let to, _), .cubicCurve(let to, _, _): anchors.append(to); hasCurve = true
            case .close: continue
            }
        }
        // A rounded rect has four corner arcs (curves) and eight edge anchors.
        guard hasCurve, anchors.count >= 8 else { return nil }
        let tol = max(box.width, box.height) * 1e-3 + 0.5
        let topXs = anchors.filter { abs($0.y - box.minY) <= tol }.map(\.x)
        let leftYs = anchors.filter { abs($0.x - box.minX) <= tol }.map(\.y)
        guard let minTopX = topXs.min(), let maxTopX = topXs.max(),
              let minLeftY = leftYs.min(), let maxLeftY = leftYs.max() else { return nil }
        let rx = minTopX - box.minX
        let ry = minLeftY - box.minY
        guard rx > 0.5, ry > 0.5,
              abs((box.maxX - maxTopX) - rx) <= tol,       // symmetric left/right inset
              abs((box.maxY - maxLeftY) - ry) <= tol       // symmetric top/bottom inset
        else { return nil }
        return (box, (rx + ry) / 2)
    }

    /// Subpaths of points if every segment is a move/line/close (no curves), else nil.
    static func lineSubpaths(_ path: ScenePath) -> [[CGPoint]]? {
        var subs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for seg in path.segments {
            switch seg {
            case .move(let p):
                if current.count >= 2 { subs.append(current) }
                current = [p]
            case .line(let p): current.append(p)
            case .close: continue
            case .quadCurve, .cubicCurve: return nil
            }
        }
        if current.count >= 2 { subs.append(current) }
        return subs.isEmpty ? nil : subs
    }

    /// A single-subpath cubic-bezier control sequence [start, c1,c2,e, …], or nil.
    static func bezierControlPoints(_ path: ScenePath) -> [CGPoint]? {
        var pts: [CGPoint] = []
        var started = false
        var current = CGPoint.zero
        for seg in path.segments {
            switch seg {
            case .move(let p):
                if started { return nil }   // more than one subpath
                pts = [p]; current = p; started = true
            case .cubicCurve(let to, let c1, let c2):
                pts.append(c1); pts.append(c2); pts.append(to); current = to
            case .quadCurve(let to, let c):
                let c1 = CGPoint(x: current.x + 2.0/3.0*(c.x-current.x), y: current.y + 2.0/3.0*(c.y-current.y))
                let c2 = CGPoint(x: to.x + 2.0/3.0*(c.x-to.x), y: to.y + 2.0/3.0*(c.y-to.y))
                pts.append(c1); pts.append(c2); pts.append(to); current = to
            case .line, .close: return nil
            }
        }
        return (started && pts.count >= 4) ? pts : nil
    }

    private static func polyPoly16(_ subs: [[CGPoint]]) -> PolyPoly16Payload? {
        var pointCounts: [UInt32] = []
        var points: [PointS] = []
        for sub in subs {
            guard sub.count <= Int(UInt32.max) else { return nil }
            for p in sub {
                guard p.x.isFinite, p.y.isFinite,
                      p.x >= CGFloat(Int16.min), p.x <= CGFloat(Int16.max),
                      p.y >= CGFloat(Int16.min), p.y <= CGFloat(Int16.max) else { return nil }
                points.append(PointS(x: Int16(p.x.rounded()), y: Int16(p.y.rounded())))
            }
            pointCounts.append(UInt32(sub.count))
        }
        return PolyPoly16Payload(bounds: RectL(left: 0, top: 0, right: 0, bottom: 0), pointCounts: pointCounts, points: points)
    }

    // MARK: - Object builders

    private static func penPayload(_ stroke: SceneStroke, handle: UInt32, scale: Double) -> ExtCreatePenPayload {
        let geometric = stroke.isCosmetic ? 0 : Pen.geometric
        let width = stroke.isCosmetic ? 0 : SceneNumeric.uint32(stroke.width * scale)
        let style = geometric | dashStyleBits(stroke.dash) | capBits(stroke.cap) | joinBits(stroke.join)
        let entries: [UInt32] = { if case .userStyle(let e) = stroke.dash { return e } else { return [] } }()
        return ExtCreatePenPayload(ihPen: handle, offBmi: 0, cbBmi: 0, offBits: 0, cbBits: 0,
            style: style, width: width, brushStyle: Brush.solid, color: stroke.color.colorRef, brushHatch: 0, styleEntries: entries)
    }

    private static func dashStyleBits(_ dash: SceneStroke.Dash) -> UInt32 {
        switch dash {
        case .solid: return Pen.solid
        case .dash: return Pen.dash
        case .dot: return Pen.dot
        case .dashDot: return Pen.dashDot
        case .dashDotDot: return Pen.dashDotDot
        case .userStyle: return Pen.userStyle
        }
    }
    private static func capBits(_ cap: CGLineCap) -> UInt32 {
        switch cap { case .butt: return Pen.endCapFlat; case .square: return Pen.endCapSquare; default: return 0 }
    }
    private static func joinBits(_ join: CGLineJoin) -> UInt32 {
        switch join { case .miter: return Pen.joinMiter; case .bevel: return Pen.joinBevel; default: return 0 }
    }

    /// The EmrText intercharacter advances in DEVICE units for the re-emitted run,
    /// or nil to use the font's natural advances. The block draws in device space
    /// (identity transform after `emfReset`), so each logical advance is scaled by
    /// the element's world→device scale — the same `scale` the font em uses. Kept
    /// only when the captured array still matches the (possibly edited) string, so a
    /// replaced string falls back to natural advances rather than mis-spacing
    /// ([MS-EMF] §2.2.5).
    private static func deviceAdvances(_ text: SceneText, scale: Double) -> [UInt32]? {
        let advances = text.advancesLogical
        guard !advances.isEmpty, advances.count == text.string.utf16.count else { return nil }
        return advances.map { SceneNumeric.uint32(Double($0) * scale) }
    }

    /// The META_EXTTEXTOUT Dx advance array ([MS-WMF] §2.3.3.5) in WMF-LOGICAL units
    /// for the re-emitted run, or nil to use the font's natural advances. The WMF
    /// String is 8-bit, one byte per character; the lift's advances are one per
    /// UTF-16 code unit. For a Latin-1 run every scalar is one byte AND one code
    /// unit, so the counts coincide and each advance maps 1:1 to its character; a
    /// run that is not all Latin-1 (it would be rasterised instead) or whose array
    /// no longer matches the (possibly edited) string returns nil. `scale` is the
    /// element's world→logical scale, the same factor the font height uses, so a
    /// source-logical advance becomes a WMF-logical one. Clamped to Int16.
    private static func wmfAdvances(_ text: SceneText, scale: Double) -> [Int16]? {
        let advances = text.advancesLogical
        guard !advances.isEmpty, advances.count == text.string.utf16.count,
              !text.string.unicodeScalars.contains(where: { $0.value > 0xFF }) else { return nil }
        return advances.map { SceneNumeric.int16(Double($0) * scale) }
    }

    /// `deviceHeight` is the SIGNED LOGFONT height ([MS-EMF] §2.2.13): negative =
    /// |height| is the em (character) height, positive = the cell height, 0 =
    /// default. The lift carries the source sign, so re-emitting it (rather than
    /// forcing em with `-abs`) reproduces a cell-height run at its true glyph size.
    private static func logFont(for text: SceneText, deviceHeight: Int32) -> LogFont {
        LogFont(height: deviceHeight, width: 0, escapement: text.escapementTenths, orientation: text.escapementTenths,
            weight: text.bold ? 700 : 400, italic: text.italic ? 1 : 0, underline: text.underline ? 1 : 0, strikeOut: text.strikeOut ? 1 : 0,
            charSet: 1, outPrecision: 0, clipPrecision: 0, quality: 0, pitchAndFamily: 0,
            faceName: text.requestedFamily.isEmpty ? text.fontFamily : text.requestedFamily)
    }

    private static func isUnsupported(_ dib: DIB) -> Bool {
        if case .unsupported = dib.content { return true }
        return false
    }

    // MARK: - Geometry helpers

    static func flatten(_ path: ScenePath, samples: Int = 48) -> [(points: [CGPoint], closed: Bool)] {
        var subpaths: [(points: [CGPoint], closed: Bool)] = []
        var current: [CGPoint] = []
        var cursor = CGPoint.zero
        func flush(closed: Bool) { if current.count >= 2 { subpaths.append((current, closed)) }; current = [] }
        for segment in path.segments {
            switch segment {
            case .move(let p): flush(closed: false); current = [p]; cursor = p
            case .line(let p): current.append(p); cursor = p
            case .cubicCurve(let to, let c1, let c2):
                for i in 1 ... samples { current.append(cubicPoint(cursor, c1, c2, to, CGFloat(i)/CGFloat(samples))) }; cursor = to
            case .quadCurve(let to, let c):
                for i in 1 ... samples { current.append(quadPoint(cursor, c, to, CGFloat(i)/CGFloat(samples))) }; cursor = to
            case .close: flush(closed: true)
            }
        }
        flush(closed: false)
        return subpaths
    }
    private static func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t, a = u*u*u, b = 3*u*u*t, c = 3*u*t*t, d = t*t*t
        return CGPoint(x: a*p0.x+b*p1.x+c*p2.x+d*p3.x, y: a*p0.y+b*p1.y+c*p2.y+d*p3.y)
    }
    private static func quadPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t, a = u*u, b = 2*u*t, c = t*t
        return CGPoint(x: a*p0.x+b*p1.x+c*p2.x, y: a*p0.y+b*p1.y+c*p2.y)
    }

    /// Whether `t` rotates or shears (an ellipse's box can only be re-emitted as
    /// an axis-aligned EMR_ELLIPSE when it does not).
    static func hasRotation(_ t: CGAffineTransform) -> Bool {
        let scale = max(averageScale(t), 1e-9)
        return abs(t.b) > 1e-6 * scale || abs(t.c) > 1e-6 * scale
    }

    static func averageScale(_ t: CGAffineTransform) -> Double {
        let sx = (t.a*t.a + t.b*t.b).squareRoot(), sy = (t.c*t.c + t.d*t.d).squareRoot()
        let s = (sx + sy) / 2
        return s > 0 ? s : 1
    }

    private static func pointL(_ p: CGPoint) -> PointL { PointL(x: clampedInt32(p.x), y: clampedInt32(p.y)) }
    private static func pointL32(_ p: CGPoint) -> PointL { PointL(x: clampedInt32(p.x), y: clampedInt32(p.y)) }
    private static func rectL(_ r: CGRect) -> RectL {
        let s = r.standardized
        return RectL(left: clampedInt32(s.minX), top: clampedInt32(s.minY), right: clampedInt32(s.maxX), bottom: clampedInt32(s.maxY))
    }
    private static func clampedInt32(_ v: CGFloat) -> Int32 { SceneNumeric.int32(v) }
}
