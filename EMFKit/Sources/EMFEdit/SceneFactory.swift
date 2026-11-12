import CoreGraphics
import EMFParse
import EMFWrite
import Foundation

/// Creates new metafile documents and new shape elements from scratch — the E3
/// creation entry points (docs/v3-plan §11.3). Additive: nothing here changes
/// how an existing scene imports, exports, mutates or renders. A blank document
/// is a real, minimal EMF, so a new document is just a normal file and all of
/// E2 (import, save, undo, revert, export) applies to it unchanged.
public enum SceneFactory {

    /// The device resolution a from-scratch metafile is authored at — the same
    /// 96 DPI the WMF device canvas (WMFTranslator) and the WMF→EMF synthesis use,
    /// so a page's physical size (its millimetre frame) and its device-pixel page
    /// bounds agree.
    public static let dotsPerInch: Double = 96

    // MARK: - Blank document

    /// A minimal, valid EMF for a blank page of `pageSizeMillimetres` (width,
    /// height) in millimetres: an EMR_HEADER with correct bounds, frame, and
    /// device/millimetre reference sizes, then EMR_EOF — no drawing records.
    ///
    /// Importing it through `SceneImporter` yields a scene with zero elements and
    /// a page bounds of `(0, 0, deviceWidth, deviceHeight)`, and it round-trips
    /// through the exporter. `rclBounds` is inclusive-inclusive so a page W pixels
    /// wide uses `right = W - 1` ([MS-EMF] §2.2.9); `rclFrame` is in units of
    /// 0.01 mm (§2.2.9); EMR_HEADER §2.3.4.2, EMR_EOF §2.3.4.1.
    public static func blankDocument(pageSizeMillimetres size: CGSize) throws(EMFWriteError) -> Data {
        let mmW = sanitizedMillimetres(size.width)
        let mmH = sanitizedMillimetres(size.height)
        let deviceW = devicePixels(fromMillimetres: mmW)
        let deviceH = devicePixels(fromMillimetres: mmH)

        // Inclusive-inclusive bounds: a W×H device page spans [0, W-1]×[0, H-1].
        let bounds = RectL(left: 0, top: 0, right: deviceW &- 1, bottom: deviceH &- 1)
        // rclFrame is in 0.01 mm.
        let frame = RectL(
            left: 0, top: 0,
            right: SceneNumeric.int32(mmW * 100), bottom: SceneNumeric.int32(mmH * 100)
        )
        let device = SizeL(cx: deviceW, cy: deviceH)
        let millimetres = SizeL(cx: SceneNumeric.int32(mmW), cy: SceneNumeric.int32(mmH))

        let builder = EMFDocumentBuilder(bounds: bounds, frame: frame, device: device, millimeters: millimetres)
        return try builder.finish()
    }

    /// A page size in millimetres clamped to a sane, positive range so the device
    /// conversion and the saturating integer fields never see 0, a negative, or a
    /// non-finite dimension (§8: never trap on a caller-derived number).
    private static func sanitizedMillimetres(_ mm: CGFloat) -> Double {
        let value = Double(mm)
        guard value.isFinite, value > 0 else { return 1 }
        return min(value, 100_000)
    }

    /// Device pixels for a millimetre length at `dotsPerInch`, floored at 1.
    private static func devicePixels(fromMillimetres mm: Double) -> Int32 {
        max(1, SceneNumeric.int32(mm / 25.4 * dotsPerInch))
    }

    // MARK: - Shapes

    /// The default paint for a newly-drawn closed shape (rect, rounded rect,
    /// ellipse, triangle): a solid system-blue fill, no stroke (Keynote default).
    public static let defaultShapeStyle = SceneStyle(
        fill: SceneFill(color: systemBlue, evenOdd: false),
        stroke: nil
    )

    /// The default paint for a newly-drawn line: a 2 pt black stroke, no fill.
    /// `width` is in the element's own (device) units; the tool converts the UI's
    /// 2 pt into device units before calling.
    public static func defaultLineStyle(widthDevice: Double) -> SceneStyle {
        SceneStyle(
            fill: nil,
            stroke: SceneStroke(
                color: SceneColor(red: 0, green: 0, blue: 0),
                isCosmetic: false, width: widthDevice, dash: .solid,
                cap: .butt, join: .miter, miterLimit: 10
            )
        )
    }

    /// macOS/iOS system blue (#0A84FF).
    public static let systemBlue = SceneColor(
        red: 10.0 / 255, green: 132.0 / 255, blue: 255.0 / 255
    )

    // MARK: - Freehand pen strokes (E3b)

    /// The paint for a freehand pen stroke: a solid stroke of `color` and `widthDevice`
    /// (the element's own device units; the tool converts the UI's point width through
    /// `Scene.deviceUnitsPerPoint`), no fill — an open stroked path. Cap/join are round
    /// so a hand-drawn curve reads smoothly.
    public static func penStyle(color: SceneColor, widthDevice: Double) -> SceneStyle {
        SceneStyle(
            fill: nil,
            stroke: SceneStroke(
                color: color,
                isCosmetic: false, width: widthDevice, dash: .solid,
                cap: .round, join: .round, miterLimit: 10
            )
        )
    }

    /// Builds a new freehand-stroke `Element` from a device-space smoothed path: an
    /// OPEN `.path` element, stroke-only, identity transform (the geometry already lives
    /// in device space), new/edited and unlocked provenance. The exporter synthesises it
    /// as a path bracket (EMR_BEGINPATH … MoveToEx/PolyBezierTo … EMR_ENDPATH →
    /// EMR_STROKEPATH, [MS-EMF] §2.3.10) so the stroke survives save → re-import as a
    /// `.path` and E2c's inspector can edit its stroke colour and width. A stroke carries
    /// no fill, so nothing is ever closed or filled.
    public static func makeStroke(geometryDevice: ScenePath, style: SceneStyle, id: Int) -> Element {
        Element(
            id: id,
            kind: .path,
            geometryDevice: geometryDevice,
            transform: .identity,
            style: style,
            provenance: Provenance(sourceRecordIndices: [], edited: true),
            locked: false
        )
    }

    /// Builds a new shape `Element` of `kind` filling `rectDevice` (device space),
    /// with `style` and the given `id`. Geometry matches the kind the synthesiser
    /// re-emits (RECTANGLE, ELLIPSE, POLYGON, POLYLINE), so the shape survives
    /// save → re-import as its own kind; a `.roundRect` is re-emitted as a path
    /// bracket (its corner radius is not retained by a GDI record) and re-imports
    /// as `.path`, rendering and exporting identically. The transform is identity
    /// (geometry already lives in device space) and provenance is new/edited and
    /// unlocked, so the exporter synthesises it and E2's inspector can edit it.
    ///
    /// `cornerRadiusDevice` applies only to `.roundRect`; it is clamped to half
    /// the shorter side. For `.line` the two endpoints are `rectDevice`'s origin
    /// and `origin + (width, height)`, so a drag's direction (and a negative
    /// width/height) is preserved.
    public static func makeShape(
        kind: ElementKind,
        rectDevice: CGRect,
        style: SceneStyle,
        id: Int,
        cornerRadiusDevice: CGFloat = 0
    ) -> Element {
        Element(
            id: id,
            kind: kind,
            geometryDevice: shapeGeometry(kind: kind, rectDevice: rectDevice, cornerRadiusDevice: cornerRadiusDevice),
            transform: .identity,
            style: style,
            provenance: Provenance(sourceRecordIndices: [], edited: true),
            locked: false
        )
    }

    /// The device-space `ScenePath` for a shape kind in `rectDevice`.
    private static func shapeGeometry(kind: ElementKind, rectDevice: CGRect, cornerRadiusDevice: CGFloat) -> ScenePath {
        let box = rectDevice.standardized
        switch kind {
        case .line:
            // Keep the drag direction: endpoints are the raw origin and far corner.
            // `size` keeps the sign (`CGRect.width`/`.height` return absolute values).
            let start = rectDevice.origin
            let end = CGPoint(x: rectDevice.origin.x + rectDevice.size.width, y: rectDevice.origin.y + rectDevice.size.height)
            return ScenePath(segments: [.move(start), .line(end)])
        case .ellipse:
            return ScenePath(CGPath(ellipseIn: box, transform: nil))
        case .roundRect:
            let radius = max(0, min(cornerRadiusDevice, min(box.width, box.height) / 2))
            return ScenePath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case .polygon:
            // An isosceles triangle inscribed in the box: apex top-centre, base along
            // the bottom edge. A single closed subpath, so it re-emits as a POLYGON.
            return ScenePath(segments: [
                .move(CGPoint(x: box.midX, y: box.minY)),
                .line(CGPoint(x: box.maxX, y: box.maxY)),
                .line(CGPoint(x: box.minX, y: box.maxY)),
                .close,
            ])
        default:
            // .rect (and any other closed kind): a four-corner rectangle outline,
            // which `SceneSynthesis.axisAlignedRect` recovers as a RECTANGLE.
            return ScenePath(segments: [
                .move(CGPoint(x: box.minX, y: box.minY)),
                .line(CGPoint(x: box.maxX, y: box.minY)),
                .line(CGPoint(x: box.maxX, y: box.maxY)),
                .line(CGPoint(x: box.minX, y: box.maxY)),
                .close,
            ])
        }
    }

    // MARK: - Text (E3c)

    /// TA_LEFT | TA_BASELINE (0x18, [MS-EMF] §2.3.11.25): the run's reference point is
    /// its left edge on the text baseline — the E3c text-tool default, so a click/tap
    /// drops the baseline under the pointer.
    public static let baselineLeftAlign: UInt32 = 0x0018

    /// Builds a new GDI text `Element` reading `string`, with its baseline-left
    /// reference at `originDevice` (device space, identity transform so device ==
    /// logical). `pointSize` is a typographic point size (1/72 inch) converted to the
    /// run's LOGFONT em height through `deviceUnitsPerPoint` (from
    /// `Scene.deviceUnitsPerPoint`), stored NEGATIVE as the character/em height
    /// ([MS-EMF] §2.2.13, matching `Scene.setFont`). The exporter synthesises it as
    /// EMR_EXTCREATEFONTINDIRECTW + EMR_EXTTEXTOUTW (and the EMF+/WMF/SVG equivalents),
    /// and E2c's inspector and the text popover edit it like any imported run.
    public static func makeText(
        string: String,
        originDevice: CGPoint,
        family: String,
        pointSize: Double,
        color: SceneColor,
        id: Int,
        deviceUnitsPerPoint: CGFloat
    ) -> Element {
        let em = max(1, (Double(deviceUnitsPerPoint) * pointSize).rounded())
        let logicalHeight = -SceneNumeric.int32(em)
        let text = SceneText(
            string: string, fontFamily: family, logicalHeight: logicalHeight,
            color: color, referenceLogical: originDevice, alignRawValue: baselineLeftAlign)
        let geometry = ScenePath(CGPath(rect: textBox(string: string, referenceDevice: originDevice, em: em, alignRawValue: baselineLeftAlign), transform: nil))
        return Element(
            id: id, kind: .text, geometryDevice: geometry, transform: .identity,
            text: text, provenance: Provenance(sourceRecordIndices: [], edited: true), locked: false
        )
    }

    /// A device-space box around a GDI text run for the element's cached bounds (the
    /// tight selection box is recomputed from the run's metrics by the app). Mirrors
    /// the horizontal-anchor and vertical-band estimate `SceneRasterize`/`EditorTextBounds`
    /// use: a left/centre/right anchor from the alignment flags, a one-em horizontal
    /// margin, and a 2.8-em vertical band centred near the baseline.
    private static func textBox(string: String, referenceDevice: CGPoint, em: Double, alignRawValue: UInt32) -> CGRect {
        let count = max(1, string.utf16.count)
        let width = Double(count) * em
        let refX = Double(referenceDevice.x)
        let x0: Double
        switch alignRawValue & 0x6 {
        case 0x2: x0 = refX - width            // TA_RIGHT
        case 0x6: x0 = refX - width / 2        // TA_CENTER
        default:  x0 = refX                    // TA_LEFT
        }
        let margin = em
        return CGRect(x: x0 - margin, y: Double(referenceDevice.y) - em * 1.4, width: width + 2 * margin, height: em * 2.8)
    }

    // MARK: - Images (E3c)

    /// Builds a new image `Element` whose pixels are `cgImage`, placed axis-aligned at
    /// `destRectDevice` (device space, identity transform). The pixels are re-encoded to
    /// a compressed PNG (`SceneImageCoding`), which both strips source metadata
    /// (EXIF/GPS; §8) and is the carrier the exporter already knows (E1's compressed-PNG
    /// EMF+ bitmap → STRETCHDIBITS GDI fallback, WMF image, SVG data URI). Nil when the
    /// pixels cannot be PNG-encoded.
    public static func makeImage(cgImage: CGImage, destRectDevice: CGRect, id: Int) -> Element? {
        guard let plus = SceneImageCoding.compressedPNGImage(fromCGImage: cgImage) else { return nil }
        let rect = destRectDevice.standardized
        let image = SceneImage(emfPlusImage: plus, destRectDevice: rect)
        let geometry = ScenePath(CGPath(rect: rect, transform: nil))
        return Element(
            id: id, kind: .image, geometryDevice: geometry, transform: .identity,
            image: image, provenance: Provenance(sourceRecordIndices: [], edited: true), locked: false
        )
    }

    /// The axis-aligned device rectangle a newly-inserted image fills: it fits within
    /// 50% of the page's smaller dimension, preserves the image's aspect ratio, and
    /// centres on the page — or on `centreDevice` when inserted at a drop point (E3c
    /// image placement). Degenerate inputs clamp so nothing traps (§8).
    public static func fitImageRect(imagePixelSize: CGSize, pageBoundsDevice: CGRect, centreDevice: CGPoint? = nil) -> CGRect {
        let imgW = max(1, Double(imagePixelSize.width))
        let imgH = max(1, Double(imagePixelSize.height))
        let maxDim = max(1, 0.5 * Double(min(pageBoundsDevice.width, pageBoundsDevice.height)))
        let scale = min(maxDim / imgW, maxDim / imgH)
        let w = imgW * scale
        let h = imgH * scale
        let centre = centreDevice ?? CGPoint(x: pageBoundsDevice.midX, y: pageBoundsDevice.midY)
        return CGRect(x: Double(centre.x) - w / 2, y: Double(centre.y) - h / 2, width: w, height: h)
    }

    // MARK: - Unique ids

    /// The next free element id for `scene` — one past the largest id in any layer,
    /// or 0 for an empty scene. New elements must not collide with an existing id
    /// (ids address elements for selection, undo and mutation).
    public static func nextElementID(in scene: Scene) -> Int {
        let maxID = scene.elements.map(\.id).max()
        return (maxID ?? -1) + 1
    }
}
