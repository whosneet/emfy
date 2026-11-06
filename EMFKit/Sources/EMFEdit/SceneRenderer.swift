import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation

/// A simple renderer that draws a `Scene` into a `CGContext` — the fidelity
/// proof for the import lift (E1a gate). Editable geometry elements are drawn
/// from their VALUE-TYPE geometry and style (so a passing render proves the lift
/// captured the drawing), reproducing EMFRender's fill/stroke exactly. Text,
/// image and passthrough elements are drawn by replaying their original draw
/// through EMFRender (their editable CONTENT is asserted separately), because
/// reproducing text layout and bitmap sampling from scratch is outside E1a.
///
/// An EMF+ scene (the whole file is one passthrough) is reproduced by replaying
/// the source through `MetafileRenderer`.
public enum SceneRenderer {

    /// Renders `scene` into a fresh sRGB bitmap sized from the page (× `scale`),
    /// on white, matching `MetafileRenderer.makeImage`'s sizing. Returns `nil`
    /// only on a bitmap allocation failure.
    public static func makeImage(_ scene: Scene, scale: CGFloat = 1) -> CGImage? {
        let safeScale = scale.isFinite && scale > 0 ? Double(scale) : 1
        let width = clampDimension(scene.pageSizeDevice.width * safeScale)
        let height = clampDimension(scene.pageSizeDevice.height * safeScale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        render(scene, into: context, target: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Draws `scene` into `context`, mapping its device space onto `target`.
    public static func render(_ scene: Scene, into context: CGContext, target: CGRect) {
        let base = deviceToTarget(pageBounds: scene.pageBoundsDevice, target: target)

        // EMF+ content lifts into editable elements (slice E1a2): geometry draws
        // from its value types; text/image/passthrough replay through the one
        // interpreter, preserving z-order.
        if scene.source.renderPath == .emfPlus {
            renderEMFPlus(scene, into: context, target: target, base: base)
            return
        }

        // Ops for the replay elements (text/image/passthrough), re-derived from
        // the source and keyed by their draw-moment record (max provenance).
        let replayOps = needsReplay(scene) ? opsByDrawKey(scene) : [:]

        context.saveGState()
        defer { context.restoreGState() }

        for element in scene.elements where !element.hidden {
            // An edited or new (no-provenance) element reflects its edit by
            // rendering the SAME records the exporter writes (so the on-screen
            // edit matches the exported file exactly); an unedited element draws
            // from its value types (geometry) or replays its original op
            // (text/image/passthrough) for lift fidelity.
            let isEdit = element.provenance.edited || element.provenance.sourceRecordIndices.isEmpty
            switch element.kind {
            case .text, .image:
                if isEdit {
                    renderSynthesized(element, into: context, pageBounds: scene.pageBoundsDevice, target: target, base: base)
                } else {
                    let key = element.provenance.sourceRecordIndices.max() ?? -1
                    if let op = replayOps[key] { EMFRenderer.replay(op, into: context, deviceToTarget: base) }
                }
            case .passthrough:
                let key = element.provenance.sourceRecordIndices.max() ?? -1
                if let op = replayOps[key] { EMFRenderer.replay(op, into: context, deviceToTarget: base) }
            default:
                if isEdit {
                    renderSynthesized(element, into: context, pageBounds: scene.pageBoundsDevice, target: target, base: base)
                } else {
                    drawGeometry(element, into: context, base: base)
                }
            }
        }
    }

    /// Renders one edited/new element by synthesising its device-space EMR block
    /// (exactly what the exporter writes) into a throwaway single-element EMF and
    /// playing that into `context` at the current z-moment, so the on-screen edit
    /// matches the exported file. The element's clip is applied around it (the
    /// exporter instead relies on the overlay's inherited clip, which the import
    /// captured as this element's clip). A no-op if the element draws nothing.
    private static func renderSynthesized(_ element: Element, into context: CGContext, pageBounds: CGRect, target: CGRect, base: CGAffineTransform) {
        var warnings: [ExportWarning] = []
        let payloads = SceneSynthesis.emfBlock(for: element, baseHandle: 1, warnings: &warnings)
        guard !payloads.isEmpty else { return }
        let left = Int32(pageBounds.minX.rounded())
        let top = Int32(pageBounds.minY.rounded())
        let right = left &+ Int32(max(1, pageBounds.width.rounded())) &- 1
        let bottom = top &+ Int32(max(1, pageBounds.height.rounded())) &- 1
        let bounds = RectL(left: left, top: top, right: right, bottom: bottom)
        let builder = EMFDocumentBuilder(bounds: bounds, frame: bounds, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        do {
            for payload in payloads { try builder.append(payload) }
            let data = try builder.finish()
            guard let file = try? EMFFile.parse(data) else { return }
            context.saveGState()
            applyClip(element.clipDevice, base: base, into: context)
            _ = EMFRenderer.render(file, into: context, target: target)
            context.restoreGState()
        } catch {
            return
        }
    }

    /// Renders an EMF+ scene: each element draws from its value types (geometry,
    /// solid and linear-gradient fills with alpha, strokes) or, for text/image/
    /// passthrough, replays its single source record so z-order is preserved. The
    /// source is re-observed once to recover each element's lifted op (the scene
    /// elements are 1:1 with `plusEntries`, in order) — the proof the lift
    /// captured what was drawn.
    private static func renderEMFPlus(_ scene: Scene, into context: CGContext, target: CGRect, base: CGAffineTransform) {
        guard let prepared = prepareSource(scene) else { return }
        let entries = MetafileRenderer.observe(prepared).plusEntries

        context.saveGState()
        defer { context.restoreGState() }

        for (element, entry) in zip(scene.elements, entries) where !element.hidden {
            switch element.kind {
            case .text, .image, .passthrough:
                switch entry {
                case .gdi(let op):
                    EMFRenderer.replay(op, into: context, deviceToTarget: base)
                case .plus(let op):
                    MetafileRenderer.replayEMFPlus(prepared, streamIndices: [op.streamIndex], into: context, target: target)
                }
            default:
                drawGeometry(element, into: context, base: base)
            }
        }
    }

    // MARK: - Geometry (value-type render)

    private static func drawGeometry(_ element: Element, into context: CGContext, base: CGAffineTransform) {
        let targetPath = CGMutablePath()
        targetPath.addPath(element.geometryDevice.cgPath, transform: base)
        guard !targetPath.isEmpty else { return }
        let full = element.transform.concatenating(base)

        if let fill = element.style.fill {
            context.saveGState()
            applyClip(element.clipDevice, base: base, into: context)
            if let gradient = fill.gradient {
                drawGradient(gradient, path: targetPath, evenOdd: fill.evenOdd, base: base, into: context)
            } else {
                context.setFillColor(fill.color.cgColor)
                context.addPath(targetPath)
                context.fillPath(using: fill.evenOdd ? .evenOdd : .winding)
            }
            context.restoreGState()
        }
        if let stroke = element.style.stroke {
            context.saveGState()
            applyClip(element.clipDevice, base: base, into: context)
            let params = deviceStroke(stroke, logicalToTarget: full, deviceToTarget: base)
            context.setStrokeColor(stroke.color.cgColor)
            context.setLineWidth(params.width)
            context.setLineCap(stroke.cap)
            context.setLineJoin(stroke.join)
            context.setMiterLimit(max(1, CGFloat(stroke.miterLimit)))
            context.setLineDash(phase: 0, lengths: params.dash)
            context.addPath(targetPath)
            context.strokePath()
            context.restoreGState()
        }
    }

    /// Clips to `targetPath` and draws an EMF+ linear gradient, matching
    /// `EMFPlusPlayback.fillBrush`: clamp both ends (`drawsBefore/AfterEndLocation`)
    /// and map the device-space axis to target space via `base`. A degenerate
    /// gradient (fewer than two stops) falls back to the first stop's solid.
    private static func drawGradient(_ gradient: SceneGradient, path targetPath: CGPath, evenOdd: Bool, base: CGAffineTransform, into context: CGContext) {
        guard gradient.stops.count >= 2, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            if let first = gradient.stops.first {
                context.setFillColor(first.color.cgColor)
                context.addPath(targetPath)
                context.fillPath(using: evenOdd ? .evenOdd : .winding)
            }
            return
        }
        let colors = gradient.stops.map(\.color.cgColor) as CFArray
        let locations = gradient.stops.map { CGFloat(min(max($0.location, 0), 1)) }
        guard let cgGradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        context.addPath(targetPath)
        context.clip(using: evenOdd ? .evenOdd : .winding)
        context.drawLinearGradient(
            cgGradient,
            start: gradient.startDevice.applying(base),
            end: gradient.endDevice.applying(base),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func applyClip(_ clip: ScenePath?, base: CGAffineTransform, into context: CGContext) {
        guard let clip, !clip.isEmpty else { return }
        let path = CGMutablePath()
        path.addPath(clip.cgPath, transform: base)
        if path.isEmpty {
            context.clip(to: .zero)
        } else {
            context.addPath(path)
            context.clip()
        }
    }

    /// Mirrors `StrokeMapper.deviceStroke` so a value-type geometry render
    /// matches EMFRender's stroke exactly (same width/dash derivation).
    private static func deviceStroke(
        _ stroke: SceneStroke, logicalToTarget: CGAffineTransform, deviceToTarget: CGAffineTransform
    ) -> (width: CGFloat, dash: [CGFloat]) {
        let unitScale: CGFloat
        let width: CGFloat
        if stroke.isCosmetic {
            unitScale = averageScale(deviceToTarget)
            width = unitScale
        } else {
            unitScale = averageScale(logicalToTarget)
            width = CGFloat(stroke.width) * unitScale
        }
        let dashBasis = max(width, 1)
        let dash: [CGFloat]
        switch stroke.dash {
        case .solid: dash = []
        case .dash: dash = [3, 1].map { $0 * dashBasis }
        case .dot: dash = [1, 1].map { $0 * dashBasis }
        case .dashDot: dash = [3, 1, 1, 1].map { $0 * dashBasis }
        case .dashDotDot: dash = [3, 1, 1, 1, 1, 1].map { $0 * dashBasis }
        case .userStyle(let entries):
            let scaled = entries.map { CGFloat($0) * unitScale }
            dash = scaled.contains(where: { $0 > 0 }) ? scaled : []
        }
        return (width, dash)
    }

    private static func averageScale(_ t: CGAffineTransform) -> CGFloat {
        let sx = (t.a * t.a + t.b * t.b).squareRoot()
        let sy = (t.c * t.c + t.d * t.d).squareRoot()
        return (sx + sy) / 2
    }

    // MARK: - Replay support

    private static func needsReplay(_ scene: Scene) -> Bool {
        scene.elements.contains { $0.kind == .text || $0.kind == .image || $0.kind == .passthrough }
    }

    /// Re-observes the source and keys each op by its draw-moment record index
    /// (max provenance), the same key the import uses for z-order.
    private static func opsByDrawKey(_ scene: Scene) -> [Int: ResolvedDrawOp] {
        guard let prepared = prepareSource(scene) else { return [:] }
        let observation = MetafileRenderer.observe(prepared)
        var map: [Int: ResolvedDrawOp] = [:]
        for op in observation.ops {
            if let key = op.recordIndices.max() { map[key] = op }
        }
        return map
    }

    private static func prepareSource(_ scene: Scene) -> MetafileRenderer.Prepared? {
        guard let opened = try? OpenedMetafile.open(scene.source.data) else { return nil }
        return MetafileRenderer.prepare(opened)
    }

    // MARK: - Device→target fit (mirrors EMFRenderer.deviceToTarget)

    private static func deviceToTarget(pageBounds: CGRect, target: CGRect) -> CGAffineTransform {
        let deviceWidth = max(pageBounds.width, 1)
        let deviceHeight = max(pageBounds.height, 1)
        let sx = target.width / deviceWidth
        let sy = target.height / deviceHeight
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: -sy,
            tx: target.minX - sx * pageBounds.minX,
            ty: target.maxY + sy * pageBounds.minY
        )
    }

    private static func clampDimension(_ requested: Double) -> Int {
        let cap = Double(EMFRenderer.canvasDimensionCap)
        guard requested.isFinite else { return EMFRenderer.canvasDimensionCap }
        let rounded = requested.rounded()
        if rounded < 1 { return 1 }
        if rounded > cap { return EMFRenderer.canvasDimensionCap }
        return Int(rounded)
    }
}
