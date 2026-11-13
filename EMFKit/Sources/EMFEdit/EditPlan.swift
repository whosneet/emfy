import CoreGraphics
import Foundation

// MARK: - A typed, bounded edit plan (X2a)
//
// A small CLOSED vocabulary of edit operations over element ids that maps 1:1 onto
// the existing `SceneCommand` layer, plus a strict JSON form. It is the ONLY shape an
// AI edit may take (docs/v3-plan §11.2): the model emits an `EditPlan`, never raw
// records, so every AI edit goes through the same validation, preview, confirm and
// undo as a user edit. The plan itself is inert — it mutates nothing. It is decoded,
// then validated (`EditPlanValidator`), and only an explicit `commands(in:)` →
// `DocumentSession.applyGroupedCommands` call ever changes a scene.
//
// Security (CLAUDE.md §8 / axiom-security): the JSON comes from model output, which is
// untrusted. The decoder is strict (an unknown op is a typed error; extra free-form
// fields are never acted on) and every number is bounds-checked by the validator
// before anything is applied. Nothing here force-unwraps or does unchecked arithmetic.

/// An RGBA colour carried in a plan as a hex string, parsed and validated separately so
/// a malformed colour is a validator problem (not a decode trap). Accepts `#RGB`,
/// `#RRGGBB`, `#RRGGBBAA` and the same without the leading `#`.
public struct PlanColor: Sendable, Equatable, Codable {
    /// The colour exactly as the plan gave it (for diagnostics and the preview list).
    public var hex: String

    public init(hex: String) { self.hex = hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.hex = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// The parsed colour, or `nil` when `hex` is not a valid colour.
    public var color: SceneColor? { PlanColor.parse(hex) }

    /// Builds a `PlanColor` from a scene colour (`#RRGGBB`, or `#RRGGBBAA` when
    /// translucent), so a deterministic recolour mapping round-trips through the plan.
    public init(_ color: SceneColor) {
        func byte(_ value: Double) -> Int { Int((value.clamped(0, 1) * 255).rounded()) }
        let r = byte(color.red), g = byte(color.green), b = byte(color.blue)
        if color.alpha < 1 {
            self.hex = String(format: "#%02X%02X%02X%02X", r, g, b, byte(color.alpha))
        } else {
            self.hex = String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    /// Parses a hex colour string (`#RGB`, `#RRGGBB`, `#RRGGBBAA`, with or without `#`),
    /// or `nil`. Public so the app's brand-colour entry can validate as the user types.
    public static func parse(_ raw: String) -> SceneColor? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        func component(_ substring: Substring) -> Double? {
            guard let value = UInt8(substring, radix: 16) else { return nil }
            return Double(value) / 255
        }
        func nibble(_ character: Character) -> Double? {
            guard let value = UInt8(String(character), radix: 16) else { return nil }
            return Double(value * 17) / 255   // 0xA -> 0xAA
        }
        let chars = Array(s)
        switch chars.count {
        case 3:   // #RGB
            guard let r = nibble(chars[0]), let g = nibble(chars[1]), let b = nibble(chars[2]) else { return nil }
            return SceneColor(red: r, green: g, blue: b, alpha: 1)
        case 6:   // #RRGGBB
            guard let r = component(s.prefix(2)),
                  let g = component(s.dropFirst(2).prefix(2)),
                  let b = component(s.dropFirst(4).prefix(2)) else { return nil }
            return SceneColor(red: r, green: g, blue: b, alpha: 1)
        case 8:   // #RRGGBBAA
            guard let r = component(s.prefix(2)),
                  let g = component(s.dropFirst(2).prefix(2)),
                  let b = component(s.dropFirst(4).prefix(2)),
                  let a = component(s.dropFirst(6).prefix(2)) else { return nil }
            return SceneColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}

/// The alignment edge for an `align` operation.
public enum PlanAlignEdge: String, Sendable, Equatable, Codable, CaseIterable {
    case left, right, top, bottom, centerHorizontal, centerVertical
}

/// The axis for a `distribute` operation.
public enum PlanDistributeAxis: String, Sendable, Equatable, Codable, CaseIterable {
    case horizontal, vertical
}

/// One operation in an `EditPlan`. Each case maps onto one (or, for per-element and
/// align/distribute ops, several) `SceneCommand`s. The closed set is the ENTIRE AI edit
/// vocabulary — anything else is refused at decode.
public enum EditOperation: Sendable, Equatable {
    /// Recolours the solid fill of each element (and, for a text run, its glyph colour).
    case recolorFill(ids: [Int], color: PlanColor)
    /// Recolours the stroke of each element that has one (elements with no stroke are skipped).
    case recolorStroke(ids: [Int], color: PlanColor)
    /// Replaces a text run's string.
    case setText(id: Int, text: String)
    /// Sets a text run's point size (typographic points, converted to the run's units).
    case setFontSize(id: Int, points: Double)
    /// Sets a text run's font family.
    case setFontFamily(id: Int, family: String)
    /// Moves elements by a device-space delta.
    case move(ids: [Int], dx: Double, dy: Double)
    /// Scales elements about their common centre by `factor` (1 = no change).
    case scale(ids: [Int], factor: Double)
    /// Sets the line width (typographic points) of each element that has a stroke.
    case setLineWidth(ids: [Int], points: Double)
    /// Aligns elements to the common bounding box's chosen edge.
    case align(ids: [Int], edge: PlanAlignEdge)
    /// Distributes elements so the gaps between them are equal along an axis.
    case distribute(ids: [Int], axis: PlanDistributeAxis)
    /// Deletes elements.
    case delete(ids: [Int])

    /// The JSON discriminator for this operation.
    public var opName: String {
        switch self {
        case .recolorFill: return "recolorFill"
        case .recolorStroke: return "recolorStroke"
        case .setText: return "setText"
        case .setFontSize: return "setFontSize"
        case .setFontFamily: return "setFontFamily"
        case .move: return "move"
        case .scale: return "scale"
        case .setLineWidth: return "setLineWidth"
        case .align: return "align"
        case .distribute: return "distribute"
        case .delete: return "delete"
        }
    }

    /// Every element id this operation targets.
    public var targetIDs: [Int] {
        switch self {
        case .recolorFill(let ids, _), .recolorStroke(let ids, _),
             .move(let ids, _, _), .scale(let ids, _), .setLineWidth(let ids, _),
             .align(let ids, _), .distribute(let ids, _), .delete(let ids):
            return ids
        case .setText(let id, _), .setFontSize(let id, _), .setFontFamily(let id, _):
            return [id]
        }
    }
}

/// A plan: an ordered list of operations. Pure value type.
public struct EditPlan: Sendable, Equatable, Codable {
    public var operations: [EditOperation]

    public init(operations: [EditOperation]) {
        self.operations = operations
    }
}

// MARK: - Strict JSON coding

/// Why decoding a plan from JSON failed. A decode failure means NOTHING is applied.
public enum EditPlanDecodingError: Error, Sendable, Equatable {
    /// The `op` field named an operation outside the closed vocabulary.
    case unknownOperation(String)
    /// A required field for the operation was missing.
    case missingField(op: String, field: String)
    /// A field held a value the operation can't use (e.g. an unknown align edge).
    case invalidValue(op: String, field: String, value: String)
}

extension EditOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, ids, id, color, text, points, family, dx, dy, factor, edge, axis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)

        func ids() throws -> [Int] {
            guard let value = try container.decodeIfPresent([Int].self, forKey: .ids) else {
                throw EditPlanDecodingError.missingField(op: op, field: "ids")
            }
            return value
        }
        func id() throws -> Int {
            guard let value = try container.decodeIfPresent(Int.self, forKey: .id) else {
                throw EditPlanDecodingError.missingField(op: op, field: "id")
            }
            return value
        }
        func color() throws -> PlanColor {
            guard let value = try container.decodeIfPresent(PlanColor.self, forKey: .color) else {
                throw EditPlanDecodingError.missingField(op: op, field: "color")
            }
            return value
        }
        func double(_ key: CodingKeys, _ field: String) throws -> Double {
            guard let value = try container.decodeIfPresent(Double.self, forKey: key) else {
                throw EditPlanDecodingError.missingField(op: op, field: field)
            }
            return value
        }
        func string(_ key: CodingKeys, _ field: String) throws -> String {
            guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
                throw EditPlanDecodingError.missingField(op: op, field: field)
            }
            return value
        }

        switch op {
        case "recolorFill":
            self = .recolorFill(ids: try ids(), color: try color())
        case "recolorStroke":
            self = .recolorStroke(ids: try ids(), color: try color())
        case "setText":
            self = .setText(id: try id(), text: try string(.text, "text"))
        case "setFontSize":
            self = .setFontSize(id: try id(), points: try double(.points, "points"))
        case "setFontFamily":
            self = .setFontFamily(id: try id(), family: try string(.family, "family"))
        case "move":
            self = .move(ids: try ids(), dx: try double(.dx, "dx"), dy: try double(.dy, "dy"))
        case "scale":
            self = .scale(ids: try ids(), factor: try double(.factor, "factor"))
        case "setLineWidth":
            self = .setLineWidth(ids: try ids(), points: try double(.points, "points"))
        case "align":
            let raw = try string(.edge, "edge")
            guard let edge = PlanAlignEdge(rawValue: raw) else {
                throw EditPlanDecodingError.invalidValue(op: op, field: "edge", value: raw)
            }
            self = .align(ids: try ids(), edge: edge)
        case "distribute":
            let raw = try string(.axis, "axis")
            guard let axis = PlanDistributeAxis(rawValue: raw) else {
                throw EditPlanDecodingError.invalidValue(op: op, field: "axis", value: raw)
            }
            self = .distribute(ids: try ids(), axis: axis)
        case "delete":
            self = .delete(ids: try ids())
        default:
            throw EditPlanDecodingError.unknownOperation(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opName, forKey: .op)
        switch self {
        case .recolorFill(let ids, let color), .recolorStroke(let ids, let color):
            try container.encode(ids, forKey: .ids)
            try container.encode(color, forKey: .color)
        case .setText(let id, let text):
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case .setFontSize(let id, let points):
            try container.encode(id, forKey: .id)
            try container.encode(points, forKey: .points)
        case .setFontFamily(let id, let family):
            try container.encode(id, forKey: .id)
            try container.encode(family, forKey: .family)
        case .move(let ids, let dx, let dy):
            try container.encode(ids, forKey: .ids)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)
        case .scale(let ids, let factor):
            try container.encode(ids, forKey: .ids)
            try container.encode(factor, forKey: .factor)
        case .setLineWidth(let ids, let points):
            try container.encode(ids, forKey: .ids)
            try container.encode(points, forKey: .points)
        case .align(let ids, let edge):
            try container.encode(ids, forKey: .ids)
            try container.encode(edge, forKey: .edge)
        case .distribute(let ids, let axis):
            try container.encode(ids, forKey: .ids)
            try container.encode(axis, forKey: .axis)
        case .delete(let ids):
            try container.encode(ids, forKey: .ids)
        }
    }
}

extension EditPlan {
    /// Decodes a plan from UTF-8 JSON, tolerant of surrounding prose or a ```json code
    /// fence (model replies often wrap the object). A small on-device model sometimes drops
    /// the opening quote on a key (`,color":` instead of `,"color":`); when the strict
    /// decode fails, ONE conservative repair that re-quotes only the known keys is tried —
    /// this never loosens the validator (the decoded plan is validated unchanged) and never
    /// invents structure. Throws `EditPlanDecodingError` (or a `DecodingError`) when the
    /// repaired text still won't decode — nothing is applied on a throw.
    public static func decode(fromJSON json: String) throws -> EditPlan {
        let slice = extractJSONObject(json) ?? json
        if let plan = try? decodeStrict(slice) { return plan }
        return try decodeStrict(repairKeyQuoting(slice))
    }

    private static func decodeStrict(_ json: String) throws -> EditPlan {
        guard let data = json.data(using: .utf8) else {
            throw EditPlanDecodingError.invalidValue(op: "plan", field: "json", value: "not utf-8")
        }
        return try JSONDecoder().decode(EditPlan.self, from: data)
    }

    /// Known EditPlan JSON keys (for the conservative re-quoting repair).
    private static let knownKeys = "op|ids|id|color|text|points|family|dx|dy|factor|edge|axis"

    /// Re-inserts a missing OPENING quote on a known key that immediately follows `{` or `,`
    /// (e.g. `,color":` → `,"color":`). A correctly-quoted key has a `"` between the
    /// delimiter and the key letters, so it never matches. Bounded to the known key set; no
    /// other structure is touched. §8: builds no force-unwrap and repairs untrusted text safely.
    static func repairKeyQuoting(_ json: String) -> String {
        let pattern = "([,{][\\s]*)(\(knownKeys))\"([\\s]*):"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex ..< json.endIndex, in: json)
        return regex.stringByReplacingMatches(in: json, range: range, withTemplate: "$1\"$2\"$3:")
    }

    /// The outermost `{ … }` object in `text`, so a fenced or prose-wrapped reply still
    /// decodes. `nil` when no brace pair is present.
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start ... end])
    }

    /// The plan as pretty JSON (for diagnostics / debug capture).
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// MARK: - Mapping to scene commands

extension EditPlan {
    /// Resolves the plan to `SceneCommand`s against `scene`, to be applied as ONE grouped
    /// undo ("AI Edit") by the caller. Operations that target a missing or non-applicable
    /// element are skipped (the validator is the gate; this is defence in depth). Font
    /// operations on the same element are merged into a single `setFont` so "bigger AND a
    /// new face" is one coherent command. Pure; no mutation happens here.
    public func commands(in scene: Scene) -> [SceneCommand] {
        var out: [SceneCommand] = []
        // Per-element merged font state, so repeated font ops on one id collapse to one
        // setFont command rewritten in place.
        var fontIndex: [Int: Int] = [:]
        var fontFamily: [Int: String] = [:]
        var fontSize: [Int: Int32] = [:]
        var fontBold: [Int: Bool] = [:]
        var fontItalic: [Int: Bool] = [:]

        func seedFont(_ id: Int) -> Bool {
            if fontIndex[id] != nil { return true }
            guard let element = scene.element(id: id), let text = element.text,
                  element.kind == .text, !element.rejectsMutation else { return false }
            let size = max(Int32(1), abs(text.logicalHeight) == 0 ? 1 : abs(text.logicalHeight))
            fontFamily[id] = text.fontFamily
            fontSize[id] = size
            fontBold[id] = text.bold
            fontItalic[id] = text.italic
            out.append(.setFont(id: id, family: text.fontFamily, size: size, bold: text.bold, italic: text.italic))
            fontIndex[id] = out.count - 1
            return true
        }
        func rewriteFont(_ id: Int) {
            guard let index = fontIndex[id],
                  let family = fontFamily[id], let size = fontSize[id],
                  let bold = fontBold[id], let italic = fontItalic[id] else { return }
            out[index] = .setFont(id: id, family: family, size: size, bold: bold, italic: italic)
        }

        for operation in operations {
            switch operation {
            case .recolorFill(let ids, let planColor):
                guard let color = planColor.color else { continue }
                for id in dedupe(ids) {
                    guard let element = scene.element(id: id), !element.rejectsMutation else { continue }
                    let evenOdd = element.style.fill?.evenOdd ?? false
                    out.append(.setFill(ids: [id], SceneFill(color: color, evenOdd: evenOdd, gradient: nil)))
                }

            case .recolorStroke(let ids, let planColor):
                guard let color = planColor.color else { continue }
                for id in dedupe(ids) {
                    guard let element = scene.element(id: id), !element.rejectsMutation,
                          var stroke = element.style.stroke else { continue }
                    stroke.color = color
                    out.append(.setStroke(ids: [id], stroke))
                }

            case .setText(let id, let text):
                guard let element = scene.element(id: id), element.kind == .text,
                      element.text != nil, !element.rejectsMutation else { continue }
                out.append(.setText(id: id, text))

            case .setFontSize(let id, let points):
                guard seedFont(id), let element = scene.element(id: id) else { continue }
                guard let logical = Self.logicalEmHeight(points: points, element: element, scene: scene) else { continue }
                fontSize[id] = logical
                rewriteFont(id)

            case .setFontFamily(let id, let family):
                guard seedFont(id) else { continue }
                fontFamily[id] = family
                rewriteFont(id)

            case .move(let ids, let dx, let dy):
                let targets = applicableTargets(dedupe(ids), in: scene)
                guard !targets.isEmpty, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { continue }
                out.append(.translate(ids: Set(targets), dx: dx, dy: dy))

            case .scale(let ids, let factor):
                let targets = applicableTargets(dedupe(ids), in: scene)
                guard !targets.isEmpty, factor.isFinite, factor > 0, factor != 1 else { continue }
                let box = unionBounds(targets, in: scene)
                guard !box.isNull, box.width.isFinite, box.height.isFinite else { continue }
                let cx = box.midX, cy = box.midY
                let transform = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: factor, y: factor)
                    .translatedBy(x: -cx, y: -cy)
                out.append(.applyTransform(ids: Set(targets), transform))

            case .setLineWidth(let ids, let points):
                for id in dedupe(ids) {
                    guard let element = scene.element(id: id), !element.rejectsMutation,
                          var stroke = element.style.stroke else { continue }
                    let device = points * Double(scene.deviceUnitsPerPoint)
                    guard device.isFinite, device > 0 else { continue }
                    stroke.isCosmetic = false
                    stroke.width = device
                    out.append(.setStroke(ids: [id], stroke))
                }

            case .align(let ids, let edge):
                let targets = applicableTargets(dedupe(ids), in: scene)
                let boxes = targets.compactMap { id -> (Int, CGRect)? in
                    guard let box = scene.element(id: id)?.boundsDevice, !box.isNull else { return nil }
                    return (id, box.standardized)
                }
                guard boxes.count >= 2 else { continue }
                let reference = boxes.map(\.1).reduce(CGRect.null) { $0.isNull ? $1 : $0.union($1) }
                for (id, box) in boxes {
                    let (dx, dy) = Self.alignDelta(box, to: reference, edge: edge)
                    if dx != 0 || dy != 0 { out.append(.translate(ids: [id], dx: dx, dy: dy)) }
                }

            case .distribute(let ids, let axis):
                let targets = applicableTargets(dedupe(ids), in: scene)
                let boxes = targets.compactMap { id -> (Int, CGRect)? in
                    guard let box = scene.element(id: id)?.boundsDevice, !box.isNull else { return nil }
                    return (id, box.standardized)
                }
                for delta in Self.distributeDeltas(boxes, axis: axis) where delta.dx != 0 || delta.dy != 0 {
                    out.append(.translate(ids: [delta.id], dx: delta.dx, dy: delta.dy))
                }

            case .delete(let ids):
                let targets = applicableTargets(dedupe(ids), in: scene)
                guard !targets.isEmpty else { continue }
                out.append(.delete(ids: Set(targets)))
            }
        }
        return out
    }

    /// Element ids that exist and accept mutation (dropping missing/locked/passthrough).
    private func applicableTargets(_ ids: [Int], in scene: Scene) -> [Int] {
        ids.filter { id in
            guard let element = scene.element(id: id) else { return false }
            return !element.rejectsMutation
        }
    }

    private func dedupe(_ ids: [Int]) -> [Int] {
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func unionBounds(_ ids: [Int], in scene: Scene) -> CGRect {
        ids.reduce(CGRect.null) { box, id in
            guard let rect = scene.element(id: id)?.boundsDevice, !rect.isNull else { return box }
            return box.isNull ? rect.standardized : box.union(rect.standardized)
        }
    }

    /// The device em height for a point size on the run's page/transform, matching
    /// `DrawingFixPlanner.planTinyText`'s basis so a plan size change prints at the asked
    /// point size. `nil` when the geometry is degenerate.
    static func logicalEmHeight(points: Double, element: Element, scene: Scene) -> Int32? {
        let perPoint = Double(scene.deviceUnitsPerPoint)
        let vScale = abs(element.transform.d) < 1e-9 ? sqrt(element.transform.b * element.transform.b + element.transform.d * element.transform.d) : abs(element.transform.d)
        let scaleFactor = vScale.isFinite && vScale > 1e-9 ? vScale : 1
        guard points.isFinite, points > 0, perPoint > 0 else { return nil }
        let logical = (points * perPoint / scaleFactor).rounded()
        guard logical.isFinite, logical >= 1, logical <= Double(Int32.max) else { return nil }
        return Int32(logical)
    }

    /// The device translation that aligns `box` to `reference`'s chosen edge.
    static func alignDelta(_ box: CGRect, to reference: CGRect, edge: PlanAlignEdge) -> (dx: Double, dy: Double) {
        switch edge {
        case .left: return (Double(reference.minX - box.minX), 0)
        case .right: return (Double(reference.maxX - box.maxX), 0)
        case .centerHorizontal: return (Double(reference.midX - box.midX), 0)
        case .top: return (0, Double(reference.minY - box.minY))
        case .bottom: return (0, Double(reference.maxY - box.maxY))
        case .centerVertical: return (0, Double(reference.midY - box.midY))
        }
    }

    struct DistributeDelta: Equatable { var id: Int; var dx: Double; var dy: Double }

    /// Per-element device translations distributing 3+ boxes so the gaps between them are
    /// equal along `axis`; the two extreme boxes stay put. Fewer than 3 → none.
    static func distributeDeltas(_ boxes: [(Int, CGRect)], axis: PlanDistributeAxis) -> [DistributeDelta] {
        guard boxes.count >= 3 else { return [] }
        let sorted = boxes.sorted { lhs, rhs in
            axis == .horizontal ? lhs.1.midX < rhs.1.midX : lhs.1.midY < rhs.1.midY
        }
        let total = sorted.reduce(0.0) { $0 + Double(axis == .horizontal ? $1.1.width : $1.1.height) }
        let first = sorted[0].1, last = sorted[sorted.count - 1].1
        let span = axis == .horizontal
            ? Double(last.maxX - first.minX)
            : Double(last.maxY - first.minY)
        let gap = (span - total) / Double(sorted.count - 1)
        var cursor = axis == .horizontal ? Double(first.minX) : Double(first.minY)
        var deltas: [DistributeDelta] = []
        for (index, (id, box)) in sorted.enumerated() {
            if index == 0 {
                cursor += Double(axis == .horizontal ? box.width : box.height)
                continue
            }
            if index == sorted.count - 1 { continue }
            cursor += gap
            if axis == .horizontal {
                deltas.append(DistributeDelta(id: id, dx: cursor - Double(box.minX), dy: 0))
            } else {
                deltas.append(DistributeDelta(id: id, dx: 0, dy: cursor - Double(box.minY)))
            }
            cursor += Double(axis == .horizontal ? box.width : box.height)
        }
        return deltas
    }
}
