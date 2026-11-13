import CoreGraphics
import EMFParse
import Foundation

/// Playback of EMR_GRADIENTFILL ([MS-EMF] §2.3.5.12). RECT_H/RECT_V fills are
/// exact two-colour linear gradients (CGGradient clipped to the rectangle).
/// TRIANGLE fills are a MESH APPROXIMATION of Gouraud shading: the triangle is
/// recursively subdivided in barycentric space and each leaf sub-triangle is
/// flat-filled with its centroid-interpolated colour — CoreGraphics exposes no
/// free-form Gouraud shading to Swift, and the subdivision converges visually
/// while staying bounded (a fixed depth, no hostile blow-up).
enum GradientDrawer {

    /// Recursion depth for the triangle mesh approximation: 5 levels = 4^5 =
    /// 1024 flat sub-triangles per gradient triangle, smooth to the eye and
    /// bounded regardless of file content.
    private static let triangleSubdivisionDepth = 5

    static func draw(
        _ payload: GradientFillPayload,
        into context: CGContext,
        dc: DeviceContext,
        base: CGAffineTransform,
        log: inout EMFRenderLog
    ) {
        // Unknown mode has no defined mesh; log-and-skip (the decoder already
        // produced an empty mesh for it).
        if case .unknown(let raw) = payload.mode {
            log.note(.unknownEnumValue(record: 118, rawValue: raw))
            return
        }

        let full = dc.resolvedTransform.concatenating(base)
        context.saveGState()
        defer { context.restoreGState() }
        dc.state.clip.apply(to: context, deviceToTarget: base)
        // Work in device space so gradients and clips compose with the world/
        // page transform exactly like every other primitive.
        context.concatenate(full)

        switch payload.mesh {
        case .rectangles(let rects):
            let vertical = payload.mode == .rectVertical
            for rect in rects {
                drawRectangle(rect, vertices: payload.vertices, vertical: vertical, into: context)
            }
        case .triangles(let triangles):
            for triangle in triangles {
                drawTriangle(triangle, vertices: payload.vertices, into: context)
            }
        }
    }

    // MARK: - Rectangle gradients

    private static func drawRectangle(
        _ rect: GradientRectangle,
        vertices: [TriVertex],
        vertical: Bool,
        into context: CGContext
    ) {
        guard let ul = vertex(rect.upperLeft, vertices),
              let lr = vertex(rect.lowerRight, vertices) else { return }
        let x0 = CGFloat(min(ul.x, lr.x)), x1 = CGFloat(max(ul.x, lr.x))
        let y0 = CGFloat(min(ul.y, lr.y)), y1 = CGFloat(max(ul.y, lr.y))
        guard x1 > x0, y1 > y0 else { return }
        let box = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

        // Two-stop gradient between the upper-left and lower-right vertex colours
        // ([MS-EMF] §2.3.5.12: RECT_H interpolates along x, RECT_V along y).
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                colorsSpace: space,
                colors: [color(ul), color(lr)] as CFArray,
                locations: [0, 1]
              ) else { return }

        context.saveGState()
        context.addRect(box)
        context.clip()
        let start = vertical ? CGPoint(x: box.minX, y: y0) : CGPoint(x: x0, y: box.minY)
        let end = vertical ? CGPoint(x: box.minX, y: y1) : CGPoint(x: x1, y: box.minY)
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    // MARK: - Triangle gradients (mesh approximation)

    private static func drawTriangle(
        _ tri: GradientTriangle,
        vertices: [TriVertex],
        into context: CGContext
    ) {
        guard let a = vertex(tri.vertex1, vertices),
              let b = vertex(tri.vertex2, vertices),
              let c = vertex(tri.vertex3, vertices) else { return }
        let pa = Corner(point: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)), color: rgba(a))
        let pb = Corner(point: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)), color: rgba(b))
        let pc = Corner(point: CGPoint(x: CGFloat(c.x), y: CGFloat(c.y)), color: rgba(c))
        // Antialiasing OFF for the leaf fills so adjacent flat sub-triangles tile
        // seamlessly instead of leaving a faint AA lattice between them; the
        // outer triangle edge is crisp, which is correct for a gradient region.
        context.saveGState()
        context.setShouldAntialias(false)
        subdivide(pa, pb, pc, depth: triangleSubdivisionDepth, into: context)
        context.restoreGState()
    }

    /// A triangle corner: position + its interpolated colour.
    private struct Corner {
        var point: CGPoint
        var color: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    }

    private static func midpoint(_ p: Corner, _ q: Corner) -> Corner {
        Corner(
            point: CGPoint(x: (p.point.x + q.point.x) / 2, y: (p.point.y + q.point.y) / 2),
            color: (
                (p.color.r + q.color.r) / 2, (p.color.g + q.color.g) / 2,
                (p.color.b + q.color.b) / 2, (p.color.a + q.color.a) / 2
            )
        )
    }

    private static func subdivide(_ a: Corner, _ b: Corner, _ c: Corner, depth: Int, into context: CGContext) {
        if depth == 0 {
            // Flat-fill this leaf with the centroid-averaged colour.
            let r = (a.color.r + b.color.r + c.color.r) / 3
            let g = (a.color.g + b.color.g + c.color.g) / 3
            let bl = (a.color.b + b.color.b + c.color.b) / 3
            let al = (a.color.a + b.color.a + c.color.a) / 3
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: bl, alpha: al))
            context.beginPath()
            context.move(to: a.point)
            context.addLine(to: b.point)
            context.addLine(to: c.point)
            context.closePath()
            context.fillPath()
            return
        }
        // Split into four sub-triangles on the edge midpoints.
        let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
        subdivide(a, ab, ca, depth: depth - 1, into: context)
        subdivide(ab, b, bc, depth: depth - 1, into: context)
        subdivide(ca, bc, c, depth: depth - 1, into: context)
        subdivide(ab, bc, ca, depth: depth - 1, into: context)
    }

    // MARK: - Helpers

    private static func vertex(_ index: UInt32, _ vertices: [TriVertex]) -> TriVertex? {
        let i = Int(index)
        return i < vertices.count ? vertices[i] : nil
    }

    /// A TriVertex's colour as a CGColor. GDI stores each channel 16-bit with
    /// the significant value in the high byte, so an 8-bit channel is the high
    /// byte ([MS-EMF] §2.2.26).
    private static func color(_ v: TriVertex) -> CGColor {
        let c = rgba(v)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    private static func rgba(_ v: TriVertex) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        // GDI's GradientFill is OPAQUE — the TriVertex Alpha is not used for a
        // plain EMR_GRADIENTFILL ([MS-EMF] §2.2.26, SHOULD be 0), so a blend is
        // forced to alpha 1 rather than taking the (usually zero) vertex alpha,
        // which would otherwise erase the fill.
        (
            CGFloat(v.red >> 8) / 255,
            CGFloat(v.green >> 8) / 255,
            CGFloat(v.blue >> 8) / 255,
            1
        )
    }
}
