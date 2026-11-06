import CoreGraphics
import EMFParse
import EMFRender
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

        // EMF+ content is one passthrough blob: reproduce it by replaying the
        // whole source through the one interpreter.
        if scene.source.renderPath == .emfPlus {
            replaySourceWholeFile(scene, into: context, target: target)
            return
        }

        // Ops for the replay elements (text/image/passthrough), re-derived from
        // the source and keyed by their draw-moment record (max provenance).
        let replayOps = needsReplay(scene) ? opsByDrawKey(scene) : [:]

        context.saveGState()
        defer { context.restoreGState() }

        for element in scene.elements where !element.hidden {
            switch element.kind {
            case .text, .image, .passthrough:
                let key = element.provenance.sourceRecordIndices.max() ?? -1
                if let op = replayOps[key] {
                    EMFRenderer.replay(op, into: context, deviceToTarget: base)
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
            context.setFillColor(fill.color.cgColor)
            context.addPath(targetPath)
            context.fillPath(using: fill.evenOdd ? .evenOdd : .winding)
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

    private static func replaySourceWholeFile(_ scene: Scene, into context: CGContext, target: CGRect) {
        guard let prepared = prepareSource(scene) else { return }
        _ = MetafileRenderer.render(prepared, into: context, target: target)
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
