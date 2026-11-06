import CoreGraphics
import EMFParse
import EMFWrite
import Foundation

/// Turns an edited or new scene element into the EMF+ records that draw it — the
/// EMF+ twin of `SceneSynthesis` (which emits GDI records). Shared by the exporter
/// (which packs the records into EMR_COMMENT_EMFPLUS carriers) and the renderer
/// (which plays a throwaway one-element EMF+ file so an edit shows its new value).
///
/// The block is self-contained (slice E1b2a, [MS-EMFPLUS] §2.3.7 Save/Restore): it
/// saves graphics state, resets the world transform to identity and the page
/// transform to 1:1 device pixels (the space the scene stores geometry in, so an
/// EMF+ record coordinate equals a device pixel), defines the objects it needs,
/// draws with the record matching the element's kind, then restores. The EMF+
/// object table has 64 slots and no save/restore of its own, so the EXPORTER
/// re-emits each reused slot's prior definition after the block (slot restore) —
/// that is the caller's job; this file only ALLOCATES slots through the closure it
/// is handed and reports which ids it used.
enum SceneEMFPlusSynthesis {

    /// `EmfPlusGraphicsVersion` written into every synthesised object
    /// ([MS-EMFPLUS] §2.2.2.19 GDI+ 1.1).
    static let graphicsVersion = SceneImageCoding.graphicsVersion

    /// One element of a synthesised block, before framing: either an object the
    /// caller writes as EmfPlusObject record(s), or a lowered drawing/state record.
    enum Emit {
        case object(id: UInt8, type: EMFPlusObjectType, value: EMFPlusObjectValue)
        case record(EMFPlusRecordPayload)
    }

    /// The EMF+ block that draws `element`. `allocate` hands back the next object
    /// slot to use (nil when the table is exhausted). Returns nil when the element
    /// draws nothing. The block is `Save … Restore` with an identity world and a
    /// 1:1-pixel page transform; the device-space geometry is emitted directly.
    static func block(
        for element: Element,
        saveIndex: UInt32,
        allocate: () -> UInt8?,
        warnings: inout [ExportWarning]
    ) -> [Emit]? {
        let inner: [Emit]?
        switch element.kind {
        case .text: inner = textEmits(element, allocate: allocate, warnings: &warnings)
        case .image: inner = imageEmits(element, allocate: allocate, warnings: &warnings)
        case .passthrough, .group: return nil
        default: inner = geometryEmits(element, allocate: allocate, warnings: &warnings)
        }
        guard let inner, !inner.isEmpty else { return nil }
        var out: [Emit] = [
            .record(.save(stackIndex: saveIndex)),
            .record(.resetWorldTransform),
            .record(.setPageTransform(scale: 1, pageUnit: unitPixel)),
        ]
        out.append(contentsOf: inner)
        out.append(.record(.restore(stackIndex: saveIndex)))
        return out
    }

    // MARK: - Units ([MS-EMFPLUS] §2.1.1.33 UnitType)

    private static let unitWorld: UInt32 = 0x00
    private static let unitPixel: UInt8 = 0x02

    // MARK: - Geometry

    private static func geometryEmits(_ element: Element, allocate: () -> UInt8?, warnings: inout [ExportWarning]) -> [Emit]? {
        guard !element.geometryDevice.isEmpty else { return nil }
        let opacity = element.style.opacity
        let fill = element.style.fill
        let stroke = element.style.stroke
        guard fill != nil || stroke != nil else { return nil }
        if let gradient = fill?.gradient, gradient.stops.count < 2 {
            warnings.append(.gradientFlattened(elementID: element.id))
        }

        var objects: [Emit] = []
        var brush: EMFPlusBrushSource?
        if let fill {
            if let gradient = fill.gradient, gradient.stops.count >= 2 {
                guard let id = allocate() else { return nil }
                objects.append(.object(id: id, type: .brush, value: gradientBrush(gradient, opacity: opacity)))
                brush = .object(id)
            } else {
                brush = .color(argb(fill.color, opacity: opacity))
            }
        }
        var penID: UInt8?
        if let stroke {
            guard let id = allocate() else { return nil }
            objects.append(.object(id: id, type: .pen, value: plusPen(stroke, element: element, opacity: opacity)))
            penID = id
        }

        guard let draw = shapeEmits(element, brush: brush, penID: penID, allocate: allocate, warnings: &warnings) else {
            return nil
        }
        return objects + draw
    }

    /// The draw record(s) reproducing `element`'s geometry, matching its kind where
    /// the geometry recovers cleanly (so a translated rect re-imports a rect), else
    /// a path object (FillPath/DrawPath) with a `kindFallback` warning.
    private static func shapeEmits(_ element: Element, brush: EMFPlusBrushSource?, penID: UInt8?, allocate: () -> UInt8?, warnings: inout [ExportWarning]) -> [Emit]? {
        let path = element.geometryDevice
        let fillable = brush != nil
        switch element.kind {
        case .rect:
            if let box = SceneSynthesis.axisAlignedRect(path) {
                return fillStrokeRecords(brush: brush, penID: penID,
                    fill: { .fillRects(brush: $0, rects: [rectF(box)]) },
                    stroke: { .drawRects(penID: $0, rects: [rectF(box)]) })
            }
        case .ellipse:
            if !SceneSynthesis.hasRotation(element.transform), !path.boundingBox.isNull {
                let r = rectF(path.boundingBox)
                return fillStrokeRecords(brush: brush, penID: penID,
                    fill: { .fillEllipse(brush: $0, rect: r) },
                    stroke: { .drawEllipse(penID: $0, rect: r) })
            }
        case .polygon:
            if let subs = SceneSynthesis.lineSubpaths(path), subs.count == 1 {
                let pts = subs[0].map(pointF)
                return fillStrokeRecords(brush: brush, penID: penID,
                    fill: { .fillPolygon(brush: $0, points: pts) },
                    stroke: { .drawLines(penID: $0, points: pts, closed: true) })
            }
        case .polyline, .line:
            if let subs = SceneSynthesis.lineSubpaths(path), subs.count == 1 {
                let pts = subs[0].map(pointF)
                return fillStrokeRecords(brush: brush, penID: penID,
                    fill: { .fillPolygon(brush: $0, points: pts) },
                    stroke: { .drawLines(penID: $0, points: pts, closed: fillable) })
            }
        case .bezier:
            if brush == nil, let pts = SceneSynthesis.bezierControlPoints(path) {
                guard let penID else { return nil }
                return [.record(.drawBeziers(penID: penID, points: pts.map(pointF)))]
            }
        default:
            break
        }
        // Fallback: a path object + FillPath/DrawPath.
        if element.kind != .path {
            warnings.append(.kindFallback(elementID: element.id, kind: element.kind))
        }
        guard let pathID = allocate() else { return nil }
        var out: [Emit] = [.object(id: pathID, type: .path, value: plusPath(path))]
        if let brush { out.append(.record(.fillPath(pathID: pathID, brush: brush))) }
        if let penID { out.append(.record(.drawPath(pathID: pathID, penID: UInt32(penID)))) }
        return out
    }

    /// Emits a fill record (if a brush is present) then a stroke record (if a pen
    /// is present). At least one is present (the caller guarantees it).
    private static func fillStrokeRecords(
        brush: EMFPlusBrushSource?, penID: UInt8?,
        fill: (EMFPlusBrushSource) -> EMFPlusRecordPayload,
        stroke: (UInt8) -> EMFPlusRecordPayload
    ) -> [Emit] {
        var out: [Emit] = []
        if let brush { out.append(.record(fill(brush))) }
        if let penID { out.append(.record(stroke(penID))) }
        return out
    }

    // MARK: - Text

    private static func textEmits(_ element: Element, allocate: () -> UInt8?, warnings: inout [ExportWarning]) -> [Emit]? {
        guard let text = element.text, !text.string.isEmpty else { return nil }
        guard let fontID = allocate() else { return nil }
        let color = element.style.fill?.color ?? text.color
        // The block draws text through the element's logical→device `transform`
        // (SetWorldTransform) on the 1:1-pixel page, so translate, scale AND
        // rotation in an edit all survive. `referenceLogical` is the reference point
        // in the run's PRE-transform (logical/world) space; the world transform maps
        // it to device. See the convention documented on `SceneText.referenceLogical`.
        let familyName = text.requestedFamily.isEmpty ? text.fontFamily : text.requestedFamily
        let font: EMFPlusFont
        if text.isEMFPlus, text.emSize > 0 {
            // Re-emit the font in its ORIGINAL size unit and em size. The overlay
            // keeps the source EmfPlusHeader, so a physical-unit font (Point/Inch/mm)
            // resolves through the SAME LogicalDpiY it did originally, and a World/
            // Pixel-unit font scales by the re-established world transform — exact for
            // every unit, with no hardcoded DPI ([MS-EMFPLUS] §2.1.1.32, §2.3.3.3).
            font = EMFPlusFont(
                version: graphicsVersion, emSize: safeFloat(CGFloat(text.emSize)), sizeUnit: text.emSizeUnit,
                styleFlags: fontStyle(text), familyName: familyName)
        } else {
            // A new or GDI-origin text run has no EMF+ em size: size it from the
            // logical cell/em height in World units, which the world transform scales
            // to the device size the lift resolved.
            font = EMFPlusFont(
                version: graphicsVersion, emSize: safeFloat(CGFloat(abs(text.logicalHeight))), sizeUnit: unitWorld,
                styleFlags: fontStyle(text), familyName: familyName)
        }

        // The layout rect in WORLD space: the run's real rectangle when it has extent
        // (so alignment and wrap/clip behave as in the source), else a zero-size
        // point rect at the reference origin (Near point-origin). The world transform
        // (SetWorldTransform) maps it to device, exactly like the lift inverted it.
        let origin = text.referenceLogical
        let layout: EMFPlusRectF
        if text.layoutReference.isNull || (text.layoutReference.width == 0 && text.layoutReference.height == 0) {
            layout = EMFPlusRectF(x: safeFloat(origin.x), y: safeFloat(origin.y), width: 0, height: 0)
        } else {
            let r = text.layoutReference
            layout = EMFPlusRectF(x: safeFloat(r.minX), y: safeFloat(r.minY), width: safeFloat(r.width), height: safeFloat(r.height))
        }

        var emits: [Emit] = [
            .record(.setWorldTransform(matrix(element.transform))),
            .object(id: fontID, type: .font, value: .font(font)),
        ]
        // Re-emit a StringFormat object whenever the run carried a non-default
        // alignment, line alignment, or format flag; the no-format default (FormatID
        // 0xFFFFFFFF) is Near/Near with wrap+clip on and reproduces a plain run
        // byte-for-byte ([MS-EMFPLUS] §2.3.4.14, §2.2.1.9). Only the fields playback
        // honours (StringAlignment, LineAlign, StringFormatFlags) need to match.
        var formatID = EMFPlusRecordPayload.noImageAttributes
        if text.alignRawValue != 0 || text.lineAlignRawValue != 0 || text.stringFormatFlags != 0 {
            if let formatSlot = allocate() {
                let format = EMFPlusStringFormat(
                    version: graphicsVersion, stringFormatFlags: text.stringFormatFlags, language: 0,
                    stringAlignment: text.alignRawValue, lineAlign: text.lineAlignRawValue,
                    digitSubstitution: 0, digitLanguage: 0, firstTabOffset: 0, hotkeyPrefix: 0,
                    leadingMargin: 0, trailingMargin: 0, tracking: 1, trimming: 0,
                    tabStops: [], characterRanges: [])
                emits.append(.object(id: formatSlot, type: .stringFormat, value: .stringFormat(format)))
                formatID = UInt32(formatSlot)
            }
        }
        emits.append(.record(.drawString(fontID: fontID, brush: .color(argb(color, opacity: element.style.opacity)),
                                         formatID: formatID, layoutRect: layout, text: text.string)))
        return emits
    }

    private static func fontStyle(_ text: SceneText) -> Int32 {
        var flags: Int32 = 0
        if text.bold { flags |= 0x1 }
        if text.italic { flags |= 0x2 }
        if text.underline { flags |= 0x4 }
        if text.strikeOut { flags |= 0x8 }
        return flags
    }

    // MARK: - Image

    private static func imageEmits(_ element: Element, allocate: () -> UInt8?, warnings: inout [ExportWarning]) -> [Emit]? {
        // A sub-1 element opacity is baked into the PNG alpha here, so the EMF+
        // DrawImage needs no ImageAttributes and every GDI+ reader shows the blend
        // (slice E1b2c). The GDI fallback cannot hold it and reports opacityDropped.
        guard let scImage = element.image,
              let plus = SceneImageCoding.compressedPNGImage(for: scImage, opacity: element.style.opacity) else {
            warnings.append(.imageDropped(elementID: element.id)); return nil
        }
        guard let imageID = allocate() else { return nil }
        let dest = scImage.destRectDevice.standardized
        guard dest.width > 0, dest.height > 0 else { warnings.append(.imageDropped(elementID: element.id)); return nil }
        // SrcRect honours the source crop when one was recorded (§2.3.4.8): the PNG
        // re-encodes the whole image at native pixel size, so a pixel-unit crop that
        // fits the PNG re-emits verbatim; otherwise the whole image is drawn. The PNG
        // header carries the native pixel size.
        let (pw, ph): (Float, Float)
        if case .bitmap(let header, _) = plus.content { pw = Float(header.width); ph = Float(header.height) }
        else { pw = Float(dest.width); ph = Float(dest.height) }
        let crop = scImage.srcRect
        let src: EMFPlusRectF
        if !crop.isNull, crop.width > 0, crop.height > 0, scImage.srcUnit == Int32(unitPixel),
           crop.minX >= -0.5, crop.minY >= -0.5, crop.maxX <= Double(pw) + 0.5, crop.maxY <= Double(ph) + 0.5 {
            src = EMFPlusRectF(x: safeFloat(crop.minX), y: safeFloat(crop.minY), width: safeFloat(crop.width), height: safeFloat(crop.height))
        } else {
            src = EMFPlusRectF(x: 0, y: 0, width: pw, height: ph)
        }
        // A rotation/shear edit stored the true device parallelogram — write
        // EmfPlusDrawImagePoints (upper-left, upper-right, lower-left; §2.3.4.9) so
        // the rotation survives. An axis-aligned dest uses EmfPlusDrawImage.
        if let corners = scImage.destCornersDevice, corners.count == 4 {
            let pts = [pointF(corners[0]), pointF(corners[1]), pointF(corners[3])]
            return [
                .object(id: imageID, type: .image, value: .image(plus)),
                .record(.drawImagePoints(imageID: imageID, imageAttributesID: nil, srcUnit: Int32(unitPixel),
                                         srcRect: src, points: pts)),
            ]
        }
        return [
            .object(id: imageID, type: .image, value: .image(plus)),
            .record(.drawImage(imageID: imageID, imageAttributesID: nil, srcUnit: Int32(unitPixel),
                               srcRect: src, destRect: rectF(dest))),
        ]
    }

    // MARK: - Object builders

    private static func plusPen(_ stroke: SceneStroke, element: Element, opacity: Double) -> EMFPlusObjectValue {
        let deviceWidth = stroke.isCosmetic ? 1 : stroke.width * SceneSynthesis.averageScale(element.transform)
        // Flags ([MS-EMFPLUS] §2.1.2.7): StartCap, EndCap, Join, MiterLimit always;
        // LineStyle when a preset dash is set.
        var flags: UInt32 = 0x02 | 0x04 | 0x08 | 0x10
        var lineStyle: Int32?
        switch stroke.dash {
        case .solid, .userStyle: break
        case .dash: lineStyle = 1
        case .dot: lineStyle = 2
        case .dashDot: lineStyle = 3
        case .dashDotDot: lineStyle = 4
        }
        if lineStyle != nil { flags |= 0x20 }
        let data = EMFPlusPenData(
            flags: flags, unit: unitWorld, width: Float(max(0, deviceWidth)),
            transform: nil, startCap: capValue(stroke.cap), endCap: capValue(stroke.cap),
            join: joinValue(stroke.join), miterLimit: Float(max(1, stroke.miterLimit)),
            lineStyle: lineStyle, dashedLineCap: nil, dashOffset: nil, dashedLine: nil,
            penAlignment: nil, compoundLine: nil, customStartCap: nil, customEndCap: nil)
        let brush = EMFPlusBrush(version: graphicsVersion, brushType: .solid, data: .solid(argb(stroke.color, opacity: opacity)))
        return .pen(EMFPlusPen(version: graphicsVersion, type: 0, penData: data, brush: brush))
    }

    /// A linear-gradient brush whose axis maps the unit rect's midline to the
    /// scene gradient's DEVICE-space axis (brush transform), so the identity-world
    /// block reproduces it exactly ([MS-EMFPLUS] §2.2.2.24/§2.2.2.25).
    private static func gradientBrush(_ g: SceneGradient, opacity: Double) -> EMFPlusObjectValue {
        let dx = Double(g.endDevice.x - g.startDevice.x)
        let dy = Double(g.endDevice.y - g.startDevice.y)
        let transform = EMFPlusTransformMatrix(
            m11: Float(dx), m12: Float(dy), m21: Float(-dy), m22: Float(dx),
            dx: Float(Double(g.startDevice.x) + 0.5 * dy), dy: Float(Double(g.startDevice.y) - 0.5 * dx))
        let start = g.stops.first.map { argb($0.color, opacity: opacity) } ?? argb(SceneColor(red: 0, green: 0, blue: 0), opacity: opacity)
        let end = g.stops.last.map { argb($0.color, opacity: opacity) } ?? start
        var flags: UInt32 = 0x02   // BrushDataTransform
        var blend: EMFPlusGradientBlend?
        if g.stops.count > 2 {
            flags |= 0x04          // BrushDataPresetColors
            blend = .presetColors(EMFPlusBlendColors(
                positions: g.stops.map { Float(min(max($0.location, 0), 1)) },
                colors: g.stops.map { argb($0.color, opacity: opacity) }))
        }
        let brush = EMFPlusLinearGradientBrush(
            brushDataFlags: flags, wrapMode: 4 /* WrapModeClamp */,
            rect: EMFPlusRectF(x: 0, y: 0, width: 1, height: 1),
            startColor: start, endColor: end, reserved1: 0, reserved2: 0,
            transform: transform, blend: blend)
        return .brush(EMFPlusBrush(version: graphicsVersion, brushType: .linearGradient, data: .linearGradient(brush)))
    }

    /// An uncompressed EmfPlusPath (PointF points) from a value-type path
    /// ([MS-EMFPLUS] §2.2.1.6 / §2.2.2.31): a move starts a subpath, a cubic curve
    /// is three bezier points, a close sets the close flag on the last point.
    private static func plusPath(_ path: ScenePath) -> EMFPlusObjectValue {
        var points: [EMFPlusPointF] = []
        var types: [UInt8] = []
        var current = CGPoint.zero
        func closeLast() { if let last = types.indices.last { types[last] |= 0x80 } }
        for segment in path.segments {
            switch segment {
            case .move(let p): points.append(pointF(p)); types.append(0x00); current = p
            case .line(let p): points.append(pointF(p)); types.append(0x01); current = p
            case .cubicCurve(let to, let c1, let c2):
                points.append(pointF(c1)); types.append(0x03)
                points.append(pointF(c2)); types.append(0x03)
                points.append(pointF(to)); types.append(0x03); current = to
            case .quadCurve(let to, let c):
                let c1 = CGPoint(x: current.x + 2.0 / 3.0 * (c.x - current.x), y: current.y + 2.0 / 3.0 * (c.y - current.y))
                let c2 = CGPoint(x: to.x + 2.0 / 3.0 * (c.x - to.x), y: to.y + 2.0 / 3.0 * (c.y - to.y))
                points.append(pointF(c1)); types.append(0x03)
                points.append(pointF(c2)); types.append(0x03)
                points.append(pointF(to)); types.append(0x03); current = to
            case .close: closeLast()
            }
        }
        return .path(EMFPlusPath(version: graphicsVersion, pointCount: UInt32(clamping: points.count), flags: 0, points: points, pointTypes: types))
    }

    // MARK: - Cap/join ([MS-EMFPLUS] §2.1.1.18 LineCap / §2.1.1.19 LineJoin)

    private static func capValue(_ cap: CGLineCap) -> Int32 {
        switch cap { case .butt: return 0; case .square: return 1; case .round: return 2; @unknown default: return 0 }
    }
    private static func joinValue(_ join: CGLineJoin) -> Int32 {
        switch join { case .miter: return 0; case .round: return 2; case .bevel: return 1; @unknown default: return 0 }
    }

    // MARK: - Conversions

    private static func argb(_ color: SceneColor, opacity: Double) -> EMFPlusARGB {
        func channel(_ v: Double) -> UInt8 { UInt8((v * 255).rounded().clamped(0, 255)) }
        return EMFPlusARGB(blue: channel(color.blue), green: channel(color.green), red: channel(color.red),
                           alpha: channel(color.alpha * min(max(opacity, 0), 1)))
    }
    /// A `CGAffineTransform` as an EMF+ transform matrix ([MS-EMFPLUS] §2.2.2.47):
    /// a→m11, b→m12, c→m21, d→m22, tx→dx, ty→dy.
    private static func matrix(_ t: CGAffineTransform) -> EMFPlusTransformMatrix {
        EMFPlusTransformMatrix(
            m11: safeFloat(t.a), m12: safeFloat(t.b), m21: safeFloat(t.c), m22: safeFloat(t.d),
            dx: safeFloat(t.tx), dy: safeFloat(t.ty))
    }

    private static func pointF(_ p: CGPoint) -> EMFPlusPointF { EMFPlusPointF(x: safeFloat(p.x), y: safeFloat(p.y)) }
    private static func rectF(_ r: CGRect) -> EMFPlusRectF {
        let s = r.standardized
        return EMFPlusRectF(x: safeFloat(s.minX), y: safeFloat(s.minY), width: safeFloat(s.width), height: safeFloat(s.height))
    }
    private static func safeFloat(_ v: CGFloat) -> Float { v.isFinite ? Float(v) : 0 }
}
