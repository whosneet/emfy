import CoreGraphics
import Foundation

// MARK: - Edit grounding semantics (X2b)
//
// Deterministic helpers that make an AI edit TARGETABLE by a small model: a readable
// name for a colour, a curated colour-word → hex table (so "dark blue" lands on a real
// dark blue, not pure #0000FF), and a text-role classifier (heading-like / body /
// small/footnote) derived only from the runs' sizes and positions. All pure and
// platform-free (Foundation + CoreGraphics only), so they drive both the grounding
// context the model sees AND the eval suite's semantic scoring, and are unit-tested in
// EMFKit without a model.

/// A named colour with a canonical hex, used both to NAME an arbitrary colour (nearest
/// entry) and to resolve a colour WORD a user typed ("dark blue") to a sensible target.
public struct NamedColor: Sendable, Equatable {
    public let name: String
    public let color: SceneColor

    public init(name: String, color: SceneColor) {
        self.name = name
        self.color = color
    }
}

public enum DrawingColorNames {

    /// The curated palette. Chosen so each entry is a readable, non-garish value a user
    /// would recognise by name (e.g. "dark blue" is a deep navy-blue, not #0000FF). The
    /// same table resolves a typed colour word and names an element's existing colour.
    public static let palette: [NamedColor] = [
        NamedColor(name: "black", color: hex(0x000000)),
        NamedColor(name: "white", color: hex(0xFFFFFF)),
        NamedColor(name: "grey", color: hex(0x7F8C8D)),
        NamedColor(name: "dark grey", color: hex(0x3B3F42)),
        NamedColor(name: "light grey", color: hex(0xBDC3C7)),
        NamedColor(name: "red", color: hex(0xC0392B)),
        NamedColor(name: "dark red", color: hex(0x8B1A1A)),
        NamedColor(name: "orange", color: hex(0xE67E22)),
        NamedColor(name: "yellow", color: hex(0xF1C40F)),
        NamedColor(name: "green", color: hex(0x1E8449)),
        NamedColor(name: "dark green", color: hex(0x145A32)),
        NamedColor(name: "light green", color: hex(0x82E0AA)),
        NamedColor(name: "teal", color: hex(0x0E7C7B)),
        NamedColor(name: "cyan", color: hex(0x17A2B8)),
        NamedColor(name: "light blue", color: hex(0x7FB2F0)),
        NamedColor(name: "blue", color: hex(0x2E5BDA)),
        NamedColor(name: "dark blue", color: hex(0x1F3A93)),
        NamedColor(name: "navy", color: hex(0x1B2A52)),
        NamedColor(name: "purple", color: hex(0x7D3C98)),
        NamedColor(name: "magenta", color: hex(0xC0399B)),
        NamedColor(name: "pink", color: hex(0xE84393)),
        NamedColor(name: "brown", color: hex(0x8A5A2B)),
    ]

    /// The readable name of the palette entry nearest `color` (CIELAB ΔE), e.g. "dark
    /// blue". Used to annotate each element's hex in the grounding context.
    public static func name(for color: SceneColor) -> String {
        let opaque = SceneColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        var best = palette[0]
        var bestDistance = Double.greatestFiniteMagnitude
        for entry in palette {
            let d = DrawingColorMath.deltaE(opaque, entry.color)
            if d < bestDistance { bestDistance = d; best = entry }
        }
        return best.name
    }

    /// Resolves a colour word or short phrase ("dark blue", "navy", "bright red") to a
    /// sensible `SceneColor`, or `nil` when no colour word is recognised. An exact palette
    /// name wins; otherwise a base hue word plus an optional "dark"/"light"/"deep"/"pale"/
    /// "bright" modifier is synthesised, so unusual combinations still land somewhere
    /// reasonable rather than on a pure primary.
    public static func color(forPhrase phrase: String) -> SceneColor? {
        let lowered = phrase.lowercased()
        let words = lowered.split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return nil }
        // Exact palette name (e.g. "dark blue", "navy").
        let joined = words.joined(separator: " ")
        if let exact = palette.first(where: { $0.name == joined }) { return exact.color }
        // Base hue word.
        let bases: [String: Double] = [
            "red": 2, "orange": 30, "yellow": 52, "green": 130, "teal": 178, "cyan": 190,
            "blue": 222, "navy": 222, "purple": 280, "violet": 280, "magenta": 312,
            "pink": 330, "brown": 24,
        ]
        guard let baseWord = words.first(where: { bases[$0] != nil }), let hue = bases[baseWord] else {
            // Neutral words.
            if words.contains("black") { return hex(0x000000) }
            if words.contains("white") { return hex(0xFFFFFF) }
            if words.contains("grey") || words.contains("gray") {
                if words.contains("dark") { return hex(0x3B3F42) }
                if words.contains("light") { return hex(0xBDC3C7) }
                return hex(0x7F8C8D)
            }
            return nil
        }
        var saturation = 0.68
        var lightness = 0.44
        if baseWord == "navy" { lightness = 0.24 }
        if baseWord == "brown" { saturation = 0.52; lightness = 0.34 }
        if baseWord == "pink" { saturation = 0.72; lightness = 0.62 }
        if words.contains("dark") || words.contains("deep") { lightness = 0.26 }
        if words.contains("light") || words.contains("pale") { lightness = 0.72; saturation = 0.55 }
        if words.contains("bright") || words.contains("vivid") { saturation = 0.9; lightness = 0.5 }
        return DrawingColorMath.fromHSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// A compact "word → hex" guidance line for the model prompt, drawn from the palette,
    /// so the model prefers a real named colour over a raw primary.
    public static func promptGuidance() -> String {
        let entries = palette
            .filter { $0.name != "light green" && $0.name != "cyan" && $0.name != "magenta" }
            .map { "\($0.name) \(PlanColor($0.color).hex)" }
            .joined(separator: ", ")
        return "Colour words map to these hex values: \(entries). Prefer one of these over a pure primary such as #0000FF or #00FF00."
    }

    private static func hex(_ rgb: UInt32) -> SceneColor {
        SceneColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Text role classification

/// A deterministic role hint for a text run, so the model can map "the headings", "the
/// body text" or "the footnote" to concrete ids.
public enum TextRole: String, Sendable, Equatable {
    case heading
    case body
    case small
}

public enum TextRoleClassifier {
    /// One text run's measurable features: its id, print size (points), and the top of
    /// its device bounds (smaller = higher on the page).
    public struct Run: Sendable, Equatable {
        public let id: Int
        public let pointSize: Double
        public let top: Double
        public init(id: Int, pointSize: Double, top: Double) {
            self.id = id
            self.pointSize = pointSize
            self.top = top
        }
    }

    /// Classifies each run as heading / body / small from the SIZE distribution. With no
    /// size variation every run is `body`. A run in the largest size tier is a `heading`;
    /// one clearly smaller than the body (≤ 70% of the median body size) is `small`.
    public static func classify(_ runs: [Run]) -> [Int: TextRole] {
        guard runs.count > 1 else {
            // A single run is "body" — there is nothing to contrast it against.
            return runs.reduce(into: [:]) { $0[$1.id] = .body }
        }
        let sizes = runs.map(\.pointSize).sorted()
        let maxSize = sizes.last ?? 0
        let minSize = sizes.first ?? 0
        guard maxSize - minSize > 0.5 else {
            return runs.reduce(into: [:]) { $0[$1.id] = .body }
        }
        // The "body" reference is the median size of the runs that are NOT in the top tier.
        let headingThreshold = maxSize * 0.9
        let nonHeading = sizes.filter { $0 < headingThreshold }
        let bodyReference = median(nonHeading.isEmpty ? sizes : nonHeading)
        var out: [Int: TextRole] = [:]
        for run in runs {
            if run.pointSize >= headingThreshold {
                out[run.id] = .heading
            } else if run.pointSize <= bodyReference * 0.7 {
                out[run.id] = .small
            } else {
                out[run.id] = .body
            }
        }
        return out
    }

    /// The id of the single most title-like run: the largest, ties broken by the topmost
    /// position. `nil` for an empty list. Used to label a likely title in the context.
    public static func titleID(_ runs: [Run]) -> Int? {
        runs.max { lhs, rhs in
            if lhs.pointSize != rhs.pointSize { return lhs.pointSize < rhs.pointSize }
            return lhs.top > rhs.top   // higher on page wins the tie
        }?.id
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
