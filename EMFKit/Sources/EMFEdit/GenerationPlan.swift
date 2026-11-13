import CoreGraphics
import Foundation

// MARK: - A typed, bounded drawing-generation plan (X2d)
//
// A small CLOSED vocabulary of create-operations that an AI "generate a drawing from a
// description" turns into a brand-new editable scene (docs/v3-plan §11.1). The model emits
// a `GenerationPlan` as JSON — never raw records and never a mutation of an existing scene.
// The plan is decoded strictly, validated (`GenerationPlanValidator`), and only then mapped
// onto the SAME `SceneFactory` creation calls the E3 shape/text tools use, producing a new
// `Scene` the user previews and confirms before anything opens. The plan itself is inert.
//
// Security (CLAUDE.md §8 / axiom-security): the JSON is untrusted model output. The decoder
// is strict (an unknown op is a typed error; extra fields are never acted on) and every
// number is bounds-checked by the validator before any geometry is built. Nothing here
// force-unwraps or does unchecked arithmetic.

// MARK: - Colours

/// A colour carried in a generation plan as a raw string: a hex value (`#RRGGBB`, …) OR a
/// colour word/phrase ("dark blue", "navy") resolved through `DrawingColorNames`. Kept as
/// the raw string so a malformed colour is a validator problem, not a decode trap.
public struct GenColor: Sendable, Equatable, Codable {
    /// The colour exactly as the plan gave it (for diagnostics).
    public var raw: String

    public init(raw: String) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    /// The resolved colour, or `nil` when `raw` is neither a valid hex colour nor a
    /// recognised colour word.
    public var color: SceneColor? {
        if let hex = PlanColor.parse(raw) { return hex }
        return DrawingColorNames.color(forPhrase: raw)
    }
}

// MARK: - Page

/// The page a generation plan declares, and the coordinate space its element coordinates
/// live in. A preset gives the millimetre size; the coordinate space is either `fraction`
/// (0…1 of the page) or `points` (typographic points within the page).
public struct GenerationPage: Sendable, Equatable, Codable {

    /// A standard page size and orientation. The millimetre sizes match
    /// `SceneFactory.blankDocument`'s presets (width, height).
    public enum Preset: String, Sendable, Equatable, Codable, CaseIterable {
        case a4Landscape = "a4-landscape"
        case a4Portrait = "a4-portrait"
        case letterLandscape = "letter-landscape"
        case letterPortrait = "letter-portrait"

        /// The page size in millimetres (width, height).
        public var sizeMillimetres: CGSize {
            switch self {
            case .a4Landscape: return CGSize(width: 297, height: 210)
            case .a4Portrait: return CGSize(width: 210, height: 297)
            case .letterLandscape: return CGSize(width: 279.4, height: 215.9)
            case .letterPortrait: return CGSize(width: 215.9, height: 279.4)
            }
        }
    }

    /// How a plan's element coordinates are expressed.
    public enum CoordinateSpace: String, Sendable, Equatable, Codable {
        /// x/y/w/h are fractions of the page (0 = left/top, 1 = right/bottom).
        case fraction
        /// x/y/w/h are typographic points (1/72 inch) within the page.
        case points
    }

    public var preset: Preset
    public var coordinateSpace: CoordinateSpace

    public init(preset: Preset = .a4Landscape, coordinateSpace: CoordinateSpace = .fraction) {
        self.preset = preset
        self.coordinateSpace = coordinateSpace
    }

    private enum CodingKeys: String, CodingKey { case page, coords }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preset = (try? container.decodeIfPresent(Preset.self, forKey: .page)) ?? .a4Landscape
        self.coordinateSpace = (try? container.decodeIfPresent(CoordinateSpace.self, forKey: .coords)) ?? .fraction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .page)
        try container.encode(coordinateSpace, forKey: .coords)
    }

    /// The page size in the plan's own coordinate space — `(1, 1)` for `fraction`, the
    /// page's point size for `points`.
    public var extent: CGSize {
        switch coordinateSpace {
        case .fraction: return CGSize(width: 1, height: 1)
        case .points:
            let mm = preset.sizeMillimetres
            return CGSize(width: Double(mm.width) / 25.4 * 72, height: Double(mm.height) / 25.4 * 72)
        }
    }
}

// MARK: - A point in the plan's coordinate space

/// A 2-D point in the plan's declared coordinate space. Decoded from `[x, y]` (a two-number
/// array) so a polyline/polygon reads naturally.
public struct GenPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.x = try container.decode(Double.self)
        self.y = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

// MARK: - Operations

/// One create-operation in a generation plan. The closed set is the ENTIRE generation
/// vocabulary — anything else is refused at decode. All coordinates are in the plan's
/// declared coordinate space; `strokeWidth` and `fontSize` are typographic points.
public enum GenerationOp: Sendable, Equatable {
    /// A filled/stroked axis-aligned rectangle at (x, y, w, h).
    case rectangle(x: Double, y: Double, w: Double, h: Double, fill: GenColor?, stroke: GenColor?, strokeWidth: Double?)
    /// A rounded rectangle; `cornerRadius` is in the coordinate space.
    case roundedRectangle(x: Double, y: Double, w: Double, h: Double, cornerRadius: Double, fill: GenColor?, stroke: GenColor?, strokeWidth: Double?)
    /// An ellipse inscribed in (x, y, w, h).
    case ellipse(x: Double, y: Double, w: Double, h: Double, fill: GenColor?, stroke: GenColor?, strokeWidth: Double?)
    /// A straight line from (x1, y1) to (x2, y2).
    case line(from: GenPoint, to: GenPoint, stroke: GenColor?, strokeWidth: Double?)
    /// A line with an arrowhead at its `to` end (a line plus a filled-triangle head).
    case arrow(from: GenPoint, to: GenPoint, stroke: GenColor?, strokeWidth: Double?)
    /// An open polyline through the given points.
    case polyline(points: [GenPoint], stroke: GenColor?, strokeWidth: Double?)
    /// A closed polygon through the given points.
    case polygon(points: [GenPoint], fill: GenColor?, stroke: GenColor?, strokeWidth: Double?)
    /// A text label with its top-left at (x, y); `fontSize` is in points.
    case text(x: Double, y: Double, w: Double?, h: Double?, string: String, color: GenColor?, fontSize: Double, fontFamily: String?)

    /// The JSON discriminator for this operation.
    public var opName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "roundedRectangle"
        case .ellipse: return "ellipse"
        case .line: return "line"
        case .arrow: return "arrow"
        case .polyline: return "polyline"
        case .polygon: return "polygon"
        case .text: return "text"
        }
    }

    /// Whether this op draws a text label (for the summary count).
    public var isText: Bool { if case .text = self { return true } else { return false } }
}

/// A generation plan: a declared page plus an ordered list of create-operations. Pure
/// value type; mutates nothing.
public struct GenerationPlan: Sendable, Equatable {
    public var page: GenerationPage
    public var operations: [GenerationOp]

    public init(page: GenerationPage, operations: [GenerationOp]) {
        self.page = page
        self.operations = operations
    }
}

// MARK: - Strict JSON coding

/// Why decoding a generation plan from JSON failed. A decode failure means NOTHING is created.
public enum GenerationPlanDecodingError: Error, Sendable, Equatable {
    /// The `op` field named an operation outside the closed vocabulary.
    case unknownOperation(String)
    /// A required field for the operation was missing.
    case missingField(op: String, field: String)
    /// The JSON wasn't the required shape.
    case malformed(String)
}

extension GenerationOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, x, y, w, h, x1, y1, x2, y2, points, cornerRadius
        case fill, stroke, strokeWidth, text, color, fontSize, fontFamily
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)

        func req(_ key: CodingKeys, _ field: String) throws -> Double {
            guard let v = try c.decodeIfPresent(Double.self, forKey: key) else {
                throw GenerationPlanDecodingError.missingField(op: op, field: field)
            }
            return v
        }
        func opt(_ key: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: key) ?? nil }
        func colour(_ key: CodingKeys) -> GenColor? { try? c.decodeIfPresent(GenColor.self, forKey: key) ?? nil }
        func pointFrom(_ xKey: CodingKeys, _ yKey: CodingKeys) throws -> GenPoint {
            GenPoint(x: try req(xKey, "x"), y: try req(yKey, "y"))
        }
        func points() throws -> [GenPoint] {
            guard let v = try c.decodeIfPresent([GenPoint].self, forKey: .points) else {
                throw GenerationPlanDecodingError.missingField(op: op, field: "points")
            }
            return v
        }

        switch op {
        case "rectangle", "rect":
            self = .rectangle(x: try req(.x, "x"), y: try req(.y, "y"), w: try req(.w, "w"), h: try req(.h, "h"),
                              fill: colour(.fill), stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "roundedRectangle", "roundedRect", "roundRect":
            self = .roundedRectangle(x: try req(.x, "x"), y: try req(.y, "y"), w: try req(.w, "w"), h: try req(.h, "h"),
                                     cornerRadius: (opt(.cornerRadius) ?? 0),
                                     fill: colour(.fill), stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "ellipse", "circle", "oval":
            self = .ellipse(x: try req(.x, "x"), y: try req(.y, "y"), w: try req(.w, "w"), h: try req(.h, "h"),
                            fill: colour(.fill), stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "line":
            self = .line(from: try pointFrom(.x1, .y1), to: try pointFrom(.x2, .y2),
                         stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "arrow":
            self = .arrow(from: try pointFrom(.x1, .y1), to: try pointFrom(.x2, .y2),
                          stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "polyline":
            self = .polyline(points: try points(), stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "polygon":
            self = .polygon(points: try points(), fill: colour(.fill), stroke: colour(.stroke), strokeWidth: opt(.strokeWidth))
        case "text", "label":
            guard let string = try c.decodeIfPresent(String.self, forKey: .text) else {
                throw GenerationPlanDecodingError.missingField(op: op, field: "text")
            }
            self = .text(x: try req(.x, "x"), y: try req(.y, "y"),
                         w: opt(.w), h: opt(.h), string: string, color: colour(.color),
                         fontSize: (opt(.fontSize) ?? 16), fontFamily: try? c.decodeIfPresent(String.self, forKey: .fontFamily) ?? nil)
        default:
            throw GenerationPlanDecodingError.unknownOperation(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opName, forKey: .op)
        func put(_ fill: GenColor?, _ stroke: GenColor?, _ sw: Double?) throws {
            if let fill { try c.encode(fill, forKey: .fill) }
            if let stroke { try c.encode(stroke, forKey: .stroke) }
            if let sw { try c.encode(sw, forKey: .strokeWidth) }
        }
        switch self {
        case let .rectangle(x, y, w, h, fill, stroke, sw), let .ellipse(x, y, w, h, fill, stroke, sw):
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try put(fill, stroke, sw)
        case let .roundedRectangle(x, y, w, h, radius, fill, stroke, sw):
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(radius, forKey: .cornerRadius); try put(fill, stroke, sw)
        case let .line(from, to, stroke, sw), let .arrow(from, to, stroke, sw):
            try c.encode(from.x, forKey: .x1); try c.encode(from.y, forKey: .y1)
            try c.encode(to.x, forKey: .x2); try c.encode(to.y, forKey: .y2)
            try put(nil, stroke, sw)
        case let .polyline(points, stroke, sw):
            try c.encode(points, forKey: .points); try put(nil, stroke, sw)
        case let .polygon(points, fill, stroke, sw):
            try c.encode(points, forKey: .points); try put(fill, stroke, sw)
        case let .text(x, y, w, h, string, color, fontSize, family):
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            if let w { try c.encode(w, forKey: .w) }
            if let h { try c.encode(h, forKey: .h) }
            try c.encode(string, forKey: .text)
            if let color { try c.encode(color, forKey: .color) }
            try c.encode(fontSize, forKey: .fontSize)
            if let family { try c.encode(family, forKey: .fontFamily) }
        }
    }
}

extension GenerationPlan: Codable {
    private enum CodingKeys: String, CodingKey { case page, coords, elements, operations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.page = try GenerationPage(from: decoder)
        if let ops = try? container.decodeIfPresent([GenerationOp].self, forKey: .elements) {
            self.operations = ops
        } else if let ops = try? container.decodeIfPresent([GenerationOp].self, forKey: .operations) {
            self.operations = ops
        } else {
            throw GenerationPlanDecodingError.malformed("no elements array")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try page.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operations, forKey: .elements)
    }
}

extension GenerationPlan {
    /// Decodes a plan from UTF-8 JSON, tolerant of surrounding prose or a ```json code
    /// fence, with the SAME conservative key-quoting repairs as `EditPlan.decode` (a small
    /// on-device model sometimes drops the opening quote on a key). Never loosens the
    /// validator (the decoded plan is validated unchanged). Throws when the repaired text
    /// still won't decode — nothing is created on a throw.
    public static func decode(fromJSON json: String) throws -> GenerationPlan {
        let slice = EditPlan.extractJSONObject(json) ?? json
        if let plan = try? decodeStrict(slice) { return plan }
        let reQuoted = GenerationPlan.repairKeyQuoting(slice)
        if let plan = try? decodeStrict(reQuoted) { return plan }
        return try decodeStrict(GenerationPlan.repairUnquotedKeys(reQuoted))
    }

    private static func decodeStrict(_ json: String) throws -> GenerationPlan {
        guard let data = json.data(using: .utf8) else {
            throw GenerationPlanDecodingError.malformed("not utf-8")
        }
        return try JSONDecoder().decode(GenerationPlan.self, from: data)
    }

    /// Known generation-plan JSON keys (for the conservative re-quoting repairs).
    private static let knownKeys = "page|coords|elements|operations|op|x|y|w|h|x1|y1|x2|y2|points|cornerRadius|fill|stroke|strokeWidth|text|color|fontSize|fontFamily"

    /// Re-inserts a missing OPENING quote on a known key (`,fill":` → `,"fill":`). Bounded
    /// to the known key set; no other structure is touched. §8: safe on untrusted input.
    static func repairKeyQuoting(_ json: String) -> String {
        let pattern = "([,{][\\s]*)(\(knownKeys))\"([\\s]*):"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex ..< json.endIndex, in: json)
        return regex.stringByReplacingMatches(in: json, range: range, withTemplate: "$1\"$2\"$3:")
    }

    /// Re-quotes a known key with NO quotes at all before a value start (`,w:0.2` →
    /// `,"w":0.2`). The lookahead requires a string/array/object/number start, so a key
    /// word inside prose text isn't matched. §8: safe on untrusted input.
    static func repairUnquotedKeys(_ json: String) -> String {
        let pattern = "([,{][\\s]*)(\(knownKeys))([\\s]*:[\\s]*)(?=[\"\\[{\\-0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex ..< json.endIndex, in: json)
        return regex.stringByReplacingMatches(in: json, range: range, withTemplate: "$1\"$2\"$3")
    }

    /// The plan as pretty JSON (for diagnostics / debug capture).
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
