import CoreGraphics
import Foundation

/// What a planned fix does, so the UI picks a label and icon (the model never
/// hard-codes display text, mirroring `SceneActionName`).
public enum DrawingFixKind: Sendable, Equatable {
    case darkenText
    case lightenText
    case enlargeText
    case adjustColor
}

/// A ready-to-apply fix for one finding: exactly one `SceneCommand`, plus the
/// before/after paint for the preview swatch. The app applies `command` through
/// `DocumentSession.apply` (undoable, with a preview/confirm); the planner never
/// mutates anything itself (design §3).
public struct PlannedFix: Sendable, Equatable {
    public var findingID: Int
    public var kind: DrawingFixKind
    public var elementID: Int
    public var command: SceneCommand
    /// The current paint of the edited element (for a before/after swatch); nil
    /// when the fix is a size change.
    public var beforeColor: SceneColor?
    public var afterColor: SceneColor?

    public init(findingID: Int, kind: DrawingFixKind, elementID: Int, command: SceneCommand, beforeColor: SceneColor? = nil, afterColor: SceneColor? = nil) {
        self.findingID = findingID
        self.kind = kind
        self.elementID = elementID
        self.command = command
        self.beforeColor = beforeColor
        self.afterColor = afterColor
    }
}

/// Pure planners that turn a `Finding` into one undoable `SceneCommand`. Every
/// planner refuses locked and passthrough elements (`rejectsMutation`), so no fix
/// ever touches verbatim content (design §3).
public enum DrawingFixPlanner {

    /// The grouped-undo name for a "Fix all of this kind" batch.
    public static let fixAllActionName = SceneActionName.group("edit.action.fixAll")

    /// Headroom added to the required contrast ratio when darkening/lightening text, so
    /// the fix still clears WCAG AA after the colour is quantised to an 8-bit COLORREF on
    /// save and re-imported (a fix landing exactly on 4.5:1 / 3.0:1 can otherwise regress
    /// to ~4.48:1 after a round-trip). Targets 4.6:1 for normal text and 3.1:1 for large.
    static let contrastFixMargin = 0.1

    /// Plans the single fix for `finding`, or nil when it is informational
    /// (unlabelled image) or the target element cannot be edited.
    public static func plan(for finding: Finding, in scene: Scene, config: DrawingAnalysis.Config = .init()) -> PlannedFix? {
        switch finding.kind {
        case .lowContrast(_, let required, _, let background, _):
            return planContrast(finding: finding, required: required, background: background, scene: scene)
        case .tinyText:
            return planTinyText(finding: finding, scene: scene, config: config)
        case .colorPair(_, _, let dichromacy):
            return planColorPair(finding: finding, dichromacy: dichromacy, scene: scene, config: config)
        case .unlabelledImage:
            return nil
        }
    }

    /// Every applicable fix for the findings of one kind, for "Fix all of this
    /// kind" (applied as one undo group by the caller).
    public static func planAll(like finding: Finding, findings: [Finding], in scene: Scene, config: DrawingAnalysis.Config = .init()) -> [PlannedFix] {
        findings
            .filter { sameFixFamily($0.kind, finding.kind) }
            .compactMap { plan(for: $0, in: scene, config: config) }
    }

    private static func sameFixFamily(_ a: Finding.Kind, _ b: Finding.Kind) -> Bool {
        switch (a, b) {
        case (.lowContrast, .lowContrast), (.tinyText, .tinyText), (.colorPair, .colorPair), (.unlabelledImage, .unlabelledImage):
            return true
        default:
            return false
        }
    }

    // MARK: - Contrast

    private static func planContrast(finding: Finding, required: Double, background: SceneColor, scene: Scene) -> PlannedFix? {
        guard let id = finding.elementIDs.first,
              let element = editableText(id: id, in: scene),
              let text = element.text
        else { return nil }
        let newColor = contrastAdjustedColor(text: text.color, background: background, required: required)
        let darken = DrawingColorMath.relativeLuminance(newColor) < DrawingColorMath.relativeLuminance(text.color)
        let fill = SceneFill(color: newColor, evenOdd: element.style.fill?.evenOdd ?? false, gradient: nil)
        return PlannedFix(
            findingID: finding.id,
            kind: darken ? .darkenText : .lightenText,
            elementID: id,
            command: .setFill(ids: [id], fill),
            beforeColor: text.color,
            afterColor: newColor
        )
    }

    /// The colour nearest `text` along the lightness axis (hue and saturation kept)
    /// that reaches `required` contrast against `background` (design §3). Darkens
    /// against a light background, lightens against a dark one; falls back to the
    /// stronger extreme when neither side can reach the ratio.
    static func contrastAdjustedColor(text: SceneColor, background: SceneColor, required: Double) -> SceneColor {
        // Aim past the bare threshold so the fix survives the 8-bit COLORREF round-trip.
        let target = required + contrastFixMargin
        let hsl = DrawingColorMath.toHSL(text)
        func colorAt(_ l: Double) -> SceneColor {
            DrawingColorMath.fromHSL(hue: hsl.hue, saturation: hsl.saturation, lightness: l, alpha: text.alpha)
        }
        func ratioAt(_ l: Double) -> Double {
            DrawingColorMath.contrastRatio(DrawingColorMath.composite(colorAt(l), over: background), background)
        }
        if ratioAt(hsl.lightness) >= target { return text }   // already fine (no-op)

        let darkReaches = ratioAt(0) >= target
        let lightReaches = ratioAt(1) >= target

        func searchDarken() -> Double {   // largest l in [0, l0] that meets
            var lo = 0.0, hi = hsl.lightness
            for _ in 0 ..< 48 { let mid = (lo + hi) / 2; if ratioAt(mid) >= target { lo = mid } else { hi = mid } }
            return lo
        }
        func searchLighten() -> Double {  // smallest l in [l0, 1] that meets
            var lo = hsl.lightness, hi = 1.0
            for _ in 0 ..< 48 { let mid = (lo + hi) / 2; if ratioAt(mid) >= target { hi = mid } else { lo = mid } }
            return hi
        }

        switch (darkReaches, lightReaches) {
        case (true, true):
            let dl = searchDarken(), ll = searchLighten()
            return abs(dl - hsl.lightness) <= abs(ll - hsl.lightness) ? colorAt(dl) : colorAt(ll)
        case (true, false):
            return colorAt(searchDarken())
        case (false, true):
            return colorAt(searchLighten())
        case (false, false):
            return ratioAt(0) >= ratioAt(1) ? colorAt(0) : colorAt(1)
        }
    }

    // MARK: - Tiny text

    private static func planTinyText(finding: Finding, scene: Scene, config: DrawingAnalysis.Config) -> PlannedFix? {
        guard let id = finding.elementIDs.first,
              let element = editableText(id: id, in: scene),
              let text = element.text,
              !text.isEMFPlus                       // GDI runs only: setFont drives logicalHeight ([MS-EMF] §2.2.13)
        else { return nil }
        let perPoint = Double(scene.deviceUnitsPerPoint)
        let vScale = Double(DrawingAnalysis.verticalScale(element.transform))
        guard perPoint > 0, vScale > 0 else { return nil }
        // Smallest logical em height whose print size reaches the threshold.
        let newLogical = Int32((config.tinyTextPoint * perPoint / vScale).rounded(.up))
        guard newLogical > abs(text.logicalHeight) else { return nil }
        return PlannedFix(
            findingID: finding.id,
            kind: .enlargeText,
            elementID: id,
            command: .setFont(id: id, family: text.fontFamily, size: newLogical, bold: text.bold, italic: text.italic)
        )
    }

    // MARK: - Colour pair

    private static func planColorPair(finding: Finding, dichromacy: DrawingColorMath.Dichromacy, scene: Scene, config: DrawingAnalysis.Config) -> PlannedFix? {
        // Edit whichever element of the pair is editable (prefer the second).
        let candidates = Array(finding.elementIDs.reversed())
        guard let targetID = candidates.first(where: { editableFilled(id: $0, in: scene) != nil }),
              let target = editableFilled(id: targetID, in: scene),
              let targetFill = target.style.fill,
              let otherID = finding.elementIDs.first(where: { $0 != targetID }),
              let other = scene.elements.first(where: { $0.id == otherID }),
              let otherColor = other.style.fill?.color
        else { return nil }

        guard let newColor = separatedColor(target: targetFill.color, other: otherColor, config: config) else { return nil }
        let fill = SceneFill(color: newColor, evenOdd: targetFill.evenOdd, gradient: nil)
        return PlannedFix(
            findingID: finding.id,
            kind: .adjustColor,
            elementID: targetID,
            command: .setFill(ids: [targetID], fill),
            beforeColor: targetFill.color,
            afterColor: newColor
        )
    }

    /// Shifts `target`'s lightness (hue/saturation kept) until it separates from
    /// `other` under BOTH dichromacies — a luminance difference survives colour-blind
    /// simulation. Returns the smallest such change, or nil if none helps.
    static func separatedColor(target: SceneColor, other: SceneColor, config: DrawingAnalysis.Config) -> SceneColor? {
        let want = config.pairSimulatedSame + 0.06   // clear the flag with margin
        let hsl = DrawingColorMath.toHSL(target)
        func colorAt(_ l: Double) -> SceneColor {
            DrawingColorMath.fromHSL(hue: hsl.hue, saturation: hsl.saturation, lightness: l.clamped(0, 1), alpha: target.alpha)
        }
        func separates(_ color: SceneColor) -> Bool {
            DrawingColorMath.Dichromacy.allCases.allSatisfy { type in
                DrawingColorMath.distance(DrawingColorMath.simulate(color, type), DrawingColorMath.simulate(other, type)) > want
            }
        }
        var step = 0.04
        while step <= 1.0 {
            for candidate in [colorAt(hsl.lightness + step), colorAt(hsl.lightness - step)] where candidate.alpha >= 0 {
                if separates(candidate) { return candidate }
            }
            step += 0.04
        }
        // Fall back to the extreme with the most separation.
        let black = colorAt(0), white = colorAt(1)
        if separates(black) || separates(white) {
            return separates(white) ? white : black
        }
        return nil
    }

    // MARK: - Element lookups

    private static func editableText(id: Int, in scene: Scene) -> Element? {
        guard let element = scene.elements.first(where: { $0.id == id }),
              element.kind == .text, element.text != nil, !element.rejectsMutation
        else { return nil }
        return element
    }

    private static func editableFilled(id: Int, in scene: Scene) -> Element? {
        guard let element = scene.elements.first(where: { $0.id == id }),
              element.kind != .text, element.style.fill != nil, !element.rejectsMutation
        else { return nil }
        return element
    }
}
