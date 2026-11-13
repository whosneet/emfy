import EMFEdit
import Foundation

// MARK: - Generate-a-drawing grounding + strict-output prompt (X2d)
//
// Builds the system instructions and the user prompt for "generate a drawing from a
// description". The model is told to output ONLY a GenerationPlan (the closed create-op
// vocabulary) as strict JSON, which then goes sanitiser → strict decode → validator →
// preview → confirm, so a model reply can never create a document without the user's
// confirmation (CLAUDE.md §8). The description is the USER's own request (trusted), but it
// is still sanitised for control characters before it reaches the prompt.

extension DrawingAIPrompt {
    /// The strict schema the model must emit for a generated drawing. Spelled out so the
    /// model knows the exact shape (providers can't always force a schema).
    static let generationPlanSchema = """
    Reply with ONLY one JSON object, no prose and no code fence, in exactly this shape:
    {"page":"a4-landscape","coords":"fraction","elements":[ ... ]}
    "page" is one of: a4-landscape, a4-portrait, letter-landscape, letter-portrait.
    ALWAYS use "coords":"fraction": every x, y, w, h is a fraction of the page from 0 to 1 \
    (0,0 is the top-left corner, 1,1 is the bottom-right). Keep every coordinate between 0 \
    and 1 and fully inside the page.
    Each element is one of (use these op names and field names exactly):
    - {"op":"rectangle","x":..,"y":..,"w":..,"h":..,"fill":"colour","stroke":"colour","strokeWidth":number}
    - {"op":"roundedRectangle","x":..,"y":..,"w":..,"h":..,"cornerRadius":..,"fill":"colour","stroke":"colour"}
    - {"op":"ellipse","x":..,"y":..,"w":..,"h":..,"fill":"colour","stroke":"colour"}
    - {"op":"line","x1":..,"y1":..,"x2":..,"y2":..,"stroke":"colour","strokeWidth":number}
    - {"op":"arrow","x1":..,"y1":..,"x2":..,"y2":..,"stroke":"colour","strokeWidth":number}
    - {"op":"polyline","points":[[x,y],[x,y],..],"stroke":"colour"}
    - {"op":"polygon","points":[[x,y],[x,y],..],"fill":"colour","stroke":"colour"}
    - {"op":"text","x":..,"y":..,"text":"the words","color":"colour","fontSize":number}
    A colour is a "#RRGGBB" string or a colour word ("blue", "dark blue", "red"). An arrow \
    is a line with an arrowhead at (x2,y2). For text, (x,y) is the label's top-left and \
    fontSize is in typographic points between 4 and 200.

    Shapes do NOT contain their own text: to label a box, add a SEPARATE text element placed \
    over it. Give every shape a fill or a stroke so it is visible. Use at most 300 elements, \
    and lay elements out so they do not all overlap.

    Keep EVERY shape fully inside the page: x and y are between 0 and 1, and x + w must be \
    1 or less and y + h must be 1 or less. A typical box is about 0.2 wide and 0.15 tall — \
    do NOT make a box wider than the space it has (three boxes in a row each need w of about \
    0.2, placed at x ≈ 0.06, 0.4 and 0.72, not 0.6).

    \(DrawingColorNames.promptGuidance())

    The reply MUST be strict, valid JSON: the top level is EXACTLY \
    {"page":"…","coords":"fraction","elements":[ … ]}. EVERY key and EVERY string value is \
    wrapped in double quotes, and a number is never followed by a quote. "coords" is always \
    the plain string "fraction". Emit an empty elements array only if the description cannot \
    be drawn with these shapes.

    Here is one complete, correctly-formed example for "a flowchart with three boxes \
    connected by arrows, labelled Start, Process, End":
    {"page":"a4-landscape","coords":"fraction","elements":[\
    {"op":"roundedRectangle","x":0.06,"y":0.4,"w":0.22,"h":0.18,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},\
    {"op":"roundedRectangle","x":0.39,"y":0.4,"w":0.22,"h":0.18,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},\
    {"op":"roundedRectangle","x":0.72,"y":0.4,"w":0.22,"h":0.18,"cornerRadius":0.02,"fill":"light blue","stroke":"dark blue","strokeWidth":2},\
    {"op":"arrow","x1":0.28,"y1":0.49,"x2":0.39,"y2":0.49,"stroke":"black","strokeWidth":2},\
    {"op":"arrow","x1":0.61,"y1":0.49,"x2":0.72,"y2":0.49,"stroke":"black","strokeWidth":2},\
    {"op":"text","x":0.1,"y":0.46,"text":"Start","color":"dark blue","fontSize":16},\
    {"op":"text","x":0.43,"y":0.46,"text":"Process","color":"dark blue","fontSize":16},\
    {"op":"text","x":0.78,"y":0.46,"text":"End","color":"dark blue","fontSize":16}]}
    """

    /// The system instructions for a generation: the role and the strict output contract.
    static let generateInstructions = """
    You are Emfy's drawing generator. You turn a short description into a simple vector \
    drawing, expressed as a precise, structured plan of shapes and text labels.

    \(generationPlanSchema)
    """

    /// The generate prompt: the user's (sanitised) description plus an optional page hint.
    static func generatePrompt(description: String, pageHint: String) -> String {
        let cleaned = DrawingAIContext.sanitizeLine(description)
        let hint = pageHint.isEmpty ? "" : "\n\(pageHint)"
        return """
        Create a drawing for this description: \(cleaned)\(hint)

        Reply with ONLY the JSON object described, and nothing else.
        """
    }
}

/// A page preset offered by the "New Drawing from Description…" sheet. Maps directly onto
/// `GenerationPage.Preset` (the model's declared page), so the user's choice forces the
/// generated page's size and orientation.
enum GenerationPagePreset: String, CaseIterable, Identifiable, Sendable {
    case a4Landscape
    case a4Portrait
    case letterLandscape
    case letterPortrait

    var id: String { rawValue }
    static let `default`: GenerationPagePreset = .a4Landscape

    var title: String {
        switch self {
        case .a4Landscape: return "A4 Landscape"
        case .a4Portrait: return "A4 Portrait"
        case .letterLandscape: return "US Letter Landscape"
        case .letterPortrait: return "US Letter Portrait"
        }
    }

    var planPreset: GenerationPage.Preset {
        switch self {
        case .a4Landscape: return .a4Landscape
        case .a4Portrait: return .a4Portrait
        case .letterLandscape: return .letterLandscape
        case .letterPortrait: return .letterPortrait
        }
    }

    /// The hint appended to the prompt so the model targets the chosen page.
    var promptHint: String {
        "Use the \(title) page."
    }
}
