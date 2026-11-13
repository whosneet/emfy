import CoreGraphics
import Foundation

/// Pure colour maths for the accessibility check (X1a): WCAG 2.2 relative
/// luminance and contrast, sRGB⇄HSL (hue-preserving lightness edits), and a
/// colour-blind simulation. No model, no platform colour types — every result is
/// deterministic so the analysis and the fix planners are unit-testable.
public enum DrawingColorMath {

    // MARK: - sRGB gamma

    /// Expands one 0…1 sRGB component to linear light (WCAG 2.2 / IEC 61966-2-1).
    static func linearize(_ component: Double) -> Double {
        let c = component.clamped(0, 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Compresses one 0…1 linear component back to sRGB.
    static func delinearize(_ linear: Double) -> Double {
        let c = linear.clamped(0, 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // MARK: - Alpha compositing

    /// `color` composited over an opaque `background` (source-over). Contrast and
    /// simulation are defined on opaque colours, so a translucent fill/text is first
    /// resolved against what sits behind it.
    public static func composite(_ color: SceneColor, over background: SceneColor) -> SceneColor {
        let a = color.alpha.clamped(0, 1)
        guard a < 1 else { return SceneColor(red: color.red, green: color.green, blue: color.blue, alpha: 1) }
        return SceneColor(
            red: color.red * a + background.red * (1 - a),
            green: color.green * a + background.green * (1 - a),
            blue: color.blue * a + background.blue * (1 - a),
            alpha: 1
        )
    }

    // MARK: - WCAG contrast

    /// WCAG 2.2 relative luminance of an opaque colour: `0.2126 R + 0.7152 G +
    /// 0.0722 B` over linearised components (WCAG 2.2 §relative luminance).
    public static func relativeLuminance(_ color: SceneColor) -> Double {
        0.2126 * linearize(color.red) + 0.7152 * linearize(color.green) + 0.0722 * linearize(color.blue)
    }

    /// WCAG 2.2 contrast ratio `(L_light + 0.05) / (L_dark + 0.05)`, 1…21. Alpha is
    /// ignored here; callers composite first.
    public static func contrastRatio(_ a: SceneColor, _ b: SceneColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = Swift.max(la, lb)
        let darker = Swift.min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - HSL (hue-preserving lightness edits)

    /// sRGB → HSL. Hue in 0…360 (0 for achromatic), saturation/lightness 0…1.
    public static func toHSL(_ color: SceneColor) -> (hue: Double, saturation: Double, lightness: Double) {
        let r = color.red, g = color.green, b = color.blue
        let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
        let l = (maxC + minC) / 2
        let delta = maxC - minC
        guard delta > 1e-12 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / delta + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        return (h * 60, s, l)
    }

    /// HSL → sRGB (hue in 0…360). `alpha` is carried through unchanged.
    public static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> SceneColor {
        let s = saturation.clamped(0, 1), l = lightness.clamped(0, 1)
        guard s > 1e-12 else { return SceneColor(red: l, green: l, blue: l, alpha: alpha) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return SceneColor(red: channel(h + 1.0 / 3), green: channel(h), blue: channel(h - 1.0 / 3), alpha: alpha)
    }

    // MARK: - Colour-blind simulation

    /// The two dichromacies the check simulates.
    public enum Dichromacy: Sendable, CaseIterable { case protanopia, deuteranopia }

    /// Simulates how `color` appears to a dichromat, via the Brettel–Viénot–Mollon
    /// 1997/1999 linear-RGB simulation matrices (the standard set used by the HCIRN
    /// / "Color Oracle" simulations). The matrix is applied in linear light, then
    /// re-gamma'd. Alpha is preserved.
    public static func simulate(_ color: SceneColor, _ type: Dichromacy) -> SceneColor {
        let r = linearize(color.red), g = linearize(color.green), b = linearize(color.blue)
        let m: (Double, Double, Double, Double, Double, Double, Double, Double, Double)
        switch type {
        case .protanopia:
            m = (0.152286, 1.052583, -0.204868,
                 0.114503, 0.786281, 0.099216,
                 -0.003882, -0.048116, 1.051998)
        case .deuteranopia:
            m = (0.367322, 0.860646, -0.227968,
                 0.280085, 0.672501, 0.047413,
                 -0.011820, 0.042940, 0.968900)
        }
        let nr = m.0 * r + m.1 * g + m.2 * b
        let ng = m.3 * r + m.4 * g + m.5 * b
        let nb = m.6 * r + m.7 * g + m.8 * b
        return SceneColor(red: delinearize(nr), green: delinearize(ng), blue: delinearize(nb), alpha: color.alpha)
    }

    /// A perceptual-ish 0…1 distance between two opaque colours: the RMS of the
    /// per-channel sRGB differences (1 for black vs white, ≈0.816 for pure red vs
    /// green). Deliberately simple and deterministic; the check only needs a stable
    /// "clearly different" vs "effectively the same" split, kept conservative.
    public static func distance(_ a: SceneColor, _ b: SceneColor) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (((dr * dr) + (dg * dg) + (db * db)) / 3).squareRoot()
    }

    // MARK: - CIELAB ΔE

    /// sRGB → CIELAB (D65), via linear sRGB → XYZ → Lab. Used for perceptual colour
    /// naming and the eval suite's "within tolerance" colour checks.
    public static func toLab(_ color: SceneColor) -> (L: Double, a: Double, b: Double) {
        let r = linearize(color.red), g = linearize(color.green), b = linearize(color.blue)
        // linear sRGB → XYZ (D65), then normalise by the D65 white point.
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.0
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIE76 ΔE between two colours (Euclidean distance in CIELAB). ~2.3 is the "just
    /// noticeable difference"; the eval suite treats a modest ΔE as "the right colour".
    public static func deltaE(_ a: SceneColor, _ b: SceneColor) -> Double {
        let la = toLab(a), lb = toLab(b)
        let dL = la.L - lb.L, da = la.a - lb.a, dB = la.b - lb.b
        return (dL * dL + da * da + dB * dB).squareRoot()
    }
}
