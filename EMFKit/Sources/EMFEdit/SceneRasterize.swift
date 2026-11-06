import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// Cross-format rasterisation (slice E1b2c2). A GDI/WMF container cannot
/// re-synthesise some content a source metafile drew — a passthrough/unsupported
/// EMF+ record, a WMF raster/ROP blit, a non-Latin-1 text run (WMF strings are
/// 8-bit), an EMF+ text run (sized by an em size GDI/WMF has no field for), or a
/// rotated image. Rather than DROP it, the exporter draws that element ALONE into
/// a bitmap at its device bounds (through the one interpreter — EMFRender's replay
/// or the EMF+ per-record filter, exactly as `SceneRenderer` does) and emits it as
/// an image record (EMR_STRETCHDIBITS / META_STRETCHDIB). The result still looks
/// right at the cost of editability and a resample.
///
/// The source is observed ONCE per export (`Source.make`) and reused for every
/// rasterised element, so a file with many elements pays the observation cost once.
enum SceneRasterize {

    /// Oversample factor: render a device unit to this many bitmap pixels so the
    /// bitmap stays sharp when a reader later resamples it at a higher zoom.
    private static let oversample: CGFloat = 2
    /// Hard caps on one rasterised bitmap (§8: a hostile element must not exhaust
    /// memory). Longest side and total pixel area; a larger element is rendered at
    /// a lower effective resolution (still bounded), never refused for size.
    private static let maxSide = 8192
    private static let maxArea = 4_000_000

    /// A rasterised element: the pixels and the DEVICE-space rectangle they cover.
    struct Raster { let image: CGImage; let deviceRect: CGRect }

    /// A once-per-export source observation: the prepared metafile plus the lifted
    /// ops (GDI/WMF keyed by draw-moment record) and EMF+ entries, so a rasterised
    /// element is replayed from its ORIGINAL op without a second interpretation.
    struct Source {
        let prepared: MetafileRenderer.Prepared
        let renderPath: RenderPathTaken
        let gdiOpsByKey: [Int: ResolvedDrawOp]
        let plusEntries: [PlusEntry]

        /// Observes `scene`'s source once. Nil when the source cannot be opened or
        /// prepared (the caller then drops the element rather than rasterising).
        static func make(_ scene: Scene) -> Source? {
            guard let opened = try? OpenedMetafile.open(scene.source.data),
                  let prepared = MetafileRenderer.prepare(opened) else { return nil }
            let observation = MetafileRenderer.observe(prepared)
            var ops: [Int: ResolvedDrawOp] = [:]
            for op in observation.ops where observation.renderPath != .emfPlus {
                if let key = op.recordIndices.max() { ops[key] = op }
            }
            return Source(prepared: prepared, renderPath: observation.renderPath,
                          gdiOpsByKey: ops, plusEntries: observation.plusEntries)
        }
    }

    /// How one element is replayed into the bitmap.
    private enum Located {
        case gdi(ResolvedDrawOp)
        case plus(streamIndex: Int)
    }

    /// Renders `element` alone into a white-backed bitmap sized to its device
    /// bounds, returning the pixels and the device rect. Nil when the element has
    /// no drawable op, zero/degenerate device area, or the bitmap cannot be built —
    /// the caller then reports `contentDropped` instead of `contentRasterized`.
    ///
    /// A text element's device geometry is only the EmrText clip rectangle, which
    /// GDI leaves empty for an unclipped run, so its bounds are ESTIMATED from the
    /// run's metrics (reference, advances, height, alignment) and the result is
    /// INK-CROPPED to the drawn glyphs — a text page is white, so trimming to the
    /// non-white bounding box both tightens the image and keeps the opaque blit
    /// from erasing the background around the glyphs.
    static func raster(_ element: Element, scene: Scene, source: Source) -> Raster? {
        guard let located = locate(element, source) else { return nil }
        // A text run with no clip rectangle has no device geometry, so its bounds are
        // ESTIMATED and the render ink-cropped. A run WITH geometry (an EMF+ layout
        // rect) is drawn to its exact bounds, no crop — ink-cropping it shifted the
        // resample and lost fidelity.
        let estimated = element.kind == .text && !isUsable(element.boundsDevice)
        var rect = element.boundsDevice
        if estimated { rect = estimatedTextBounds(element) ?? rect }
        guard isUsable(rect) else { return nil }
        // Two device pixels of margin so antialiased edges are not clipped.
        rect = rect.insetBy(dx: -2, dy: -2)
        let (width, height) = bitmapSize(rect)
        guard width >= 1, height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // White background: STRETCHDIBITS/STRETCHDIB blit opaque (BI_RGB has no
        // alpha), so the element is composited over the page's white, matching how
        // a reader shows it; transparent corners of a rotated image stay white.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let base = deviceToTarget(deviceRect: rect, target: target)
        switch located {
        case .gdi(let op):
            EMFRenderer.replay(op, into: context, deviceToTarget: base)
        case .plus(let streamIndex):
            // replayEMFPlus fits the WHOLE page into its `target`; choose the target
            // that makes its internal device→target fit equal `base`, so only this
            // element's device sub-rect fills the bitmap.
            let pageTarget = emfPlusPageTarget(deviceRect: rect, page: scene.pageBoundsDevice, base: base)
            MetafileRenderer.replayEMFPlus(source.prepared, streamIndices: [streamIndex], into: context, target: pageTarget)
        }
        if estimated {
            // Trim to the glyphs: an empty crop means the run drew nothing. The
            // context buffer is TOP-DOWN (memory row 0 is the image's top scan-line,
            // the same order as the CGImage and the STRETCHDIB top-down DIB), and
            // `rect` maps linearly onto the whole bitmap, so a bitmap pixel box maps
            // to device by the per-axis scale — device minY is the top row, matching
            // the top-down DIB the blit places at the destination top.
            guard let ink = inkBounds(context, width: width, height: height) else { return nil }
            let cropImage = CGRect(x: ink.minX, y: ink.minY,
                                   width: ink.maxX - ink.minX + 1, height: ink.maxY - ink.minY + 1)
            let fx = rect.width / Double(width), fy = rect.height / Double(height)
            let deviceCrop = CGRect(
                x: rect.minX + Double(ink.minX) * fx, y: rect.minY + Double(ink.minY) * fy,
                width: Double(ink.maxX - ink.minX + 1) * fx, height: Double(ink.maxY - ink.minY + 1) * fy)
            guard let image = context.makeImage()?.cropping(to: cropImage) else { return nil }
            return Raster(image: image, deviceRect: deviceCrop)
        }
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, deviceRect: rect)
    }

    // MARK: - Element → op mapping

    private static func locate(_ element: Element, _ source: Source) -> Located? {
        if source.renderPath == .emfPlus {
            guard element.id >= 0, element.id < source.plusEntries.count else { return nil }
            switch source.plusEntries[element.id] {
            case .gdi(let op): return .gdi(op)
            case .plus(let op): return .plus(streamIndex: op.streamIndex)
            }
        }
        guard let key = element.provenance.sourceRecordIndices.max(),
              let op = source.gdiOpsByKey[key] else { return nil }
        return .gdi(op)
    }

    // MARK: - Text bounds (estimate + ink crop)

    /// A generous device bounding box for a text run from its metrics, used when the
    /// run carries no clip rectangle (the usual GDI case). The box is in the run's
    /// PRE-transform (logical/world) space then mapped by `element.transform`: the
    /// reference anchors it per the text-alignment flags ([MS-EMF] §2.3.11.25), the
    /// width is the advance sum (or an em-based estimate), the height spans an em
    /// with ascent/descent headroom. Deliberately loose — `raster` ink-crops the
    /// result, so over-estimating costs nothing but under-estimating would clip.
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

        // Horizontal anchor from the alignment flags (reliable, lifted from
        // SETTEXTALIGN); vertical is anchor-AGNOSTIC — a generous 2.8-em band around
        // the reference covers TA_TOP, TA_BASELINE and TA_BOTTOM alike, and the ink
        // crop trims it, so the box never has to guess the vertical anchor.
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
    /// at the bottom), or nil when every pixel is white (the run drew nothing). A
    /// channel below 245 counts as ink, catching antialiased glyph edges.
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

    private static func isUsable(_ r: CGRect) -> Bool {
        isFinite(r) && !r.isNull && r.width >= 0.5 && r.height >= 0.5
    }

    // MARK: - Transforms

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

    /// The `target` rect to hand `replayEMFPlus` so its own page→target fit equals
    /// `base` (device→bitmap). `replayEMFPlus` fits the file's whole device page
    /// `page` into `target`; solving `deviceToTarget(page, target) == base` for
    /// `target` crops the output to the element's device sub-rect.
    private static func emfPlusPageTarget(deviceRect: CGRect, page: CGRect, base: CGAffineTransform) -> CGRect {
        let pw = max(page.width, 1), ph = max(page.height, 1)
        let sx = base.a, sy = -base.d      // base.d is negative (the y-flip)
        let width = sx * pw, height = sy * ph
        // base.tx = target.minX - sx*page.minX  →  minX = base.tx + sx*page.minX
        let minX = base.tx + sx * page.minX
        // base.ty = target.maxY + sy*page.minY  →  maxY = base.ty - sy*page.minY
        let maxY = base.ty - sy * page.minY
        return CGRect(x: minX, y: maxY - height, width: width, height: height)
    }

    // MARK: - Sizing

    private static func bitmapSize(_ rect: CGRect) -> (Int, Int) {
        var w = Double(max(1, rect.width * oversample))
        var h = Double(max(1, rect.height * oversample))
        if w * h > Double(maxArea) {
            let s = (Double(maxArea) / (w * h)).squareRoot()
            w *= s; h *= s
        }
        let width = min(maxSide, max(1, Int(w.rounded())))
        let height = min(maxSide, max(1, Int(h.rounded())))
        return (width, height)
    }

    private static func isFinite(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite
    }
}
