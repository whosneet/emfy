import CoreGraphics
import EMFParse
import Foundation

/// Resolved CG stroke parameters for an EMF+ pen, in target (canvas) units.
struct PlusStrokeStyle {
    var color: CGColor
    var width: CGFloat
    var cap: CGLineCap
    var join: CGLineJoin
    var miterLimit: CGFloat
    /// Dash segment lengths in target units; empty means a solid line.
    var dash: [CGFloat]
    var dashPhase: CGFloat
}

/// EMF+ brush/pen → CoreGraphics translation (P3 fidelity policy, primer §8).
/// Solid colours and linear gradients render faithfully; hatch, path-gradient,
/// texture, and non-solid pen brushes are approximated with a logged note.
enum EMFPlusPaint {

    private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

    // MARK: - Fill colour resolution

    /// The single representative solid colour for a brush — the fill a viewer
    /// gets when the full brush is not (yet) rendered: the solid colour, a
    /// gradient's start colour, a hatch's foreground, or a path gradient's
    /// centre. Nil for a texture brush (no representative colour).
    static func representativeColor(_ brush: EMFPlusBrush) -> EMFPlusARGB? {
        switch brush.data {
        case .solid(let c): return c
        case .hatch(_, let fore, _): return fore
        case .linearGradient(let g): return g.startColor
        case .pathGradient(let g): return g.centerColor
        case .texture: return nil
        }
    }

    // MARK: - Linear gradients

    /// Builds a CGGradient for an EmfPlusLinearGradientBrushData ([MS-EMFPLUS]
    /// §2.2.2.24/§2.2.2.25). Preset colours become stops directly; blend
    /// factors interpolate start→end at each position; a plain two-colour
    /// gradient is start@0 → end@1.
    static func linearGradient(_ g: EMFPlusLinearGradientBrush) -> CGGradient? {
        var stops: [(CGFloat, CGColor)] = []
        switch g.blend {
        case .presetColors(let preset):
            for (pos, color) in zip(preset.positions, preset.colors) {
                stops.append((CGFloat(pos), EMFPlusGeometry.cgColor(color)))
            }
        case .blendFactors(let arrays):
            if let factors = arrays.first, !factors.positions.isEmpty {
                for (pos, factor) in zip(factors.positions, factors.factors) {
                    stops.append((CGFloat(pos), lerp(g.startColor, g.endColor, CGFloat(factor))))
                }
            }
        case nil:
            break
        }
        if stops.count < 2 {
            stops = [(0, EMFPlusGeometry.cgColor(g.startColor)), (1, EMFPlusGeometry.cgColor(g.endColor))]
        }
        // Locations MUST be non-decreasing in [0, 1] for CGGradient.
        stops.sort { $0.0 < $1.0 }
        let locations = stops.map { min(max($0.0, 0), 1) }
        let colors = stops.map { $0.1 }
        return CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)
    }

    /// The gradient axis endpoints in TARGET space: the horizontal midline of
    /// the gradient rect (world space), carried through the brush's own
    /// transform (if any) and then the world→target transform `full`. This
    /// honours the common horizontal case and any rotation baked into the
    /// brush transform ([MS-EMFPLUS] §2.2.2.24); a free-standing gradient angle
    /// is P6 polish. Returns nil for a degenerate rect (caller fills solid).
    static func linearGradientAxis(
        _ g: EMFPlusLinearGradientBrush,
        full: CGAffineTransform
    ) -> (start: CGPoint, end: CGPoint)? {
        let rect = g.rect
        guard rect.width != 0, rect.width.isFinite, rect.height.isFinite else { return nil }
        var mapping = full
        if let transform = g.transform {
            mapping = EMFPlusGeometry.affine(transform).concatenating(full)
        }
        let midY = Double(rect.y) + Double(rect.height) / 2
        let p0 = CGPoint(x: Double(rect.x), y: midY)
        let p1 = CGPoint(x: Double(rect.x) + Double(rect.width), y: midY)
        return (p0.applying(mapping), p1.applying(mapping))
    }

    /// Per-channel linear interpolation between two ARGB colours by `factor`.
    private static func lerp(_ a: EMFPlusARGB, _ b: EMFPlusARGB, _ factor: CGFloat) -> CGColor {
        let f = min(max(factor, 0), 1)
        func mix(_ x: UInt8, _ y: UInt8) -> CGFloat { (CGFloat(x) + (CGFloat(y) - CGFloat(x)) * f) / 255 }
        return CGColor(srgbRed: mix(a.red, b.red), green: mix(a.green, b.green), blue: mix(a.blue, b.blue), alpha: mix(a.alpha, b.alpha))
    }

    // MARK: - Pen → stroke style

    /// Resolves an EmfPlusPen ([MS-EMFPLUS] §2.2.1.7 / §2.2.2.33) into CG stroke
    /// parameters. Width is world-space (PenUnit 0), scaled to target units by
    /// the average axis scale of `full`. Caps/joins map per §2.1.1.17/§2.1.1.18;
    /// dash lengths are multiples of the pen width (§2.2.2.16). Anything CG
    /// cannot express (triangle/anchor/custom caps, a non-solid pen brush) is
    /// approximated with a logged note.
    static func strokeStyle(
        _ pen: EMFPlusPen,
        full: CGAffineTransform,
        log: inout EMFRenderLog
    ) -> PlusStrokeStyle {
        let data = pen.penData
        let scale = StrokeMapper.averageScale(full)
        let rawWidth = CGFloat(data.width) * scale
        let width = rawWidth > 0 ? rawWidth : 1

        // Colour: solid pen brush → its colour; otherwise a representative
        // solid with a logged approximation.
        let color: CGColor
        if case .solid(let argb) = pen.brush.data {
            color = EMFPlusGeometry.cgColor(argb)
        } else {
            log.noteEMFPlusApproximated(.penNonSolidBrush)
            color = EMFPlusGeometry.cgColor(representativeColor(pen.brush) ?? EMFPlusARGB(blue: 0, green: 0, red: 0, alpha: 255))
        }

        // Line cap (§2.1.1.17): use the start cap; CG applies one cap to both
        // ends. A custom cap block present also degrades to a basic cap.
        var cap: CGLineCap = .butt
        var capApproximated = data.customStartCap != nil || data.customEndCap != nil
        switch data.startCap ?? 0 {
        case 0: cap = .butt        // LineCapTypeFlat
        case 1: cap = .square      // LineCapTypeSquare
        case 2: cap = .round       // LineCapTypeRound
        default: cap = .round; capApproximated = true   // triangle / anchor / custom
        }
        if capApproximated { log.noteEMFPlusApproximated(.penCap) }

        // Line join (§2.1.1.18).
        let join: CGLineJoin
        switch data.join ?? 0 {
        case 1: join = .bevel      // LineJoinTypeBevel
        case 2: join = .round      // LineJoinTypeRound
        default: join = .miter     // Miter / MiterClipped
        }

        let miterLimit = data.miterLimit.map { CGFloat(max($0, 1)) } ?? 10

        // Dash pattern (§2.2.2.16): DashedLineData values are multiples of the
        // pen width, so a dash in target units is value × width. The offset
        // (§2.1.2.7 PenDataDashedLineOffset) is likewise width-relative.
        var dash: [CGFloat] = []
        var dashPhase: CGFloat = 0
        if let pattern = data.dashedLine {
            let scaled = pattern.map { CGFloat($0) * width }
            if scaled.contains(where: { $0 > 0 }) {
                dash = scaled.map { max($0, 0) }
                dashPhase = CGFloat(data.dashOffset ?? 0) * width
            }
        }

        return PlusStrokeStyle(
            color: color,
            width: width,
            cap: cap,
            join: join,
            miterLimit: miterLimit,
            dash: dash,
            dashPhase: dashPhase
        )
    }
}
