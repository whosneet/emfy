import EMFEdit
import Foundation
import FoundationModels

// MARK: - @Generable mirror plans for the on-device path (F3)
//
// The on-device model path for Edit, Translate and New-Drawing uses GUIDED generation
// (`respond(to:generating:)`) instead of free-form JSON: constrained decoding guarantees
// a structurally valid reply, so the weak 3B model can't drop a quote or invent a key.
// These `@Generable` types are the shape the model fills; they are then MAPPED onto the
// existing domain plans (`EditPlan`, `[TranslationEntry]`, `GenerationPlan`) and re-emitted
// as the SAME JSON the provider (free-form) path produces, so the one downstream pipeline —
// sanitiser → strict decode → validator → preview → confirm — is unchanged and nothing
// applies without the user's confirmation (docs/v3-plan §11; CLAUDE.md §8).
//
// `EditOperation` and `GenerationOp` are enums with associated values. A `@Generable`
// mirror of an enum-with-payload is awkward for a small model, so each is modelled as a
// FLATTENED struct: a `kind` discriminator (a `@Generable` enum) plus optional fields, and
// the mapping picks the fields that kind needs. The mapping does NOT validate — it only
// shapes — so an out-of-range number or unreadable colour maps through and is caught by the
// shared validator, exactly as on the JSON path.
//
// Everything here is gated to macOS 26 / iOS 26 (the `@Generable` macro emits
// FoundationModels types); the app and tests still compile at the 14/17 floor.

// MARK: - Edit plan mirror (the 11-case EditOperation vocabulary)

@available(macOS 26, iOS 26, *)
@Generable
enum GenEditOpKind: Equatable {
    case recolorFill, recolorStroke, setText, setFontSize, setFontFamily
    case move, scale, setLineWidth, align, distribute, delete
}

@available(macOS 26, iOS 26, *)
@Generable
enum GenAlignEdge: Equatable {
    case left, right, top, bottom, centerHorizontal, centerVertical

    var domain: PlanAlignEdge {
        switch self {
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .centerHorizontal: return .centerHorizontal
        case .centerVertical: return .centerVertical
        }
    }
}

@available(macOS 26, iOS 26, *)
@Generable
enum GenDistributeAxis: Equatable {
    case horizontal, vertical

    var domain: PlanDistributeAxis { self == .horizontal ? .horizontal : .vertical }
}

/// One flattened edit operation. Only the fields its `op` needs are read by the mapping.
@available(macOS 26, iOS 26, *)
@Generable
struct GenEditOperation: Equatable {
    @Guide(description: "The kind of edit to make.")
    var op: GenEditOpKind
    @Guide(description: "The element ids to change together, for recolorFill, recolorStroke, move, scale, setLineWidth, align, distribute and delete. Use the ids listed in the drawing data.")
    var ids: [Int]?
    @Guide(description: "The single element id for setText, setFontSize and setFontFamily.")
    var id: Int?
    @Guide(description: "A #RRGGBB hex colour, for recolorFill and recolorStroke.")
    var color: String?
    @Guide(description: "The replacement text, for setText.")
    var text: String?
    @Guide(description: "A typographic point size: the font size for setFontSize, or the line width for setLineWidth.")
    var points: Double?
    @Guide(description: "The font family name, for setFontFamily.")
    var family: String?
    @Guide(description: "The horizontal move distance in device units, for move.")
    var dx: Double?
    @Guide(description: "The vertical move distance in device units, for move.")
    var dy: Double?
    @Guide(description: "The scale factor (1 = no change), for scale.")
    var factor: Double?
    @Guide(description: "The edge to align to, for align.")
    var edge: GenAlignEdge?
    @Guide(description: "The axis to distribute along, for distribute.")
    var axis: GenDistributeAxis?

    /// Maps this generated op onto the domain `EditOperation`, or nil when a field its kind
    /// requires is absent (dropped, like a strict-decode miss). No validation here.
    func toDomain() -> EditOperation? {
        switch op {
        case .recolorFill:
            guard let ids, let color else { return nil }
            return .recolorFill(ids: ids, color: PlanColor(hex: color))
        case .recolorStroke:
            guard let ids, let color else { return nil }
            return .recolorStroke(ids: ids, color: PlanColor(hex: color))
        case .setText:
            guard let id, let text else { return nil }
            return .setText(id: id, text: text)
        case .setFontSize:
            guard let id, let points else { return nil }
            return .setFontSize(id: id, points: points)
        case .setFontFamily:
            guard let id, let family else { return nil }
            return .setFontFamily(id: id, family: family)
        case .move:
            guard let ids, let dx, let dy else { return nil }
            return .move(ids: ids, dx: dx, dy: dy)
        case .scale:
            guard let ids, let factor else { return nil }
            return .scale(ids: ids, factor: factor)
        case .setLineWidth:
            guard let ids, let points else { return nil }
            return .setLineWidth(ids: ids, points: points)
        case .align:
            guard let ids, let edge else { return nil }
            return .align(ids: ids, edge: edge.domain)
        case .distribute:
            guard let ids, let axis else { return nil }
            return .distribute(ids: ids, axis: axis.domain)
        case .delete:
            guard let ids else { return nil }
            return .delete(ids: ids)
        }
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct GenEditPlan: Equatable {
    @Guide(description: "The edit operations to apply, in order. Empty if the request can't be expressed with these operations.")
    var operations: [GenEditOperation]

    /// The domain `EditPlan`. An op missing a required field is dropped (not invented),
    /// so an all-unmappable reply becomes an empty plan the caller retries.
    func toDomain() -> EditPlan {
        EditPlan(operations: operations.compactMap { $0.toDomain() })
    }
}

// MARK: - Translations mirror ({id, text}[])

@available(macOS 26, iOS 26, *)
@Generable
struct GenTranslation: Equatable {
    @Guide(description: "The item id to reuse, exactly as shown after the # for this item.")
    var id: Int
    @Guide(description: "The item's text translated into the target language.")
    var text: String
}

@available(macOS 26, iOS 26, *)
@Generable
struct GenTranslations: Equatable {
    @Guide(description: "One entry for every item, reusing each item's id.")
    var translations: [GenTranslation]

    /// The domain entries, for direct reconciliation in tests.
    func toEntries() -> [TranslationEntry] {
        translations.map { TranslationEntry(id: $0.id, text: $0.text) }
    }

    /// The `{"translations":[{"id":N,"text":"…"}]}` JSON the shared decode/reconcile path
    /// expects, built with `JSONSerialization` so any text is escaped safely.
    func toJSON() -> String {
        let array = translations.map { ["id": $0.id, "text": $0.text] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["translations": array]) else {
            return "{\"translations\":[]}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Generation plan mirror (the 8 create-ops)

@available(macOS 26, iOS 26, *)
@Generable
enum GenGenerateOpKind: Equatable {
    case rectangle, roundedRectangle, ellipse, line, arrow, polyline, polygon, text
}

@available(macOS 26, iOS 26, *)
@Generable
enum GenPagePreset: Equatable {
    case a4Landscape, a4Portrait, letterLandscape, letterPortrait

    var domain: GenerationPage.Preset {
        switch self {
        case .a4Landscape: return .a4Landscape
        case .a4Portrait: return .a4Portrait
        case .letterLandscape: return .letterLandscape
        case .letterPortrait: return .letterPortrait
        }
    }
}

/// A point for polyline / polygon, as x and y in the plan's (fraction) coordinate space.
@available(macOS 26, iOS 26, *)
@Generable
struct GenPointXY: Equatable {
    @Guide(description: "The x coordinate, a fraction of the page width from 0 to 1.")
    var x: Double
    @Guide(description: "The y coordinate, a fraction of the page height from 0 to 1.")
    var y: Double
}

/// One flattened create-op. Only the fields its `op` needs are read by the mapping. All
/// coordinates are fractions of the page (0…1); strokeWidth and fontSize are points.
@available(macOS 26, iOS 26, *)
@Generable
struct GenGenerateOperation: Equatable {
    @Guide(description: "The kind of shape or label to create.")
    var op: GenGenerateOpKind
    @Guide(description: "Left edge (fraction 0…1), for rectangle, roundedRectangle, ellipse and text.")
    var x: Double?
    @Guide(description: "Top edge (fraction 0…1), for rectangle, roundedRectangle, ellipse and text.")
    var y: Double?
    @Guide(description: "Width (fraction 0…1), for rectangle, roundedRectangle and ellipse.")
    var w: Double?
    @Guide(description: "Height (fraction 0…1), for rectangle, roundedRectangle and ellipse.")
    var h: Double?
    @Guide(description: "Start x (fraction 0…1), for line and arrow.")
    var x1: Double?
    @Guide(description: "Start y (fraction 0…1), for line and arrow.")
    var y1: Double?
    @Guide(description: "End x (fraction 0…1), for line and arrow.")
    var x2: Double?
    @Guide(description: "End y (fraction 0…1), for line and arrow.")
    var y2: Double?
    @Guide(description: "Corner radius (fraction), for roundedRectangle.")
    var cornerRadius: Double?
    @Guide(description: "The points, for polyline and polygon.")
    var points: [GenPointXY]?
    @Guide(description: "Fill colour: a #RRGGBB hex value or a colour word like \"blue\".")
    var fill: String?
    @Guide(description: "Stroke (outline) colour: a #RRGGBB hex value or a colour word.")
    var stroke: String?
    @Guide(description: "Stroke width in typographic points.")
    var strokeWidth: Double?
    @Guide(description: "The words to show, for text.")
    var text: String?
    @Guide(description: "Text colour: a #RRGGBB hex value or a colour word, for text.")
    var color: String?
    @Guide(description: "Text size in typographic points (4 to 200), for text.")
    var fontSize: Double?
    @Guide(description: "Font family name, for text.")
    var fontFamily: String?

    private func gen(_ raw: String?) -> GenColor? { raw.map { GenColor(raw: $0) } }

    /// Maps this generated op onto the domain `GenerationOp`, or nil when a field its kind
    /// requires is absent. No validation here — the shared validator bounds-checks.
    func toDomain() -> GenerationOp? {
        switch op {
        case .rectangle:
            guard let x, let y, let w, let h else { return nil }
            return .rectangle(x: x, y: y, w: w, h: h, fill: gen(fill), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .roundedRectangle:
            guard let x, let y, let w, let h else { return nil }
            return .roundedRectangle(x: x, y: y, w: w, h: h, cornerRadius: cornerRadius ?? 0,
                                     fill: gen(fill), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .ellipse:
            guard let x, let y, let w, let h else { return nil }
            return .ellipse(x: x, y: y, w: w, h: h, fill: gen(fill), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .line:
            guard let x1, let y1, let x2, let y2 else { return nil }
            return .line(from: GenPoint(x: x1, y: y1), to: GenPoint(x: x2, y: y2), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .arrow:
            guard let x1, let y1, let x2, let y2 else { return nil }
            return .arrow(from: GenPoint(x: x1, y: y1), to: GenPoint(x: x2, y: y2), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .polyline:
            guard let points else { return nil }
            return .polyline(points: points.map { GenPoint(x: $0.x, y: $0.y) }, stroke: gen(stroke), strokeWidth: strokeWidth)
        case .polygon:
            guard let points else { return nil }
            return .polygon(points: points.map { GenPoint(x: $0.x, y: $0.y) }, fill: gen(fill), stroke: gen(stroke), strokeWidth: strokeWidth)
        case .text:
            guard let x, let y, let text else { return nil }
            return .text(x: x, y: y, w: w, h: h, string: text, color: gen(color), fontSize: fontSize ?? 16, fontFamily: fontFamily)
        }
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct GenGeneratePlan: Equatable {
    @Guide(description: "The page size and orientation.")
    var page: GenPagePreset
    @Guide(description: "The shapes and text labels that make up the drawing, in order.")
    var elements: [GenGenerateOperation]

    /// The domain `GenerationPlan` (coordinates are always fractions of the page). An op
    /// missing a required field is dropped, so an all-unmappable reply becomes empty.
    func toDomain() -> GenerationPlan {
        GenerationPlan(page: GenerationPage(preset: page.domain, coordinateSpace: .fraction),
                       operations: elements.compactMap { $0.toDomain() })
    }
}

// MARK: - Guided on-device generation (one code path for the models and the eval)

/// Runs the on-device model with guided generation and returns the SAME JSON string the
/// free-form provider path produces, so every caller shares one downstream pipeline.
@available(macOS 26, iOS 26, *)
enum DrawingAIGuided {
    /// An AI edit as the EditPlan JSON (`{"operations":[…]}`), via guided generation.
    static func editPlanJSON(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let generated = try await session.respond(to: prompt, generating: GenEditPlan.self).content
        return generated.toDomain().json()
    }

    /// A translation batch as the translations JSON (`{"translations":[…]}`), via guided generation.
    static func translationsJSON(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let generated = try await session.respond(to: prompt, generating: GenTranslations.self).content
        return generated.toJSON()
    }

    /// A generated drawing as the GenerationPlan JSON, via guided generation.
    static func generationPlanJSON(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let generated = try await session.respond(to: prompt, generating: GenGeneratePlan.self).content
        return generated.toDomain().json()
    }
}
