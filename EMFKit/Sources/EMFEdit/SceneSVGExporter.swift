import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import WMFParse

/// A fidelity note from an SVG export. SVG natively holds alpha, gradients and
/// arbitrary affine image placement, so unlike the EMF/WMF `ExportWarning` list
/// there is little to drop — the only losses are content that cannot be lifted
/// vectorially (a passthrough record is RASTERISED into an embedded PNG), an
/// image whose pixels cannot be decoded or encoded, geometry whose coordinates
/// are non-finite, an approximated text rotation, and a hostile scene hitting the
/// output ceiling. Maps onto the shared `ExportWarningCategory` via `summarize`.
public enum SVGExportWarning: Sendable, Equatable {
    /// A passthrough (or otherwise unrepresentable) element was drawn alone into a
    /// bitmap and embedded as a PNG `<image>` so it still looks right, at the cost
    /// of editability.
    case contentRasterized(elementID: Int)
    /// An image element's pixels could not be decoded/encoded (or exceeded the
    /// per-image output budget), so it was omitted.
    case imageDropped(elementID: Int)
    /// An element whose geometry/placement was non-finite was skipped (§8: a
    /// hostile edit can push a coordinate to infinity).
    case elementSkipped(elementID: Int)
    /// A text run carried a baseline rotation (GDI escapement) that SVG reproduces
    /// as a `rotate()` transform; the sign/pivot is an approximation.
    case textRotationApproximated(elementID: Int)
    /// The output hit the size ceiling (a hostile scene); later elements were
    /// omitted and the document was closed well-formed.
    case outputTruncated
}

/// SVG export tuning.
public struct SVGExportOptions: Sendable, Equatable {
    /// Rasterise passthrough/unrepresentable elements into embedded PNGs (default).
    /// When false they are omitted with a warning instead.
    public var rasterizePassthrough: Bool

    public init(rasterizePassthrough: Bool = true) {
        self.rasterizePassthrough = rasterizePassthrough
    }
}

/// The bytes an SVG export produced, plus any fidelity warnings.
public struct SVGExportResult: Sendable, Equatable {
    public let data: Data
    public let warnings: [SVGExportWarning]

    public init(data: Data, warnings: [SVGExportWarning]) {
        self.data = data
        self.warnings = warnings
    }
}

/// Serialises an editable `Scene` to a standalone **SVG 1.1** document
/// (plus two SVG 2 features that every mainstream renderer — Illustrator,
/// Inkscape, Chrome/Safari/Firefox, Keynote — supports: `vector-effect=
/// "non-scaling-stroke"` for cosmetic pens, and `paint-order` is NOT used).
/// This is the F2 "scene → SVG" backend (docs/v3-plan §11.2).
///
/// The document is self-contained and safe to open in another app (§8 spirit):
/// every attribute and text node is escaped, characters illegal in XML 1.0 are
/// stripped, there are no scripts, no `<foreignObject>`, and the only external
/// reference an image can carry is an inline `data:image/png;base64,…` URI. The
/// export never traps on a hostile scene — non-finite numbers are skipped with a
/// warning and the output is capped — and the same scene always produces
/// byte-identical bytes (stable ids, fixed 3-decimal float formatting).
///
/// Clean-room: the mapping derives from the W3C SVG 1.1 Recommendation only.
public enum SceneSVGExporter {

    public static func export(_ scene: Scene, options: SVGExportOptions = SVGExportOptions()) -> SVGExportResult {
        let builder = SVGBuilder(scene: scene, options: options)
        return builder.run()
    }

    /// Groups SVG warnings into the shared user-facing categories, so the app can
    /// show one short list the way the EMF/WMF export flow does.
    public static func summarize(_ warnings: [SVGExportWarning]) -> [ExportWarningCategory: Int] {
        var seen: [SVGExportWarning] = []
        for warning in warnings where !seen.contains(warning) { seen.append(warning) }
        var counts: [ExportWarningCategory: Int] = [:]
        for warning in seen {
            let category: ExportWarningCategory
            switch warning {
            case .contentRasterized: category = .rasterized
            case .imageDropped: category = .image
            case .elementSkipped, .outputTruncated: category = .droppedContent
            case .textRotationApproximated: category = .text
            }
            counts[category, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Builder

/// The single-pass SVG serialiser. A local reference type so the body, the `defs`
/// registries and the running byte budget accumulate without threading them
/// through every call; it is created, run and discarded inside one `export`.
private final class SVGBuilder {
    private let scene: Scene
    private let options: SVGExportOptions

    private var body = ""
    private var defs = ""
    private var warnings: [SVGExportWarning] = []

    /// Deduplicated clip paths and gradients, in first-appearance order (`ScenePath`
    /// and `SceneGradient` are `Equatable`, not `Hashable`, so this is a linear
    /// registry — the distinct-clip/gradient count is tiny even for a huge scene).
    private var clips: [(path: ScenePath, id: String)] = []
    private var gradients: [(gradient: SceneGradient, id: String)] = []

    /// Rasterisation source for passthrough elements, built once on first need.
    private var rasterSource: SceneRasterize.Source??

    /// Output ceiling (§8): a hostile scene must not exhaust memory. Base64 image
    /// data legitimately dominates, so the cap is generous; once the body passes it
    /// the walk stops and the document is closed well-formed.
    private static let maxBodyBytes = 128 * 1024 * 1024
    /// Per-image data-URI budget: an image whose encoded PNG would exceed this is
    /// dropped rather than embedded.
    private static let maxImageDataBytes = 48 * 1024 * 1024
    private var truncated = false

    init(scene: Scene, options: SVGExportOptions) {
        self.scene = scene
        self.options = options
    }

    func run() -> SVGExportResult {
        for element in scene.elements where !element.hidden {
            if truncated { break }
            if body.utf8.count > Self.maxBodyBytes {
                truncated = true
                warnings.append(.outputTruncated)
                break
            }
            emit(element)
        }

        let header = documentHeader()
        var out = header
        if !defs.isEmpty {
            out += "  <defs>\n" + defs + "  </defs>\n"
        }
        out += body
        out += "</svg>\n"
        return SVGExportResult(data: Data(out.utf8), warnings: warnings)
    }

    // MARK: Document frame

    /// The opening `<svg>` tag. The viewBox is the device-space page; width/height
    /// are the physical size (mm) so the drawing imports at true scale.
    private func documentHeader() -> String {
        let page = SVGFormat.finiteRect(scene.pageBoundsDevice) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let vb = "\(SVGFormat.num(page.minX)) \(SVGFormat.num(page.minY)) "
            + "\(SVGFormat.num(max(1, page.width))) \(SVGFormat.num(max(1, page.height)))"
        var dims = ""
        if let mm = SVGPhysicalSize.millimetres(for: scene) {
            dims = " width=\"\(SVGFormat.num(mm.width))mm\" height=\"\(SVGFormat.num(mm.height))mm\""
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            + "<svg xmlns=\"http://www.w3.org/2000/svg\""
            + " xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\""
            + dims + " viewBox=\"\(vb)\">\n"
    }

    // MARK: Element dispatch

    private func emit(_ element: Element) {
        switch element.kind {
        case .passthrough:
            emitRasterized(element)
        case .text:
            emitText(element)
        case .image:
            emitImage(element)
        case .group:
            break   // a container carries no own geometry
        default:
            emitGeometry(element)
        }
    }

    // MARK: Geometry

    private func emitGeometry(_ element: Element) {
        guard !element.geometryDevice.isEmpty else { return }
        guard element.style.fill != nil || element.style.stroke != nil else { return }
        guard SVGGeometry.isFinite(element.geometryDevice) else {
            warnings.append(.elementSkipped(elementID: element.id)); return
        }

        var attrs = paintAttributes(for: element)
        if element.style.opacity < 1 { attrs.append("opacity=\"\(SVGFormat.num(element.style.opacity))\"") }

        // Recover a primitive shape when it round-trips cleanly (editability);
        // otherwise a path, which is always exact.
        let shape = SVGGeometry.shape(for: element)
        appendClipped("<\(shape.tag) \(shape.geometryAttribute) \(attrs.joined(separator: " "))/>", clip: element.clipDevice)
    }

    /// The fill/stroke attributes shared by geometry (and reused for text fill).
    private func paintAttributes(for element: Element) -> [String] {
        var attrs: [String] = []
        if let fill = element.style.fill {
            if let gradient = fill.gradient {
                attrs.append("fill=\"\(gradientReference(gradient))\"")
            } else {
                attrs.append("fill=\"\(SVGFormat.hex(fill.color))\"")
                if fill.color.alpha < 1 { attrs.append("fill-opacity=\"\(SVGFormat.num(fill.color.alpha))\"") }
            }
            if fill.evenOdd { attrs.append("fill-rule=\"evenodd\"") }
        } else {
            attrs.append("fill=\"none\"")
        }
        if let stroke = element.style.stroke {
            attrs.append(contentsOf: strokeAttributes(stroke, transform: element.transform))
        }
        return attrs
    }

    /// Stroke attributes in device units. A cosmetic pen is 1 device unit with
    /// `vector-effect="non-scaling-stroke"` so it stays hairline at any zoom, as a
    /// GDI cosmetic pen does. A geometric pen's logical width is scaled to device by
    /// the element transform, mirroring `StrokeMapper.deviceStroke`.
    private func strokeAttributes(_ stroke: SceneStroke, transform: CGAffineTransform) -> [String] {
        let unitScale = stroke.isCosmetic ? 1.0 : SVGGeometry.averageScale(transform)
        let width = stroke.isCosmetic ? 1.0 : max(0, Double(stroke.width) * unitScale)
        var attrs: [String] = []
        attrs.append("stroke=\"\(SVGFormat.hex(stroke.color))\"")
        if stroke.color.alpha < 1 { attrs.append("stroke-opacity=\"\(SVGFormat.num(stroke.color.alpha))\"") }
        attrs.append("stroke-width=\"\(SVGFormat.num(width))\"")
        if stroke.isCosmetic { attrs.append("vector-effect=\"non-scaling-stroke\"") }
        switch stroke.cap {
        case .round: attrs.append("stroke-linecap=\"round\"")
        case .square: attrs.append("stroke-linecap=\"square\"")
        default: break   // butt is the SVG default
        }
        switch stroke.join {
        case .round: attrs.append("stroke-linejoin=\"round\"")
        case .bevel: attrs.append("stroke-linejoin=\"bevel\"")
        default:
            if stroke.miterLimit > 0, stroke.miterLimit != 4 {
                attrs.append("stroke-miterlimit=\"\(SVGFormat.num(max(1, stroke.miterLimit)))\"")
            }
        }
        if let dash = SVGGeometry.dashArray(stroke, width: width, unitScale: unitScale) {
            attrs.append("stroke-dasharray=\"\(dash)\"")
        }
        return attrs
    }

    // MARK: Gradients and clips (defs)

    private func gradientReference(_ gradient: SceneGradient) -> String {
        if let existing = gradients.first(where: { $0.gradient == gradient }) { return "url(#\(existing.id))" }
        let id = "g\(gradients.count)"
        gradients.append((gradient, id))
        defs += gradientDef(gradient, id: id)
        return "url(#\(id))"
    }

    /// A `<linearGradient>` in userSpaceOnUse device coordinates (the scene gradient
    /// axis is already device-space), with every stop. Clamp semantics match
    /// playback via `spreadMethod="pad"` (the SVG default).
    private func gradientDef(_ gradient: SceneGradient, id: String) -> String {
        var out = "    <linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" "
        out += "x1=\"\(SVGFormat.num(gradient.startDevice.x))\" y1=\"\(SVGFormat.num(gradient.startDevice.y))\" "
        out += "x2=\"\(SVGFormat.num(gradient.endDevice.x))\" y2=\"\(SVGFormat.num(gradient.endDevice.y))\">\n"
        for stop in gradient.stops {
            let offset = SVGFormat.num(min(max(stop.location, 0), 1))
            var line = "      <stop offset=\"\(offset)\" stop-color=\"\(SVGFormat.hex(stop.color))\""
            if stop.color.alpha < 1 { line += " stop-opacity=\"\(SVGFormat.num(stop.color.alpha))\"" }
            line += "/>\n"
            out += line
        }
        out += "    </linearGradient>\n"
        return out
    }

    private func clipReference(_ clip: ScenePath?) -> String? {
        guard let clip, !clip.isEmpty, SVGGeometry.isFinite(clip) else { return nil }
        if let existing = clips.first(where: { $0.path == clip }) { return "url(#\(existing.id))" }
        let id = "c\(clips.count)"
        clips.append((clip, id))
        defs += "    <clipPath id=\"\(id)\" clipPathUnits=\"userSpaceOnUse\">\n"
        defs += "      <path d=\"\(SVGGeometry.pathData(clip))\"/>\n"
        defs += "    </clipPath>\n"
        return "url(#\(id))"
    }

    // MARK: Text

    private func emitText(_ element: Element) {
        guard let text = element.text, !text.string.isEmpty else { return }
        guard let layout = SVGText.layout(for: element, text: text) else {
            warnings.append(.elementSkipped(elementID: element.id)); return
        }

        var attrs: [String] = []
        if !layout.transform.isEmpty { attrs.append("transform=\"\(layout.transform)\"") }
        attrs.append("x=\"\(layout.x)\"")
        attrs.append("y=\"\(SVGFormat.num(layout.y))\"")
        attrs.append("font-family=\"\(layout.fontFamily)\"")
        attrs.append("font-size=\"\(SVGFormat.num(layout.fontSize))\"")
        if text.bold { attrs.append("font-weight=\"bold\"") }
        if text.italic { attrs.append("font-style=\"italic\"") }
        if let decoration = layout.decoration { attrs.append("text-decoration=\"\(decoration)\"") }
        if let anchor = layout.anchor { attrs.append("text-anchor=\"\(anchor)\"") }
        if let baseline = layout.baseline { attrs.append("dominant-baseline=\"\(baseline)\"") }
        attrs.append("fill=\"\(SVGFormat.hex(text.color))\"")
        if text.color.alpha < 1 { attrs.append("fill-opacity=\"\(SVGFormat.num(text.color.alpha))\"") }
        if element.style.opacity < 1 { attrs.append("opacity=\"\(SVGFormat.num(element.style.opacity))\"") }
        attrs.append("xml:space=\"preserve\"")

        if layout.rotationApproximated { warnings.append(.textRotationApproximated(elementID: element.id)) }
        appendClipped("<text \(attrs.joined(separator: " "))>\(SVGEscape.text(text.string))</text>", clip: element.clipDevice)
    }

    // MARK: Images

    private func emitImage(_ element: Element) {
        guard let image = element.image else { return }
        guard let placement = SVGImage.placement(for: element, image: image) else {
            warnings.append(.elementSkipped(elementID: element.id)); return
        }
        guard let cg = SceneImageCoding.cgImage(for: image), let png = SceneImageCoding.pngData(cg) else {
            warnings.append(.imageDropped(elementID: element.id)); return
        }
        let base64 = png.base64EncodedString()
        guard base64.utf8.count <= Self.maxImageDataBytes else {
            warnings.append(.imageDropped(elementID: element.id)); return
        }

        var attrs = placement.attributes
        attrs.append("preserveAspectRatio=\"none\"")
        // GDI StretchDIBITS is nearest-neighbour (the renderer uses
        // interpolationQuality = .none), so hint the same to SVG renderers.
        attrs.append("image-rendering=\"pixelated\"")
        if element.style.opacity < 1 { attrs.append("opacity=\"\(SVGFormat.num(element.style.opacity))\"") }
        attrs.append("xlink:href=\"data:image/png;base64,\(base64)\"")
        // xlink kept for maximum importer compatibility; href (SVG 2) added too.
        attrs.append("href=\"data:image/png;base64,\(base64)\"")
        appendClipped("<image \(attrs.joined(separator: " "))/>", clip: element.clipDevice)
    }

    // MARK: Rasterised passthrough

    private func emitRasterized(_ element: Element) {
        // A control/comment passthrough (an EMF+ wrapper comment, a private comment)
        // draws nothing — omit it silently. Only passthroughs that stand for real
        // drawing content (a raster op, an unsupported EMF+ record/brush) reach the
        // rasteriser, and a failure there means no drawable op was found, so it is
        // likewise omitted silently (§8: best partial output, never a noise warning).
        guard element.passthroughReason != .comment else { return }
        guard options.rasterizePassthrough else { return }
        if rasterSource == nil {
            // Transparent background: the PNG composites over the vector content
            // already written, so it must carry only the passthrough's own pixels.
            rasterSource = SceneRasterize.Source.make(scene, rasterize: { $0.kind == .passthrough }, transparentBackground: true)
        }
        guard case let source?? = rasterSource,
              let raster = SceneRasterize.raster(element, scene: scene, source: source),
              let png = SceneImageCoding.pngData(raster.image),
              let rect = SVGFormat.finiteRect(raster.deviceRect), rect.width > 0, rect.height > 0 else {
            return
        }
        let base64 = png.base64EncodedString()
        guard base64.utf8.count <= Self.maxImageDataBytes else { return }
        var attrs: [String] = []
        attrs.append("x=\"\(SVGFormat.num(rect.minX))\"")
        attrs.append("y=\"\(SVGFormat.num(rect.minY))\"")
        attrs.append("width=\"\(SVGFormat.num(rect.width))\"")
        attrs.append("height=\"\(SVGFormat.num(rect.height))\"")
        attrs.append("preserveAspectRatio=\"none\"")
        attrs.append("image-rendering=\"pixelated\"")
        attrs.append("xlink:href=\"data:image/png;base64,\(base64)\"")
        attrs.append("href=\"data:image/png;base64,\(base64)\"")
        appendClipped("<image \(attrs.joined(separator: " "))/>", clip: element.clipDevice)
        warnings.append(.contentRasterized(elementID: element.id))
    }

    // MARK: Append with budget

    /// Appends one element, wrapping it in an UNTRANSFORMED `<g clip-path>` when it
    /// has a clip. A clip must never sit on the element itself: a text or
    /// parallelogram-image element carries its own `transform`, and SVG applies that
    /// transform to a `clip-path` on the same element too — scaling the device-space
    /// clip away. The group carries the device-space clip; the child keeps its own
    /// transform.
    private func appendClipped(_ innerTag: String, clip: ScenePath?) {
        guard !truncated else { return }
        if let clipRef = clipReference(clip) {
            body += "  <g clip-path=\"\(clipRef)\">\(innerTag)</g>\n"
        } else {
            body += "  \(innerTag)\n"
        }
    }

    private func append(_ fragment: String) {
        guard !truncated else { return }
        body += fragment
    }
}
