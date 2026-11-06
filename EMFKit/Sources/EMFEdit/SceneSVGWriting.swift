import CoreGraphics
import EMFParse
import Foundation
import WMFParse

/// Deterministic number, colour and rectangle formatting for the SVG writer.
/// Fixed 3-decimal floats, no exponent, no locale decimal separator (Swift's
/// `String(format:)` uses the C locale for `%f`), so the same scene yields
/// byte-identical output.
enum SVGFormat {
    /// `v` to at most 3 decimals, trailing zeros trimmed, non-finite → "0",
    /// "-0" → "0".
    static func num(_ v: some BinaryFloatingPoint) -> String {
        let d = Double(v)
        guard d.isFinite else { return "0" }
        var s = String(format: "%.3f", d)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    /// A lowercase `#rrggbb` (alpha is carried separately as `*-opacity`).
    static func hex(_ c: SceneColor) -> String {
        func comp(_ v: Double) -> Int { Int((v * 255).rounded().clamped(0, 255)) }
        return String(format: "#%02x%02x%02x", comp(c.red), comp(c.green), comp(c.blue))
    }

    /// `r` standardised, or nil when it is null or any component is non-finite.
    static func finiteRect(_ r: CGRect) -> CGRect? {
        guard !r.isNull, r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
        return r.standardized
    }
}

/// XML 1.0 escaping that also strips characters illegal in XML 1.0 (§8: the output
/// is opened by other apps, and drawing text is untrusted). Attribute values are
/// always double-quoted, so single quotes are left literal.
enum SVGEscape {
    static func attr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars where isLegalXML(scalar) {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func text(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars where isLegalXML(scalar) {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            // Escaping '>' also neutralises any "]]>" sequence in character data.
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The XML 1.0 Char production ([W3C XML 1.0 §2.2]).
    private static func isLegalXML(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return v == 0x9 || v == 0xA || v == 0xD
            || (v >= 0x20 && v <= 0xD7FF)
            || (v >= 0xE000 && v <= 0xFFFD)
            || (v >= 0x10000 && v <= 0x10FFFF)
    }
}

/// Geometry → SVG path/shape data, and the stroke-metric helpers shared with the
/// renderer.
enum SVGGeometry {
    static func isFinite(_ path: ScenePath) -> Bool {
        for segment in path.segments {
            switch segment {
            case .move(let p), .line(let p):
                if !p.x.isFinite || !p.y.isFinite { return false }
            case .quadCurve(let to, let c):
                if !to.x.isFinite || !to.y.isFinite || !c.x.isFinite || !c.y.isFinite { return false }
            case .cubicCurve(let to, let c1, let c2):
                if !to.x.isFinite || !to.y.isFinite || !c1.x.isFinite || !c1.y.isFinite || !c2.x.isFinite || !c2.y.isFinite { return false }
            case .close:
                break
            }
        }
        return true
    }

    static func isFiniteTransform(_ t: CGAffineTransform) -> Bool {
        t.a.isFinite && t.b.isFinite && t.c.isFinite && t.d.isFinite && t.tx.isFinite && t.ty.isFinite
    }

    static func matrix(_ t: CGAffineTransform) -> String {
        "matrix(\(SVGFormat.num(t.a)) \(SVGFormat.num(t.b)) \(SVGFormat.num(t.c)) \(SVGFormat.num(t.d)) \(SVGFormat.num(t.tx)) \(SVGFormat.num(t.ty)))"
    }

    static func averageScale(_ t: CGAffineTransform) -> Double {
        let sx = (Double(t.a) * Double(t.a) + Double(t.b) * Double(t.b)).squareRoot()
        let sy = (Double(t.c) * Double(t.c) + Double(t.d) * Double(t.d)).squareRoot()
        return (sx + sy) / 2
    }

    /// A primitive shape when the element's kind round-trips cleanly from its
    /// segments (line/polyline/polygon, single subpath), else a `<path>` — always
    /// exact. Recovered primitives keep the drawing editable in SVG tools.
    static func shape(for element: Element) -> (tag: String, geometryAttribute: String) {
        let path = element.geometryDevice
        switch element.kind {
        case .line:
            if let pts = polyPoints(path, closed: false), pts.count == 2 {
                return ("line", "x1=\"\(SVGFormat.num(pts[0].x))\" y1=\"\(SVGFormat.num(pts[0].y))\" x2=\"\(SVGFormat.num(pts[1].x))\" y2=\"\(SVGFormat.num(pts[1].y))\"")
            }
        case .polyline:
            if let pts = polyPoints(path, closed: false), pts.count >= 2 {
                return ("polyline", "points=\"\(pointsString(pts))\"")
            }
        case .polygon:
            if let pts = polyPoints(path, closed: true), pts.count >= 3 {
                return ("polygon", "points=\"\(pointsString(pts))\"")
            }
        default:
            break
        }
        return ("path", "d=\"\(pathData(path))\"")
    }

    static func pathData(_ path: ScenePath) -> String {
        var out = ""
        var first = true
        for segment in path.segments {
            if !first { out += " " }
            first = false
            switch segment {
            case .move(let p): out += "M \(SVGFormat.num(p.x)) \(SVGFormat.num(p.y))"
            case .line(let p): out += "L \(SVGFormat.num(p.x)) \(SVGFormat.num(p.y))"
            case .quadCurve(let to, let c):
                out += "Q \(SVGFormat.num(c.x)) \(SVGFormat.num(c.y)) \(SVGFormat.num(to.x)) \(SVGFormat.num(to.y))"
            case .cubicCurve(let to, let c1, let c2):
                out += "C \(SVGFormat.num(c1.x)) \(SVGFormat.num(c1.y)) \(SVGFormat.num(c2.x)) \(SVGFormat.num(c2.y)) \(SVGFormat.num(to.x)) \(SVGFormat.num(to.y))"
            case .close: out += "Z"
            }
        }
        return out
    }

    /// A stroke-dasharray in device units mirroring `StrokeMapper`/`SceneRenderer`
    /// (predefined patterns scale by `max(width, 1)`; a user style scales by the
    /// element unit scale), or nil for a solid pen.
    static func dashArray(_ stroke: SceneStroke, width: Double, unitScale: Double) -> String? {
        let basis = Swift.max(width, 1)
        func pattern(_ multiples: [Double]) -> String {
            multiples.map { SVGFormat.num($0 * basis) }.joined(separator: " ")
        }
        switch stroke.dash {
        case .solid: return nil
        case .dash: return pattern([3, 1])
        case .dot: return pattern([1, 1])
        case .dashDot: return pattern([3, 1, 1, 1])
        case .dashDotDot: return pattern([3, 1, 1, 1, 1, 1])
        case .userStyle(let entries):
            let scaled = entries.map { Double($0) * unitScale }
            guard scaled.contains(where: { $0 > 0 }) else { return nil }
            return scaled.map(SVGFormat.num).joined(separator: " ")
        }
    }

    private static func pointsString(_ pts: [CGPoint]) -> String {
        pts.map { "\(SVGFormat.num($0.x)),\(SVGFormat.num($0.y))" }.joined(separator: " ")
    }

    /// The vertices of a single-subpath move+line sequence, or nil when the path has
    /// a curve, more than one subpath, or a close that disagrees with `closed`.
    private static func polyPoints(_ path: ScenePath, closed: Bool) -> [CGPoint]? {
        var pts: [CGPoint] = []
        var sawClose = false
        for (i, segment) in path.segments.enumerated() {
            switch segment {
            case .move(let p):
                guard i == 0 else { return nil }
                pts.append(p)
            case .line(let p):
                guard !sawClose, !pts.isEmpty else { return nil }
                pts.append(p)
            case .close:
                guard !sawClose else { return nil }
                sawClose = true
            case .quadCurve, .cubicCurve:
                return nil
            }
        }
        if closed { guard sawClose else { return nil } }
        else { guard !sawClose else { return nil } }
        return pts.isEmpty ? nil : pts
    }
}

/// Text-run layout: the `<text>` transform, anchor, baseline, font and the x
/// position(s). Both GDI and EMF+ runs follow the one convention that the drawn
/// device point is `referenceLogical.applying(element.transform)`, so the run is
/// emitted in its PRE-transform space with the element transform on the tag.
enum SVGText {
    struct Layout {
        var transform: String
        var x: String
        var y: Double
        var fontFamily: String
        var fontSize: Double
        var decoration: String?
        var anchor: String?
        var baseline: String?
        var rotationApproximated: Bool
    }

    static func layout(for element: Element, text: SceneText) -> Layout? {
        let t = element.transform
        guard SVGGeometry.isFiniteTransform(t) else { return nil }
        let ref = text.referenceLogical
        guard ref.x.isFinite, ref.y.isFinite else { return nil }

        var fontSize: Double
        if text.isEMFPlus {
            fontSize = text.emSize > 0 ? text.emSize : 16
        } else {
            fontSize = abs(Double(text.logicalHeight))
            if fontSize < 1 { fontSize = 16 }
        }
        guard fontSize.isFinite else { return nil }

        // Text under an axis-aligned world transform (no rotation/shear) is drawn
        // UPRIGHT in device space by both engines: GDI (`TextDrawer`) and EMF+
        // (`EMFPlusPlayback.drawString`, the b==0,c==0 branch) position the anchor
        // through the transform and size the glyphs by its scale, but never run the
        // glyph shapes through it — so a reflection (worldToDevice.d < 0, common in
        // bottom-up pages) moves the text without mirroring it. Putting the transform
        // on the <text> tag instead would flip the glyphs upside down. Only a true
        // rotation/shear keeps the transform on the tag (there the glyphs DO rotate).
        let axisAligned = abs(Double(t.b)) < 1e-9 && abs(Double(t.c)) < 1e-9
        if axisAligned {
            return text.isEMFPlus
                ? deviceLayoutEMFPlus(element, text: text, transform: t, preEm: fontSize)
                : deviceLayoutGDI(element, text: text, transform: t, preEm: fontSize)
        }

        var transformStr = SVGGeometry.matrix(t)
        var rotationApprox = false
        if !text.isEMFPlus, text.escapementTenths != 0 {
            let deg = Double(text.escapementTenths) / 10.0
            if deg.isFinite {
                // GDI escapement is CCW in logical space; in SVG's y-down user space
                // that is a clockwise rotate about the reference point (approximate).
                transformStr += " rotate(\(SVGFormat.num(-deg)) \(SVGFormat.num(ref.x)) \(SVGFormat.num(ref.y)))"
                rotationApprox = true
            }
        }

        let anchor: String?
        let baseline: String?
        let xAttr: String
        let yVal: Double

        if text.isEMFPlus {
            if let rect = SVGFormat.finiteRect(text.layoutReference), rect.width != 0 || rect.height != 0 {
                switch text.alignRawValue {
                case 1: anchor = "middle"; xAttr = SVGFormat.num(rect.midX)
                case 2: anchor = "end"; xAttr = SVGFormat.num(rect.maxX)
                default: anchor = nil; xAttr = SVGFormat.num(rect.minX)   // Near
                }
                switch text.lineAlignRawValue {
                case 1: baseline = "central"; yVal = Double(rect.midY)
                case 2: baseline = "text-after-edge"; yVal = Double(rect.maxY)
                default: baseline = "text-before-edge"; yVal = Double(rect.minY)   // Near (top)
                }
            } else {
                switch text.alignRawValue {
                case 1: anchor = "middle"
                case 2: anchor = "end"
                default: anchor = nil
                }
                baseline = "text-before-edge"   // an EMF+ point origin is the layout top-left
                xAttr = SVGFormat.num(ref.x)
                yVal = Double(ref.y)
            }
        } else {
            // GDI text-alignment flags (wingdi TA_*; [MS-EMF] §2.1.1.25).
            let horiz = text.alignRawValue & 0x6
            switch text.alignRawValue & 0x18 {
            case 0x18: baseline = nil                 // TA_BASELINE (SVG default)
            case 0x08: baseline = "text-after-edge"   // TA_BOTTOM
            default: baseline = "text-before-edge"    // TA_TOP
            }
            if let xs = perGlyphX(text: text, ref: ref, horiz: horiz) {
                anchor = nil   // absolute per-glyph positions already encode the anchor
                xAttr = xs
            } else {
                switch horiz {
                case 0x2: anchor = "end"
                case 0x6: anchor = "middle"
                default: anchor = nil
                }
                xAttr = SVGFormat.num(ref.x)
            }
            yVal = Double(ref.y)
        }

        return Layout(
            transform: transformStr, x: xAttr, y: yVal,
            fontFamily: fontFamily(text), fontSize: fontSize,
            decoration: decoration(text), anchor: anchor, baseline: baseline,
            rotationApproximated: rotationApprox
        )
    }

    /// EMF+ axis-aligned text in DEVICE space (upright glyphs). The layout rect maps
    /// through the transform (CGRect.applying returns the standardised device box, so
    /// a y-flip is absorbed), and the string/line alignment place the anchor exactly
    /// as `EMFPlusText.drawStringOrigin` does. No transform on the tag, so glyphs stay
    /// upright regardless of the world flip.
    private static func deviceLayoutEMFPlus(_ element: Element, text: SceneText, transform t: CGAffineTransform, preEm: Double) -> Layout {
        let scale = SVGGeometry.averageScale(t)
        let fontSize = preEm * (scale.isFinite && scale > 0 ? scale : 1)

        let anchor: String?
        switch text.alignRawValue {
        case 1: anchor = "middle"   // StringAlignmentCenter
        case 2: anchor = "end"      // StringAlignmentFar
        default: anchor = nil       // Near (SVG default start)
        }

        let xValue: Double
        let yValue: Double
        let baseline: String?
        if let rect = SVGFormat.finiteRect(text.layoutReference.applying(t)), rect.width != 0 || rect.height != 0 {
            switch text.alignRawValue {
            case 1: xValue = Double(rect.midX)
            case 2: xValue = Double(rect.maxX)
            default: xValue = Double(rect.minX)
            }
            switch text.lineAlignRawValue {
            case 1: baseline = "central"; yValue = Double(rect.midY)
            case 2: baseline = "text-after-edge"; yValue = Double(rect.maxY)
            default: baseline = "text-before-edge"; yValue = Double(rect.minY)
            }
        } else {
            let device = text.referenceLogical.applying(t)
            xValue = Double(device.x)
            yValue = Double(device.y)
            baseline = "text-before-edge"
        }

        return Layout(
            transform: "", x: SVGFormat.num(xValue), y: yValue,
            fontFamily: fontFamily(text), fontSize: fontSize,
            decoration: decoration(text), anchor: anchor, baseline: baseline,
            rotationApproximated: false
        )
    }

    /// GDI axis-aligned text in DEVICE space (upright glyphs). The anchor maps
    /// through the transform, the font size scales by the vertical device scale, and
    /// the explicit advances scale by the horizontal device scale — matching
    /// `TextDrawer`, which draws upright glyphs at the device anchor regardless of a
    /// world y-flip. A non-zero escapement becomes a `rotate()` about the anchor.
    private static func deviceLayoutGDI(_ element: Element, text: SceneText, transform t: CGAffineTransform, preEm: Double) -> Layout {
        let sx = abs(Double(t.a)), sy = abs(Double(t.d))
        let fontSize = preEm * (sy.isFinite && sy > 0 ? sy : 1)
        let device = text.referenceLogical.applying(t)

        var transformStr = ""
        var rotationApprox = false
        if text.escapementTenths != 0 {
            let deg = Double(text.escapementTenths) / 10.0
            if deg.isFinite, device.x.isFinite, device.y.isFinite {
                transformStr = "rotate(\(SVGFormat.num(-deg)) \(SVGFormat.num(device.x)) \(SVGFormat.num(device.y)))"
                rotationApprox = true
            }
        }

        let baseline: String?
        switch text.alignRawValue & 0x18 {
        case 0x18: baseline = nil                 // TA_BASELINE (SVG default)
        case 0x08: baseline = "text-after-edge"   // TA_BOTTOM
        default: baseline = "text-before-edge"    // TA_TOP
        }

        let horiz = text.alignRawValue & 0x6
        let anchor: String?
        let xAttr: String
        if let xs = perGlyphXDevice(text: text, deviceAnchor: device, sx: sx, horiz: horiz) {
            anchor = nil
            xAttr = xs
        } else {
            switch horiz {
            case 0x2: anchor = "end"
            case 0x6: anchor = "middle"
            default: anchor = nil
            }
            xAttr = SVGFormat.num(device.x)
        }

        return Layout(
            transform: transformStr, x: xAttr, y: Double(device.y),
            fontFamily: fontFamily(text), fontSize: fontSize,
            decoration: decoration(text), anchor: anchor, baseline: baseline,
            rotationApproximated: rotationApprox
        )
    }

    /// Absolute per-character DEVICE x positions from the GDI advance array (scaled
    /// by the horizontal device scale), so the file's exact spacing survives. BMP-only.
    private static func perGlyphXDevice(text: SceneText, deviceAnchor: CGPoint, sx: Double, horiz: UInt32) -> String? {
        let advances = text.advancesLogical
        guard !advances.isEmpty, advances.count == text.string.utf16.count,
              text.string.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF }) else { return nil }
        let scaled = advances.map { Double($0) * sx }
        let total = scaled.reduce(0, +)
        guard total.isFinite, deviceAnchor.x.isFinite else { return nil }
        let start: Double
        switch horiz {
        case 0x2: start = Double(deviceAnchor.x) - total       // TA_RIGHT
        case 0x6: start = Double(deviceAnchor.x) - total / 2    // TA_CENTER
        default: start = Double(deviceAnchor.x)                 // TA_LEFT
        }
        var xs: [String] = []
        xs.reserveCapacity(scaled.count)
        var cursor = start
        for advance in scaled {
            xs.append(SVGFormat.num(cursor))
            cursor += advance
        }
        return xs.joined(separator: " ")
    }

    /// Absolute per-character x positions from the GDI advance array, so the file's
    /// exact (often condensed) spacing survives. Only when the advances line up 1:1
    /// with addressable characters — SVG addresses by codepoint, so this is BMP-only.
    private static func perGlyphX(text: SceneText, ref: CGPoint, horiz: UInt32) -> String? {
        let advances = text.advancesLogical
        guard !advances.isEmpty, advances.count == text.string.utf16.count,
              text.string.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF }) else { return nil }
        let total = advances.reduce(0.0) { $0 + Double($1) }
        guard total.isFinite else { return nil }
        let start: Double
        switch horiz {
        case 0x2: start = Double(ref.x) - total       // TA_RIGHT
        case 0x6: start = Double(ref.x) - total / 2    // TA_CENTER
        default: start = Double(ref.x)                 // TA_LEFT
        }
        var xs: [String] = []
        xs.reserveCapacity(advances.count)
        var cursor = start
        for advance in advances {
            xs.append(SVGFormat.num(cursor))
            cursor += Double(advance)
        }
        return xs.joined(separator: " ")
    }

    /// The requested face first (what the file asked for), then the resolved macOS
    /// family, then a generic fallback — quoted for CSS and XML-attribute-escaped.
    private static func fontFamily(_ text: SceneText) -> String {
        var names: [String] = []
        func add(_ name: String) {
            let cleaned = name
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !names.contains(cleaned) else { return }
            names.append(cleaned)
        }
        add(text.requestedFamily)
        add(text.fontFamily)
        let quoted = names.map { "'\($0)'" } + ["sans-serif"]
        return SVGEscape.attr(quoted.joined(separator: ", "))
    }

    private static func decoration(_ text: SceneText) -> String? {
        var parts: [String] = []
        if text.underline { parts.append("underline") }
        if text.strikeOut { parts.append("line-through") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Image placement: an axis-aligned `x/y/width/height`, or a `matrix()` mapping the
/// unit square to the device-space parallelogram corners (rotation/mirror/shear).
enum SVGImage {
    struct Placement { var attributes: [String] }

    static func placement(for element: Element, image: SceneImage) -> Placement? {
        if let corners = image.destCornersDevice, corners.count == 4,
           corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            // corners: upper-left, upper-right, lower-right, lower-left. The image's
            // unit square maps so (1,0)→UR−UL, (0,1)→LL−UL, origin→UL.
            let ul = corners[0], ur = corners[1], ll = corners[3]
            let a = Double(ur.x - ul.x), b = Double(ur.y - ul.y)
            let c = Double(ll.x - ul.x), d = Double(ll.y - ul.y)
            let e = Double(ul.x), f = Double(ul.y)
            let matrix = "matrix(\(SVGFormat.num(a)) \(SVGFormat.num(b)) \(SVGFormat.num(c)) \(SVGFormat.num(d)) \(SVGFormat.num(e)) \(SVGFormat.num(f)))"
            return Placement(attributes: ["x=\"0\"", "y=\"0\"", "width=\"1\"", "height=\"1\"", "transform=\"\(matrix)\""])
        }
        guard let rect = SVGFormat.finiteRect(image.destRectDevice), rect.width > 0, rect.height > 0 else { return nil }
        return Placement(attributes: [
            "x=\"\(SVGFormat.num(rect.minX))\"", "y=\"\(SVGFormat.num(rect.minY))\"",
            "width=\"\(SVGFormat.num(rect.width))\"", "height=\"\(SVGFormat.num(rect.height))\"",
        ])
    }
}

/// The document's physical size in millimetres so it imports at true scale: from
/// the EMF frame (hundredths of a millimetre, [MS-EMF] §2.2.9) or the WMF placeable
/// header's units-per-inch ([MS-WMF] §2.3.2.3), falling back to the device pixels
/// at 96 DPI.
enum SVGPhysicalSize {
    static func millimetres(for scene: Scene) -> CGSize? {
        switch scene.source.format {
        case .emf:
            if let file = try? EMFFile.parse(scene.source.data) {
                let f = file.header.frame
                let w = Double(Int64(f.right) - Int64(f.left)) / 100.0
                let h = Double(Int64(f.bottom) - Int64(f.top)) / 100.0
                if w.isFinite, h.isFinite, w > 0, h > 0 { return CGSize(width: w, height: h) }
            }
        case .wmf, .placeableWMF:
            if let wmf = try? WMFFile.parse(scene.source.data), let placeable = wmf.placeable, placeable.inch > 0 {
                let bb = placeable.boundingBox
                let w = Double(Int(bb.right) - Int(bb.left)) / Double(placeable.inch) * 25.4
                let h = Double(Int(bb.bottom) - Int(bb.top)) / Double(placeable.inch) * 25.4
                if w.isFinite, h.isFinite, w > 0, h > 0 { return CGSize(width: w, height: h) }
            }
        }
        let dev = scene.pageSizeDevice
        let w = Double(dev.width) / 96.0 * 25.4
        let h = Double(dev.height) / 96.0 * 25.4
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
