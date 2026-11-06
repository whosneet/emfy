import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// Cross-format rasterisation (slice E1b2c2). A GDI/WMF container cannot
/// re-synthesise some content a source metafile drew — a passthrough/unsupported
/// EMF+ record, a WMF raster/ROP blit, a non-Latin-1 text run (WMF strings are
/// 8-bit), an EMF+ text run (sized by an em size GDI/WMF has no field for), or a
/// rotated image. Rather than DROP it, the exporter draws that element into a
/// bitmap (through the one interpreter — EMFRender's replay) and emits it as an
/// image record (EMR_STRETCHDIBITS / META_STRETCHDIB). The result still looks right
/// at the cost of editability and a resample.
///
/// The source is observed ONCE per export (`Source.make`). A GDI element replays
/// its single op into a bitmap sized to its bounds. An EMF+ element cannot be
/// replayed one at a time cheaply — `replayEMFPlus` re-runs the WHOLE stream per
/// call, so N elements would be O(N·stream) — so ALL rasterised EMF+ elements are
/// drawn in ONE page replay up front and each element is CROPPED from that page.
enum SceneRasterize {

    /// Oversample factor: render a device unit to this many bitmap pixels so the
    /// bitmap stays sharp when a reader later resamples it at a higher zoom.
    private static let oversample = 2.0
    /// Hard caps on one rasterised bitmap (§8: a hostile element must not exhaust
    /// memory). Longest side and total pixel area; a larger element is rendered at
    /// a lower effective resolution (still bounded), never refused for size.
    private static let maxSide = 8192
    private static let maxArea = 4_000_000

    /// A rasterised element: the pixels and the DEVICE-space rectangle they cover.
    struct Raster { let image: CGImage; let deviceRect: CGRect }

    /// A single page render of every rasterised EMF+ element, drawn in ONE
    /// `replayEMFPlus` pass (so the cost is O(stream), not O(N·stream)). Elements
    /// are cropped from it by their device bounds.
    struct PlusPage { let image: CGImage; let pageRect: CGRect; let width: Int; let height: Int }

    /// A once-per-export source observation: the prepared metafile, the lifted ops
    /// (GDI/WMF keyed by draw-moment record) and EMF+ entries, and — for an EMF+
    /// source — the batched page render of the elements to rasterise.
    struct Source {
        let prepared: MetafileRenderer.Prepared
        let renderPath: RenderPathTaken
        let gdiOpsByKey: [Int: ResolvedDrawOp]
        let plusEntries: [PlusEntry]
        let plusPage: PlusPage?

        /// Observes `scene`'s source once. Nil when the source cannot be opened or
        /// prepared (the caller then drops the element rather than rasterising).
        static func make(_ scene: Scene) -> Source? {
            guard let opened = try? OpenedMetafile.open(scene.source.data),
                  let prepared = MetafileRenderer.prepare(opened) else { return nil }
            let observation = MetafileRenderer.observe(prepared)
            var ops: [Int: ResolvedDrawOp] = [:]
            if observation.renderPath != .emfPlus {
                for op in observation.ops { if let key = op.recordIndices.max() { ops[key] = op } }
            }
            var plusPage: PlusPage?
            if observation.renderPath == .emfPlus {
                var indices = Set<Int>()
                for element in scene.elements where SceneExporter.shouldRasterize(element) {
                    if element.id >= 0, element.id < observation.plusEntries.count,
                       case .plus(let op) = observation.plusEntries[element.id] { indices.insert(op.streamIndex) }
                }
                if !indices.isEmpty { plusPage = renderPlusPage(prepared, page: scene.pageBoundsDevice, streamIndices: indices) }
            }
            return Source(prepared: prepared, renderPath: observation.renderPath,
                          gdiOpsByKey: ops, plusEntries: observation.plusEntries, plusPage: plusPage)
        }
    }

    private enum Located {
        case gdi(ResolvedDrawOp)
        case plus
    }

    /// The pixels and device rect for `element`, or nil when it has no drawable op,
    /// zero/degenerate device area, or the bitmap cannot be built — the caller then
    /// reports `contentDropped` instead of `contentRasterized`.
    static func raster(_ element: Element, scene: Scene, source: Source) -> Raster? {
        switch locate(element, source) {
        case .gdi(let op)?: return rasterGDI(element, op: op)
        case .plus?: return rasterPlus(element, source: source)
        case nil: return nil
        }
    }

    private static func locate(_ element: Element, _ source: Source) -> Located? {
        if source.renderPath == .emfPlus {
            guard element.id >= 0, element.id < source.plusEntries.count else { return nil }
            switch source.plusEntries[element.id] {
            case .gdi(let op): return .gdi(op)
            case .plus: return .plus
            }
        }
        guard let key = element.provenance.sourceRecordIndices.max(),
              let op = source.gdiOpsByKey[key] else { return nil }
        return .gdi(op)
    }

    // MARK: - GDI element: replay its single op into its own bitmap

    /// Replays one GDI op into a white-backed bitmap at its device bounds. A text
    /// run with no clip rectangle has no device geometry, so its bounds are
    /// ESTIMATED and the render INK-CROPPED to the drawn glyphs — a text page is
    /// white, so trimming to the non-white box both tightens the image and keeps the
    /// opaque blit from erasing the background around the glyphs.
    private static func rasterGDI(_ element: Element, op: ResolvedDrawOp) -> Raster? {
        let estimated = element.kind == .text && !isUsable(element.boundsDevice)
        var rect = element.boundsDevice
        if estimated { rect = estimatedTextBounds(element) ?? rect }
        guard isUsable(rect) else { return nil }
        rect = rect.insetBy(dx: -2, dy: -2)
        let (width, height) = bitmapSize(rect)
        guard let context = whiteContext(width, height) else { return nil }
        EMFRenderer.replay(op, into: context, deviceToTarget: deviceToTarget(deviceRect: rect, target: CGRect(x: 0, y: 0, width: width, height: height)))
        if estimated {
            guard let ink = inkBounds(context, width: width, height: height) else { return nil }
            let fx = rect.width / Double(width), fy = rect.height / Double(height)
            let crop = CGRect(x: ink.minX, y: ink.minY, width: ink.maxX - ink.minX + 1, height: ink.maxY - ink.minY + 1)
            let deviceRect = CGRect(x: rect.minX + Double(ink.minX) * fx, y: rect.minY + Double(ink.minY) * fy,
                                    width: Double(ink.maxX - ink.minX + 1) * fx, height: Double(ink.maxY - ink.minY + 1) * fy)
            guard let image = context.makeImage()?.cropping(to: crop) else { return nil }
            return Raster(image: image, deviceRect: deviceRect)
        }
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, deviceRect: rect)
    }

    // MARK: - EMF+ element: crop from the batched page render

    private static func rasterPlus(_ element: Element, source: Source) -> Raster? {
        guard let page = source.plusPage else { return nil }
        var rect = element.boundsDevice
        if element.kind == .text, !isUsable(rect) { rect = estimatedTextBounds(element) ?? rect }
        guard isUsable(rect) else { return nil }
        rect = rect.insetBy(dx: -1, dy: -1)
        // device rect → page-bitmap pixels (top-down: device minY is row 0).
        let fx = Double(page.width) / Double(page.pageRect.width), fy = Double(page.height) / Double(page.pageRect.height)
        guard fx.isFinite, fy.isFinite else { return nil }
        let cx = clampInt(((Double(rect.minX) - Double(page.pageRect.minX)) * fx).rounded(.down), 0, page.width - 1)
        let cy = clampInt(((Double(rect.minY) - Double(page.pageRect.minY)) * fy).rounded(.down), 0, page.height - 1)
        let cw = clampInt((Double(rect.width) * fx).rounded(.up), 1, page.width - cx)
        let ch = clampInt((Double(rect.height) * fy).rounded(.up), 1, page.height - cy)
        guard let image = page.image.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else { return nil }
        let deviceRect = CGRect(x: Double(page.pageRect.minX) + Double(cx) / fx, y: Double(page.pageRect.minY) + Double(cy) / fy,
                                width: Double(cw) / fx, height: Double(ch) / fy)
        return Raster(image: image, deviceRect: deviceRect)
    }

    /// Renders every rasterised EMF+ stream index into ONE white-backed page bitmap
    /// via a single `replayEMFPlus` pass (the page maps to the bitmap, so each
    /// element lands where it draws). O(stream), independent of the element count.
    private static func renderPlusPage(_ prepared: MetafileRenderer.Prepared, page: CGRect, streamIndices: Set<Int>) -> PlusPage? {
        let pw = max(1.0, Double(page.width)), ph = max(1.0, Double(page.height))
        var s = oversample
        s = min(s, Double(maxSide) / max(pw, ph))
        if s * s * pw * ph > Double(maxArea) { s = (Double(maxArea) / (pw * ph)).squareRoot() }
        guard s.isFinite, s > 0 else { return nil }
        let width = min(maxSide, max(1, Int((pw * s).rounded())))
        let height = min(maxSide, max(1, Int((ph * s).rounded())))
        guard let context = whiteContext(width, height) else { return nil }
        MetafileRenderer.replayEMFPlus(prepared, streamIndices: streamIndices, into: context, target: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return PlusPage(image: image, pageRect: page, width: width, height: height)
    }

    // MARK: - Text bounds (estimate + ink crop)

    /// A generous device bounding box for a text run from its metrics, used when the
    /// run carries no clip rectangle (the usual GDI case). The box is in the run's
    /// PRE-transform (logical/world) space then mapped by `element.transform`: the
    /// horizontal anchor follows the text-alignment flags ([MS-EMF] §2.3.11.25), the
    /// vertical band is anchor-AGNOSTIC (a 2.8-em band covers TA_TOP/BASELINE/BOTTOM
    /// alike). Deliberately loose — `rasterGDI` ink-crops the result, so
    /// over-estimating costs nothing but under-estimating would clip.
    private static func estimatedTextBounds(_ element: Element) -> CGRect? {
        guard let text = element.text else { return nil }
        let count = text.string.utf16.count
        guard count > 0 else { return nil }
        var em = abs(Double(text.logicalHeight))
        if em < 1 { em = text.emSize > 0 ? text.emSize : 16 }
        let ref = Double(text.referenceLogical.x)
        let refY = Double(text.referenceLogical.y)
        let advanceSum = text.advancesLogical.reduce(0.0) { $0 + Double($1) }
        let width = advanceSum > 0 ? advanceSum : Double(count) * em

        let align = text.alignRawValue
        let x0: Double
        switch align & 0x6 {
        case 0x2: x0 = ref - width        // TA_RIGHT
        case 0x6: x0 = ref - width / 2    // TA_CENTER
        default:  x0 = ref                // TA_LEFT
        }
        let marginX = em
        let box = CGRect(x: x0 - marginX, y: refY - em * 1.4, width: width + 2 * marginX, height: em * 2.8)
        let device = box.applying(element.transform).standardized
        return isUsable(device) ? device : nil
    }

    /// The non-white pixel bounding box of `context`'s bitmap (buffer coords, row 0
    /// the image's TOP scan-line), or nil when every pixel is white. A channel below
    /// 245 counts as ink, catching antialiased glyph edges.
    private static func inkBounds(_ context: CGContext, width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            let row = ptr + y * bytesPerRow
            for x in 0 ..< width {
                let p = row + x * 4
                if p[0] < 245 || p[1] < 245 || p[2] < 245 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        return (maxX >= minX && maxY >= minY) ? (minX, minY, maxX, maxY) : nil
    }

    // MARK: - Bitmap helpers

    /// A white-filled premultiplied-sRGB bitmap context. White background because
    /// STRETCHDIBITS/STRETCHDIB blit opaque (BI_RGB has no alpha): the element is
    /// composited over the page's white, as a reader shows it.
    private static func whiteContext(_ width: Int, _ height: Int) -> CGContext? {
        guard width >= 1, height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// device→bitmap: maps `deviceRect` onto `target` with the single y-flip
    /// (device y-down → CG y-up), mirroring `EMFRenderer.deviceToTarget`.
    private static func deviceToTarget(deviceRect: CGRect, target: CGRect) -> CGAffineTransform {
        let dw = max(deviceRect.width, 1), dh = max(deviceRect.height, 1)
        let sx = target.width / dw, sy = target.height / dh
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: -sy,
            tx: target.minX - sx * deviceRect.minX,
            ty: target.maxY + sy * deviceRect.minY)
    }

    private static func bitmapSize(_ rect: CGRect) -> (Int, Int) {
        var w = max(1.0, Double(rect.width) * oversample)
        var h = max(1.0, Double(rect.height) * oversample)
        if w * h > Double(maxArea) {
            let s = (Double(maxArea) / (w * h)).squareRoot()
            w *= s; h *= s
        }
        return (min(maxSide, max(1, Int(w.rounded()))), min(maxSide, max(1, Int(h.rounded()))))
    }

    private static func isUsable(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite
            && !r.isNull && r.width >= 0.5 && r.height >= 0.5
    }

    private static func clampInt(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
        guard v.isFinite else { return lo }
        return max(lo, min(hi, Int(v)))
    }
}
