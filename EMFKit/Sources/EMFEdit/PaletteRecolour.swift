import CoreGraphics
import Foundation

// MARK: - Deterministic palette recolour (X2a)
//
// Recolours a scene (or a selection) to a palette, with NO model involved: greyscale,
// a colour-blind-safe set, a print-ready set, or the user's brand colours. Every mode
// is pure maths over `SceneColor`, so the mapping is deterministic and unit-testable,
// and it emits ordinary `SceneCommand`s applied as one grouped "Recolour" undo — the
// same path a user edit takes.
//
// Contrast is judged against the page/white background (the common case for metafiles,
// which carry no explicit canvas colour), reusing `DrawingColorMath`'s WCAG maths; text
// colours are adjusted so a run that was legible stays legible.

public enum PaletteRecolourMode: Sendable, Equatable {
    /// Luminance-preserving grey (R = G = B).
    case greyscale
    /// A colour-vision-deficiency-safe palette (Okabe–Ito), mapped by lightness order so
    /// mapped pairs stay distinguishable under deuteranopia and protanopia.
    case colourBlindSafe
    /// Print-ready: text to near-black; very light fills kept; other fills held inside a
    /// conservative, saturation- and lightness-limited gamut.
    case print
    /// Map each distinct drawing colour to the nearest of the user's 2–8 brand colours by
    /// CIELAB ΔE, keeping text legible.
    case brand(colours: [SceneColor])
}

public enum PaletteRecolour {

    /// One colour's old → new mapping, for the preview mapping list (old swatch → new).
    public struct Mapping: Sendable, Equatable {
        public var from: SceneColor
        public var to: SceneColor
        public init(from: SceneColor, to: SceneColor) {
            self.from = from
            self.to = to
        }
    }

    /// The background contrast is judged against: an opaque white page.
    static let assumedBackground = SceneColor(red: 1, green: 1, blue: 1)

    // MARK: Okabe–Ito palette ([Okabe & Ito 2008] colour-universal design set)

    /// The eight Okabe–Ito colours (black, orange, sky blue, bluish green, yellow, blue,
    /// vermillion, reddish purple) — every pair is distinguishable under the common
    /// dichromacies.
    static let okabeIto: [SceneColor] = [
        SceneColor(red: 0, green: 0, blue: 0),                           // black
        SceneColor(red: 0.902, green: 0.624, blue: 0),                   // orange
        SceneColor(red: 0.337, green: 0.706, blue: 0.914),              // sky blue
        SceneColor(red: 0, green: 0.620, blue: 0.451),                  // bluish green
        SceneColor(red: 0.941, green: 0.894, blue: 0.259),             // yellow
        SceneColor(red: 0, green: 0.447, blue: 0.698),                  // blue
        SceneColor(red: 0.835, green: 0.369, blue: 0),                  // vermillion
        SceneColor(red: 0.800, green: 0.475, blue: 0.655),            // reddish purple
    ]

    // MARK: Public API

    /// The scoped, editable elements for a recolour: those whose id is in `ids`, or all
    /// editable elements when `ids` is nil.
    static func scopedElements(_ scene: Scene, ids: Set<Int>?) -> [Element] {
        scene.editableElements.filter { element in
            guard !element.rejectsMutation else { return false }
            if let ids { return ids.contains(element.id) }
            return true
        }
    }

    /// The old → new colour mappings the recolour would apply (de-duplicated, in order of
    /// first appearance), for the preview mapping list. A colour that maps to itself is
    /// omitted.
    public static func mapping(for scene: Scene, ids: Set<Int>?, mode: PaletteRecolourMode) -> [Mapping] {
        let plan = buildPlan(for: scene, ids: ids, mode: mode)
        var seen = Set<SceneColor>()
        var out: [Mapping] = []
        for element in scopedElements(scene, ids: ids) {
            for original in plan.sourceColours(of: element) {
                guard let to = plan.mappedColour(original, isText: element.kind == .text),
                      to != original, seen.insert(original).inserted else { continue }
                out.append(Mapping(from: original, to: to))
            }
        }
        return out
    }

    /// The scene commands that recolour the scoped elements, for one grouped "Recolour"
    /// undo. One `setFill`/`setStroke` per changed element colour.
    public static func commands(for scene: Scene, ids: Set<Int>?, mode: PaletteRecolourMode) -> [SceneCommand] {
        let plan = buildPlan(for: scene, ids: ids, mode: mode)
        var out: [SceneCommand] = []
        for element in scopedElements(scene, ids: ids) {
            let isText = element.kind == .text
            // Text colour lives in the fill channel (setFill also sets the glyph colour).
            if isText, let colour = element.text?.color,
               let to = plan.mappedColour(colour, isText: true), to != colour {
                let evenOdd = element.style.fill?.evenOdd ?? false
                out.append(.setFill(ids: [element.id], SceneFill(color: to, evenOdd: evenOdd, gradient: nil)))
                continue
            }
            if !isText, let fill = element.style.fill, fill.gradient == nil,
               let to = plan.mappedColour(fill.color, isText: false), to != fill.color {
                out.append(.setFill(ids: [element.id], SceneFill(color: to, evenOdd: fill.evenOdd, gradient: nil)))
            }
            if var stroke = element.style.stroke,
               let to = plan.mappedColour(stroke.color, isText: false), to != stroke.color {
                stroke.color = to
                out.append(.setStroke(ids: [element.id], stroke))
            }
        }
        return out
    }

    // MARK: Plan (precomputed context)

    /// A resolved recolour: the role-aware colour map for one invocation, so every
    /// element and the preview share the same deterministic result.
    private struct Plan {
        let mode: PaletteRecolourMode
        /// For colour-blind-safe and brand: the base (non-text) colour map.
        let baseMap: [SceneColor: SceneColor]

        func sourceColours(of element: Element) -> [SceneColor] {
            if element.kind == .text { return element.text.map { [$0.color] } ?? [] }
            var out: [SceneColor] = []
            if let fill = element.style.fill, fill.gradient == nil { out.append(fill.color) }
            if let stroke = element.style.stroke { out.append(stroke.color) }
            return out
        }

        /// The new colour for `original` in the given role, or nil when it is unchanged.
        func mappedColour(_ original: SceneColor, isText: Bool) -> SceneColor? {
            switch mode {
            case .greyscale:
                return PaletteRecolour.greyscale(original)
            case .print:
                return isText ? PaletteRecolour.printText(original) : PaletteRecolour.printFill(original)
            case .colourBlindSafe:
                let mapped = baseMap[original] ?? original
                return isText ? PaletteRecolour.enforceTextContrast(mapped, original: original) : mapped
            case .brand(let colours):
                let mapped = baseMap[original] ?? PaletteRecolour.nearestBrand(original, brand: colours)
                if isText {
                    return PaletteRecolour.nearestBrandForText(original, brand: colours) ?? PaletteRecolour.enforceTextContrast(mapped, original: original)
                }
                return mapped
            }
        }
    }

    private static func buildPlan(for scene: Scene, ids: Set<Int>?, mode: PaletteRecolourMode) -> Plan {
        switch mode {
        case .greyscale, .print:
            return Plan(mode: mode, baseMap: [:])
        case .colourBlindSafe:
            let distinct = distinctColours(scene, ids: ids)
            return Plan(mode: mode, baseMap: colourBlindMap(distinct))
        case .brand(let colours):
            let distinct = distinctColours(scene, ids: ids)
            var map: [SceneColor: SceneColor] = [:]
            for colour in distinct { map[colour] = nearestBrand(colour, brand: colours) }
            return Plan(mode: mode, baseMap: map)
        }
    }

    /// The distinct colours used by the scoped elements, in order of first appearance.
    static func distinctColours(_ scene: Scene, ids: Set<Int>?) -> [SceneColor] {
        var seen = Set<SceneColor>()
        var out: [SceneColor] = []
        func add(_ colour: SceneColor) { if seen.insert(colour).inserted { out.append(colour) } }
        for element in scopedElements(scene, ids: ids) {
            if element.kind == .text, let colour = element.text?.color { add(colour) }
            if let fill = element.style.fill, fill.gradient == nil { add(fill.color) }
            if let stroke = element.style.stroke { add(stroke.color) }
        }
        return out
    }

    // MARK: Greyscale

    /// A luminance-preserving grey: R = G = B = the sRGB value whose relative luminance
    /// equals the original's, so the greyscale drawing keeps the same light/dark
    /// relationships. Alpha is carried through.
    static func greyscale(_ colour: SceneColor) -> SceneColor {
        let value = DrawingColorMath.delinearize(DrawingColorMath.relativeLuminance(colour))
        return SceneColor(red: value, green: value, blue: value, alpha: colour.alpha)
    }

    // MARK: Print
    //
    // Definition (documented, per the brief): text is forced to near-black (#1A1A1A) so it
    // prints crisply; a very light fill (lightness > 0.9) is left alone (paper tints, light
    // tint-fills); every other fill is pulled inside a conservative gamut — saturation
    // capped at 0.8 and lightness clamped to [0.2, 0.85] — so a screen-vivid fill does not
    // bleed or wash out on paper. Hue is always preserved.

    static let printNearBlack = SceneColor(red: 0.102, green: 0.102, blue: 0.102)
    static let printMaxSaturation = 0.8
    static let printMinLightness = 0.2
    static let printMaxLightness = 0.85

    static func printText(_ colour: SceneColor) -> SceneColor {
        SceneColor(red: printNearBlack.red, green: printNearBlack.green, blue: printNearBlack.blue, alpha: colour.alpha)
    }

    static func printFill(_ colour: SceneColor) -> SceneColor {
        let hsl = DrawingColorMath.toHSL(colour)
        if hsl.lightness > 0.9 { return colour }   // keep very light fills
        let s = min(hsl.saturation, printMaxSaturation)
        let l = hsl.lightness.clamped(printMinLightness, printMaxLightness)
        return DrawingColorMath.fromHSL(hue: hsl.hue, saturation: s, lightness: l, alpha: colour.alpha)
    }

    // MARK: Colour-blind-safe

    /// How far apart two mapped colours must stay under BOTH dichromacies to count as
    /// distinguishable (same split `DrawingFixPlanner` uses, with margin).
    static let cvdDistinctThreshold = 0.2

    /// A colour is achromatic (grey/black/white) when its RGB chroma is tiny. Achromatic
    /// colours carry no hue to confuse, so the CVD recolour LEAVES THEM UNCHANGED.
    static func isAchromatic(_ colour: SceneColor) -> Bool {
        let maxC = Swift.max(colour.red, colour.green, colour.blue)
        let minC = Swift.min(colour.red, colour.green, colour.blue)
        return (maxC - minC) < 0.12
    }

    /// Maps the CHROMATIC `distinct` colours to the CHROMATIC Okabe–Ito entries (never to
    /// black): each source takes the nearest-hue palette entry that keeps every mapped pair
    /// distinguishable under deuteranopia AND protanopia. Achromatic colours (greys, black,
    /// white) are omitted, so they pass through unchanged.
    static func colourBlindMap(_ distinct: [SceneColor]) -> [SceneColor: SceneColor] {
        let chromaticPalette = Array(okabeIto.dropFirst())   // drop black — only chromatic targets
        var map: [SceneColor: SceneColor] = [:]
        var assigned: [SceneColor] = []
        for source in distinct where !isAchromatic(source) {
            let hue = DrawingColorMath.toHSL(source).hue
            let ordered = chromaticPalette.sorted { hueDistance(hue, $0) < hueDistance(hue, $1) }
            var chosen = ordered[0]
            var bestMin = -1.0
            for candidate in ordered {
                let minDist = assigned.map { minSimulatedDistance(candidate, $0) }.min() ?? .infinity
                if assigned.isEmpty || minDist >= cvdDistinctThreshold { chosen = candidate; break }
                if minDist > bestMin { bestMin = minDist; chosen = candidate }
            }
            map[source] = chosen
            assigned.append(chosen)
        }
        return map
    }

    /// Circular hue distance (degrees) between a hue and a colour's hue.
    private static func hueDistance(_ hue: Double, _ colour: SceneColor) -> Double {
        let other = DrawingColorMath.toHSL(colour).hue
        let d = abs(hue - other).truncatingRemainder(dividingBy: 360)
        return Swift.min(d, 360 - d)
    }

    /// The smallest separation between two colours across the simulated dichromacies.
    private static func minSimulatedDistance(_ a: SceneColor, _ b: SceneColor) -> Double {
        DrawingColorMath.Dichromacy.allCases
            .map { DrawingColorMath.distance(DrawingColorMath.simulate(a, $0), DrawingColorMath.simulate(b, $0)) }
            .min() ?? 0
    }

    /// Darkens (or lightens) `colour` just enough to keep text legible against the page:
    /// to at least the original's contrast, or 4.5:1 when the original already met 4.5:1.
    /// Hue is preserved. Reuses the fix planner's contrast search.
    static func enforceTextContrast(_ colour: SceneColor, original: SceneColor) -> SceneColor {
        let originalContrast = DrawingColorMath.contrastRatio(
            DrawingColorMath.composite(original, over: assumedBackground), assumedBackground)
        let target = originalContrast >= 4.5 ? 4.5 : originalContrast
        let have = DrawingColorMath.contrastRatio(
            DrawingColorMath.composite(colour, over: assumedBackground), assumedBackground)
        if have >= target { return colour }
        return DrawingFixPlanner.contrastAdjustedColor(text: colour, background: assumedBackground, required: target)
    }

    // MARK: Brand (nearest by CIELAB ΔE)

    /// The brand colour nearest `colour` by CIELAB ΔE (ΔE76). Falls back to `colour` when
    /// no brand colours are given.
    static func nearestBrand(_ colour: SceneColor, brand: [SceneColor]) -> SceneColor {
        guard let first = brand.first else { return colour }
        let target = lab(colour)
        var best = first
        var bestDistance = deltaE(target, lab(first))
        for candidate in brand.dropFirst() {
            let distance = deltaE(target, lab(candidate))
            if distance < bestDistance { best = candidate; bestDistance = distance }
        }
        return best
    }

    /// The brand colour for a text run: the nearest brand colour (ΔE) among those that keep
    /// the run legible (contrast ≥ the original's, or ≥ 4.5 where the original met it); if
    /// none qualify, the brand colour with the highest contrast. `nil` when no brand given.
    static func nearestBrandForText(_ colour: SceneColor, brand: [SceneColor]) -> SceneColor? {
        guard !brand.isEmpty else { return nil }
        let originalContrast = DrawingColorMath.contrastRatio(
            DrawingColorMath.composite(colour, over: assumedBackground), assumedBackground)
        let target = originalContrast >= 4.5 ? 4.5 : originalContrast
        func contrast(_ candidate: SceneColor) -> Double {
            DrawingColorMath.contrastRatio(DrawingColorMath.composite(candidate, over: assumedBackground), assumedBackground)
        }
        let qualifying = brand.filter { contrast($0) >= target }
        if !qualifying.isEmpty { return nearestBrand(colour, brand: qualifying) }
        // None meet the target: fall back to the highest-contrast brand colour.
        return brand.max { contrast($0) < contrast($1) }
    }

    // MARK: CIELAB

    /// sRGB → CIELAB (D65), for perceptual nearest-colour matching.
    static func lab(_ colour: SceneColor) -> (l: Double, a: Double, b: Double) {
        let r = DrawingColorMath.linearize(colour.red)
        let g = DrawingColorMath.linearize(colour.green)
        let bl = DrawingColorMath.linearize(colour.blue)
        // Linear sRGB → XYZ (D65).
        let x = r * 0.4124 + g * 0.3576 + bl * 0.1805
        let y = r * 0.2126 + g * 0.7152 + bl * 0.0722
        let z = r * 0.0193 + g * 0.1192 + bl * 0.9505
        // Normalise by the D65 white point.
        let xn = x / 0.95047, yn = y / 1.0, zn = z / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116)
        }
        let fx = f(xn), fy = f(yn), fz = f(zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// ΔE76 (Euclidean distance in Lab) — simple, deterministic, enough for a nearest-of-a-
    /// handful match.
    static func deltaE(_ a: (l: Double, a: Double, b: Double), _ b: (l: Double, a: Double, b: Double)) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
