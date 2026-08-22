import CoreGraphics
import EMFParse
import Foundation

/// A bounds-checked, little-endian sequential reader over one EMF+ record's
/// `RecordData` (primer §8: every read is validated, nothing force-unwraps or
/// over-allocates). `EMFPlusRecord.data` may be a slice with a non-zero
/// `startIndex`, so the bytes are normalised into a zero-based array on init —
/// the same hazard `ByteReader` neutralises on the parse side.
struct PlusReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.offset = 0
    }

    var remaining: Int { bytes.count - offset }

    mutating func u32() -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func u16() -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }

    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }

    /// An EmfPlusRectF ([MS-EMFPLUS] §2.2.2.39): X, Y, Width, Height as floats.
    mutating func rectF() -> CGRect? {
        guard let x = f32(), let y = f32(), let w = f32(), let h = f32() else { return nil }
        return CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }

    /// An EmfPlusRect ([MS-EMFPLUS] §2.2.2.38): X, Y, Width, Height as 16-bit
    /// signed integers, packed two-per-DWORD.
    mutating func rectI() -> CGRect? {
        guard let a = u32(), let b = u32() else { return nil }
        let x = Int16(bitPattern: UInt16(a & 0xFFFF))
        let y = Int16(bitPattern: UInt16((a >> 16) & 0xFFFF))
        let w = Int16(bitPattern: UInt16(b & 0xFFFF))
        let h = Int16(bitPattern: UInt16((b >> 16) & 0xFFFF))
        return CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }

    /// One RectData element, EmfPlusRect if `compressed` else EmfPlusRectF.
    mutating func rect(compressed: Bool) -> CGRect? {
        compressed ? rectI() : rectF()
    }

    /// An EmfPlusPointF ([MS-EMFPLUS] §2.2.2.36).
    mutating func pointF() -> CGPoint? {
        guard let x = f32(), let y = f32() else { return nil }
        return CGPoint(x: Double(x), y: Double(y))
    }

    /// An EmfPlusPoint ([MS-EMFPLUS] §2.2.2.35): two 16-bit signed integers.
    mutating func pointI() -> CGPoint? {
        guard let a = u32() else { return nil }
        let x = Int16(bitPattern: UInt16(a & 0xFFFF))
        let y = Int16(bitPattern: UInt16((a >> 16) & 0xFFFF))
        return CGPoint(x: Double(x), y: Double(y))
    }

    /// `count` points, EmfPlusPoint if `compressed` else EmfPlusPointF. The
    /// count is bounds-checked against the remaining bytes BEFORE any
    /// allocation, so a lying count fails instead of over-reading (primer §8).
    mutating func points(count: Int, compressed: Bool) -> [CGPoint]? {
        let stride = compressed ? 4 : 8
        guard count >= 0, count <= remaining / stride else { return nil }
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let p = compressed ? pointI() : pointF() else { return nil }
            result.append(p)
        }
        return result
    }
}

/// EMF+ geometry → CGPath construction. Every builder appends into a caller
/// path with the composed EMF+ world→page→device→target transform applied at
/// construction time (the CGPath `transform:` parameters), exactly as the GDI
/// `PathBuilder` does, so the renderer never sets a CTM.
enum EMFPlusGeometry {

    /// An EmfPlusARGB → sRGB CGColor. The channels are stored blue/green/red/
    /// alpha ([MS-EMFPLUS] §2.2.2.1); this builds an sRGB colour with straight
    /// alpha.
    static func cgColor(_ argb: EMFPlusARGB) -> CGColor {
        CGColor(
            srgbRed: CGFloat(argb.red) / 255,
            green: CGFloat(argb.green) / 255,
            blue: CGFloat(argb.blue) / 255,
            alpha: CGFloat(argb.alpha) / 255
        )
    }

    /// An EmfPlusTransformMatrix ([MS-EMFPLUS] §2.2.2.47: m11,m12,m21,m22,dx,dy)
    /// as a CGAffineTransform — the same row-vector `[a b c d tx ty]` layout.
    static func affine(_ m: EMFPlusTransformMatrix) -> CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(m.m11), b: CGFloat(m.m12),
            c: CGFloat(m.m21), d: CGFloat(m.m22),
            tx: CGFloat(m.dx), ty: CGFloat(m.dy)
        )
    }

    // MARK: - Paths

    /// Appends an EmfPlusPath ([MS-EMFPLUS] §2.2.1.6) by walking its point
    /// types (§2.2.2.31): a `.start` opens a subpath (move), `.line` adds a
    /// line, `.bezier` consumes three points as control/control/end, and the
    /// CloseSubpath flag closes after the point it is on. A truncated bezier
    /// triple or an unknown point kind stops the walk, keeping what was built
    /// (log-and-skip). Empty/degenerate paths append nothing.
    static func appendPath(
        _ path: EMFPlusPath,
        to out: CGMutablePath,
        transform t: CGAffineTransform,
        recordType: UInt16,
        log: inout EMFRenderLog
    ) {
        let pts = path.points.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
        let types = path.decodedPointTypes
        guard pts.count == types.count, !pts.isEmpty else { return }
        // Per-segment DashMode (§2.2.2.31) is not reproduced — note it once (the
        // path still draws solid). PathMarker (0x02) is deliberately NOT noted:
        // markers only affect GetPathPoints enumeration, never how a path is
        // filled or stroked, so ignoring them changes no pixels (audit M14).
        if types.contains(where: \.isDashMode) { log.noteEMFPlusApproximated(.pathDashSegment) }

        var i = 0
        var hasCurrent = false
        while i < pts.count {
            let type = types[i]
            switch type.kind {
            case .start:
                out.move(to: pts[i], transform: t)
                hasCurrent = true
                i += 1
            case .line:
                if hasCurrent {
                    out.addLine(to: pts[i], transform: t)
                } else {
                    out.move(to: pts[i], transform: t)
                    hasCurrent = true
                }
                if type.isCloseSubpath { out.closeSubpath() }
                i += 1
            case .bezier:
                // A bezier consumes this point (control 1) plus the next two.
                guard i + 2 < pts.count else {
                    log.noteEMFPlusRecordUndecodable(type: recordType); return   // dangling bezier triple
                }
                if !hasCurrent {
                    out.move(to: pts[i], transform: t)
                    hasCurrent = true
                }
                out.addCurve(
                    to: pts[i + 2],
                    control1: pts[i],
                    control2: pts[i + 1],
                    transform: t
                )
                let closeAfter = types[i + 2].isCloseSubpath
                i += 3
                if closeAfter { out.closeSubpath() }
            case .unknown:
                log.noteEMFPlusRecordUndecodable(type: recordType); return   // unknown point kind
            }
        }
    }

    /// Appends a closed polygon subpath from `points`. Fewer than 2 points
    /// append nothing (GDI+ no-op).
    static func appendPolygon(_ points: [CGPoint], to out: CGMutablePath, transform t: CGAffineTransform) {
        guard points.count >= 2, let first = points.first else { return }
        out.move(to: first, transform: t)
        for p in points.dropFirst() { out.addLine(to: p, transform: t) }
        out.closeSubpath()
    }

    /// Appends an open polyline through `points`, optionally closing the figure
    /// (EmfPlusDrawLines L flag).
    static func appendPolyline(_ points: [CGPoint], to out: CGMutablePath, transform t: CGAffineTransform, close: Bool) {
        guard points.count >= 2, let first = points.first else { return }
        out.move(to: first, transform: t)
        for p in points.dropFirst() { out.addLine(to: p, transform: t) }
        if close { out.closeSubpath() }
    }

    /// Appends connected cubic Bezier curves: `points[0]` is the start, then
    /// control/control/end triples (EmfPlusDrawBeziers, count ≡ 1 mod 3). Any
    /// trailing partial triple (or too few points for even one curve) is dropped
    /// and noted as undecodable (audit M14).
    static func appendBeziers(
        _ points: [CGPoint],
        to out: CGMutablePath,
        transform t: CGAffineTransform,
        recordType: UInt16,
        log: inout EMFRenderLog
    ) {
        if let first = points.first, points.count >= 4 {
            out.move(to: first, transform: t)
            var i = 1
            while i + 2 <= points.count - 1 {
                out.addCurve(to: points[i + 2], control1: points[i], control2: points[i + 1], transform: t)
                i += 3
            }
        }
        // A well-formed run is 1 + 3k points; a leftover partial triple (or a
        // count too small to draw one curve, e.g. 2 or 3 points) was dropped.
        if points.count >= 1, (points.count - 1) % 3 != 0 {
            log.noteEMFPlusRecordUndecodable(type: recordType)
        }
    }

    // MARK: - Ellipses, arcs, pies

    /// Appends the full ellipse inscribed in `rect` (world coordinates).
    static func appendEllipse(in rect: CGRect, to out: CGMutablePath, transform t: CGAffineTransform) {
        out.addEllipse(in: rect, transform: t)
    }

    /// Appends the arc (open) or pie wedge (closed, through the centre) of the
    /// ellipse inscribed in `rect`, from `startDegrees` sweeping `sweepDegrees`
    /// ([MS-EMFPLUS] §2.3.4.2/§2.3.4.12). StartAngle/SweepAngle are TRUE angles —
    /// the endpoint is the ray∩ellipse at that angle (matching GDI+ DrawArc), NOT
    /// the ellipse's parametric angle. A point on the ellipse in true direction θ
    /// has tan t = (rx/ry)·tan θ (quadrant-preserved), so the parametric angle is
    /// t = atan2(rx·sinθ, ry·cosθ). For a circle (rx==ry) this is the identity,
    /// and at 90° multiples t == θ. The arc is emitted as cubic segments of at
    /// most 90° (parametric) via the standard 4/3·tan(Δ/4) control construction.
    static func appendArc(
        rect: CGRect,
        startDegrees: Float,
        sweepDegrees: Float,
        pie: Bool,
        to out: CGMutablePath,
        transform t: CGAffineTransform
    ) {
        let rx = rect.width / 2
        let ry = rect.height / 2
        guard rx != 0, ry != 0, rect.width.isFinite, rect.height.isFinite else { return }
        // §2.3.4.2 / GDI+ DrawArc: a zero sweep draws nothing — arc AND pie (L12).
        guard sweepDegrees != 0 else { return }
        let cx = rect.midX
        let cy = rect.midY

        let startTrue = Double(startDegrees) * .pi / 180
        // §2.3.4.2: SweepAngle is clamped to [-360, 360].
        let sweepClamped = max(-360, min(360, Double(sweepDegrees)))
        let endTrue = startTrue + sweepClamped * .pi / 180

        // True angle → parametric angle (see the doc comment).
        func parametric(_ theta: Double) -> Double { atan2(rx * sin(theta), ry * cos(theta)) }
        let t0 = parametric(startTrue)
        // Continuous unwrap: t(θ) increases monotonically and gains 2π per turn,
        // so the parametric sweep takes the sign and winding of the true sweep.
        let sweepParam: Double
        if abs(sweepClamped) == 360 {
            sweepParam = sweepClamped > 0 ? 2 * .pi : -2 * .pi
        } else {
            var delta = parametric(endTrue) - t0
            if sweepClamped > 0 {
                while delta <= 0 { delta += 2 * .pi }
                while delta > 2 * .pi { delta -= 2 * .pi }
            } else {
                while delta >= 0 { delta -= 2 * .pi }
                while delta < -2 * .pi { delta += 2 * .pi }
            }
            sweepParam = delta
        }

        func point(_ theta: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(theta), y: cy + ry * sin(theta))
        }
        func derivative(_ theta: Double) -> CGVector {
            CGVector(dx: -rx * sin(theta), dy: ry * cos(theta))
        }

        let segments = max(1, Int((abs(sweepParam) / (.pi / 2)).rounded(.up)))
        let step = sweepParam / Double(segments)

        if pie {
            out.move(to: CGPoint(x: cx, y: cy), transform: t)
            out.addLine(to: point(t0), transform: t)
        } else {
            out.move(to: point(t0), transform: t)
        }

        var theta = t0
        for _ in 0 ..< segments {
            let next = theta + step
            let alpha = 4.0 / 3.0 * tan(step / 4)
            let p1 = point(theta)
            let p2 = point(next)
            let d1 = derivative(theta)
            let d2 = derivative(next)
            out.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + alpha * d1.dx, y: p1.y + alpha * d1.dy),
                control2: CGPoint(x: p2.x - alpha * d2.dx, y: p2.y - alpha * d2.dy),
                transform: t
            )
            theta = next
        }

        if pie {
            out.addLine(to: CGPoint(x: cx, y: cy), transform: t)
            out.closeSubpath()
        }
    }

    // MARK: - Cardinal splines (curves)

    /// Appends a cardinal spline through `points` with GDI+ `tension`
    /// ([MS-EMFPLUS] §2.3.4.5 + the cited [PETZOLD] construction). A cardinal
    /// segment P₁→P₂ maps to a cubic Bezier whose control points offset the
    /// endpoints along the neighbour chord: C₁ = P₁ + (P₂−P₀)·tension/3,
    /// C₂ = P₂ − (P₃−P₁)·tension/3. Tension 0 yields straight lines. `closed`
    /// wraps the neighbour indices and closes the loop; open clamps the ends.
    static func appendCardinalSpline(
        _ points: [CGPoint],
        tension: Float,
        closed: Bool,
        to out: CGMutablePath,
        transform t: CGAffineTransform
    ) {
        let n = points.count
        guard n >= 2, let first = points.first else { return }
        let k = CGFloat(tension) / 3

        func at(_ index: Int) -> CGPoint {
            if closed {
                return points[((index % n) + n) % n]
            }
            return points[min(max(index, 0), n - 1)]
        }

        out.move(to: first, transform: t)
        let segmentCount = closed ? n : n - 1
        for i in 0 ..< segmentCount {
            let p0 = at(i - 1)
            let p1 = at(i)
            let p2 = at(i + 1)
            let p3 = at(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * k, y: p1.y + (p2.y - p0.y) * k)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * k, y: p2.y - (p3.y - p1.y) * k)
            out.addCurve(to: p2, control1: c1, control2: c2, transform: t)
        }
        if closed { out.closeSubpath() }
    }

    // MARK: - Regions

    /// Resolves an EmfPlusRegion node ([MS-EMFPLUS] §2.2.2.40) into a single
    /// CGPath in the target space defined by `transform`. Leaves map directly
    /// (rect/path/empty/infinite); a combine node is approximated as the UNION
    /// of its two children — exact for RegionNodeDataTypeOr, and a safe
    /// "render more" over-approximation for the other combine modes, each of
    /// which is logged. `infinite` resolves to a very large rectangle so an
    /// infinite region clip is effectively no clip.
    static func regionPath(
        _ node: EMFPlusRegionNode,
        transform t: CGAffineTransform,
        recordType: UInt16,
        log: inout EMFRenderLog
    ) -> CGPath {
        let out = CGMutablePath()
        appendRegion(node, to: out, transform: t, recordType: recordType, log: &log)
        return out
    }

    private static func appendRegion(
        _ node: EMFPlusRegionNode,
        to out: CGMutablePath,
        transform t: CGAffineTransform,
        recordType: UInt16,
        log: inout EMFRenderLog
    ) {
        switch node {
        case .rect(let rf):
            out.addRect(
                CGRect(x: Double(rf.x), y: Double(rf.y), width: Double(rf.width), height: Double(rf.height)),
                transform: t
            )
        case .path(let path):
            appendPath(path, to: out, transform: t, recordType: recordType, log: &log)
        case .empty:
            break
        case .infinite:
            out.addRect(CGRect(x: -10_000_000, y: -10_000_000, width: 20_000_000, height: 20_000_000), transform: t)
        case .combine(let operation, let left, let right):
            if operation != .or { log.noteEMFPlusApproximated(.regionCombine) }
            appendRegion(left, to: out, transform: t, recordType: recordType, log: &log)
            appendRegion(right, to: out, transform: t, recordType: recordType, log: &log)
        }
    }
}
