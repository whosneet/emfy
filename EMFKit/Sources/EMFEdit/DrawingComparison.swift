import CoreGraphics
import Foundation

// MARK: - Compare two versions of a drawing (X1b item 1)
//
// `DrawingComparison` diffs two scenes at the ELEMENT level — added, removed and
// changed elements, with which attributes changed — and offers a PIXEL-level diff
// helper (two CGImages → changed-pixel count and merged bounding regions). It is a
// pure value computed off the scene model; nothing here touches the model or the UI.
//
// Matching strategy (brief): byte-identical elements pair first (so an identical
// scene diffs to nothing), then same-id-and-kind pairs (stable across an edit, which
// preserves element ids), then nearest same-kind-by-position pairs (for two unrelated
// files that share no provenance). Whatever is left over is reported added/removed.

/// An element-level and pixel-level diff of two scenes.
public struct DrawingComparison: Sendable, Equatable {

    /// How an element changed between the two versions.
    public enum ChangeKind: Sendable, Equatable {
        case added, removed, changed
    }

    /// Which attribute of a matched element changed.
    public enum Attribute: String, Sendable, Equatable, CaseIterable {
        case position      // moved (same size and shape, different place)
        case geometry      // shape or size changed
        case fillColor     // fill colour (text colour for a text run)
        case strokeColor   // stroke colour
        case text          // the text string changed
        case font          // family, size, weight, slant or decoration changed
        case other         // some other property changed (opacity, dash, lock, …)
    }

    /// One reported difference.
    public struct ElementChange: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: ChangeKind
        /// The old element (nil when `kind == .added`).
        public var oldElement: Element?
        /// The new element (nil when `kind == .removed`).
        public var newElement: Element?
        /// Which attributes changed (empty for added/removed).
        public var attributes: [Attribute]
        /// The device-space region to highlight: the union of the old and new bounds.
        public var boundsDevice: CGRect
        /// A short human line, e.g. "Rectangle moved" or "Text recoloured".
        public var summary: String

        public init(id: Int, kind: ChangeKind, oldElement: Element?, newElement: Element?, attributes: [Attribute], boundsDevice: CGRect, summary: String) {
            self.id = id
            self.kind = kind
            self.oldElement = oldElement
            self.newElement = newElement
            self.attributes = attributes
            self.boundsDevice = boundsDevice
            self.summary = summary
        }
    }

    /// All reported changes, in a stable order (changed, then added, then removed,
    /// each by z-order).
    public var changes: [ElementChange]

    public init(changes: [ElementChange]) {
        self.changes = changes
    }

    /// True when the two scenes have no element-level differences.
    public var isEmpty: Bool { changes.isEmpty }

    public var addedCount: Int { changes.lazy.filter { $0.kind == .added }.count }
    public var removedCount: Int { changes.lazy.filter { $0.kind == .removed }.count }
    public var changedCount: Int { changes.lazy.filter { $0.kind == .changed }.count }

    // MARK: - Element diff

    /// Builds the element-level diff of `old` → `new`.
    public init(old: Scene, new: Scene) {
        let oldElements = old.elements
        let newElements = new.elements
        var usedNew = Set<Int>()          // indices into newElements already matched
        var pairs: [(oldIndex: Int, newIndex: Int)] = []
        var unmatchedOld: [Int] = []

        // Pass 1: byte-identical elements (so an identical scene is an empty diff).
        var identicalNewByHash: [Int: [Int]] = [:]
        for (j, element) in newElements.enumerated() {
            identicalNewByHash[Self.matchHash(element), default: []].append(j)
        }
        var remainingOld: [Int] = []
        for (i, element) in oldElements.enumerated() {
            let hash = Self.matchHash(element)
            if let candidates = identicalNewByHash[hash],
               let slot = candidates.firstIndex(where: { !usedNew.contains($0) && newElements[$0] == element }) {
                usedNew.insert(candidates[slot])
                continue   // identical → not a change
            }
            remainingOld.append(i)
        }

        // Pass 2: same id AND kind (edits preserve the element id).
        var newByID: [Int: [Int]] = [:]
        for j in newElements.indices where !usedNew.contains(j) {
            newByID[newElements[j].id, default: []].append(j)
        }
        var afterID: [Int] = []
        for i in remainingOld {
            let old = oldElements[i]
            if let candidates = newByID[old.id],
               let j = candidates.first(where: { !usedNew.contains($0) && newElements[$0].kind == old.kind }) {
                usedNew.insert(j)
                pairs.append((i, j))
            } else {
                afterID.append(i)
            }
        }

        // Pass 3: nearest same-kind by position (unrelated files share no id).
        for i in afterID {
            let old = oldElements[i]
            let centre = Self.centre(old.boundsDevice)
            var best: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for j in newElements.indices where !usedNew.contains(j) && newElements[j].kind == old.kind {
                let d = Self.distanceSquared(centre, Self.centre(newElements[j].boundsDevice))
                if d < bestDistance { bestDistance = d; best = j }
            }
            if let j = best {
                usedNew.insert(j)
                pairs.append((i, j))
            } else {
                unmatchedOld.append(i)
            }
        }

        // Assemble: changed pairs (only those that actually differ), then added, removed.
        var changed: [ElementChange] = []
        for (i, j) in pairs {
            let a = oldElements[i]
            let b = newElements[j]
            let attributes = Self.attributes(from: a, to: b)
            guard !attributes.isEmpty else { continue }  // matched but equivalent
            changed.append(ElementChange(
                id: b.id, kind: .changed, oldElement: a, newElement: b,
                attributes: attributes,
                boundsDevice: a.boundsDevice.union(b.boundsDevice),
                summary: Self.changedSummary(kind: b.kind, attributes: attributes, old: a, new: b)))
        }
        let added: [ElementChange] = newElements.indices
            .filter { !usedNew.contains($0) }
            .map { j in
                let b = newElements[j]
                return ElementChange(id: b.id, kind: .added, oldElement: nil, newElement: b, attributes: [],
                                     boundsDevice: b.boundsDevice, summary: "Added \(Self.kindName(b.kind))")
            }
        let removed: [ElementChange] = unmatchedOld.map { i in
            let a = oldElements[i]
            return ElementChange(id: a.id, kind: .removed, oldElement: a, newElement: nil, attributes: [],
                                 boundsDevice: a.boundsDevice, summary: "Removed \(Self.kindName(a.kind))")
        }
        self.changes = changed + added + removed
    }

    // MARK: - Attribute detection

    /// Which attributes differ between a matched pair.
    static func attributes(from a: Element, to b: Element) -> [Attribute] {
        var result: [Attribute] = []

        // Geometry / position. A pure translation (same size, same shape shifted) is a
        // move; anything else that changes the drawn geometry is a geometry change.
        let geometryChanged = a.geometryDevice != b.geometryDevice || a.transform != b.transform
        if geometryChanged {
            if sizeApproxEqual(a.boundsDevice.size, b.boundsDevice.size)
                && translatedEqual(a, b) {
                result.append(.position)
            } else {
                result.append(.geometry)
            }
        }

        // Fill / stroke colour. For a text run the colour lives in `text.color`.
        if a.kind == .text || b.kind == .text {
            if a.text?.color != b.text?.color { result.append(.fillColor) }
        } else if fillColor(a) != fillColor(b) || a.style.fill?.gradient != b.style.fill?.gradient {
            result.append(.fillColor)
        }
        if strokeColor(a) != strokeColor(b) { result.append(.strokeColor) }

        // Text and font.
        if a.text?.string != b.text?.string { result.append(.text) }
        if fontSignature(a.text) != fontSignature(b.text) { result.append(.font) }

        // Anything else that still differs (opacity, stroke width/dash, lock, hidden …).
        if result.isEmpty && !elementsEquivalent(a, b) {
            result.append(.other)
        }
        return result
    }

    private static func fillColor(_ e: Element) -> SceneColor? { e.style.fill?.color }
    private static func strokeColor(_ e: Element) -> SceneColor? { e.style.stroke?.color }

    /// A comparable font signature (family, size, weight, slant, decoration). Nil for a
    /// non-text element.
    private static func fontSignature(_ text: SceneText?) -> String? {
        guard let t = text else { return nil }
        return [t.fontFamily, String(t.logicalHeight), String(t.emSize),
                t.bold ? "b" : "", t.italic ? "i" : "", t.underline ? "u" : "",
                t.strikeOut ? "s" : "", String(t.escapementTenths)].joined(separator: "|")
    }

    /// Whether two matched elements are equivalent apart from attributes already
    /// reported — used to decide if a trailing `.other` change is worth reporting.
    private static func elementsEquivalent(_ a: Element, _ b: Element) -> Bool {
        var a2 = a
        // Ignore id, provenance and bounds cache (derived) for this check.
        a2.provenance = b.provenance
        a2.id = b.id
        a2.boundsDevice = b.boundsDevice
        return a2 == b
    }

    /// True when `b`'s geometry is `a`'s shifted by a constant offset (a move).
    private static func translatedEqual(_ a: Element, _ b: Element) -> Bool {
        let dx = b.boundsDevice.minX - a.boundsDevice.minX
        let dy = b.boundsDevice.minY - a.boundsDevice.minY
        let shifted = a.geometryDevice.applying(CGAffineTransform(translationX: dx, y: dy))
        return pathApproxEqual(shifted, b.geometryDevice)
    }

    // MARK: - Summaries

    private static func changedSummary(kind: ElementKind, attributes: [Attribute], old: Element, new: Element) -> String {
        let name = kindName(kind)
        if attributes == [.position] { return "\(name.capitalisedFirst) moved" }
        if attributes == [.geometry] { return "\(name.capitalisedFirst) reshaped" }
        if attributes == [.text] {
            // Avoid "Text text changed" for a text element.
            return kind == .text ? "Text changed" : "\(name.capitalisedFirst) text changed"
        }
        if attributes == [.fillColor] {
            if kind == .text, let o = old.text?.color, let n = new.text?.color {
                return "\(name.capitalisedFirst) recoloured \(o.hexString) → \(n.hexString)"
            }
            if let o = old.style.fill?.color, let n = new.style.fill?.color {
                return "\(name.capitalisedFirst) recoloured \(o.hexString) → \(n.hexString)"
            }
            return "\(name.capitalisedFirst) fill changed"
        }
        if attributes == [.strokeColor] { return "\(name.capitalisedFirst) stroke recoloured" }
        if attributes == [.font] { return "\(name.capitalisedFirst) font changed" }
        let labels = attributes.map(\.humanLabel).joined(separator: ", ")
        return "\(name.capitalisedFirst) changed (\(labels))"
    }

    /// A lower-case element-kind noun for summaries.
    static func kindName(_ kind: ElementKind) -> String {
        switch kind {
        case .path: return "path"
        case .rect: return "rectangle"
        case .ellipse: return "ellipse"
        case .roundRect: return "rounded rectangle"
        case .polygon: return "polygon"
        case .polyline: return "polyline"
        case .line: return "line"
        case .arc: return "arc"
        case .bezier: return "curve"
        case .text: return "text"
        case .image: return "image"
        case .group: return "group"
        case .passthrough: return "other content"
        }
    }

    // MARK: - Match helpers

    /// A cheap bucket key for the identical-element pass.
    private static func matchHash(_ e: Element) -> Int {
        var hasher = Hasher()
        hasher.combine(e.kind)
        hasher.combine(e.boundsDevice.origin.x)
        hasher.combine(e.boundsDevice.origin.y)
        hasher.combine(e.text?.string)
        return hasher.finalize()
    }

    private static func centre(_ r: CGRect) -> CGPoint {
        r.isNull ? .zero : CGPoint(x: r.midX, y: r.midY)
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return dx * dx + dy * dy
    }

    private static func sizeApproxEqual(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    private static func pathApproxEqual(_ a: ScenePath, _ b: ScenePath) -> Bool {
        let ba = a.boundingBox, bb = b.boundingBox
        return abs(ba.minX - bb.minX) <= 0.5 && abs(ba.minY - bb.minY) <= 0.5
            && abs(ba.width - bb.width) <= 0.5 && abs(ba.height - bb.height) <= 0.5
            && a.segments.count == b.segments.count
    }
}

extension DrawingComparison.Attribute {
    /// A short human label for the attribute.
    public var humanLabel: String {
        switch self {
        case .position: return "position"
        case .geometry: return "shape"
        case .fillColor: return "fill colour"
        case .strokeColor: return "stroke colour"
        case .text: return "text"
        case .font: return "font"
        case .other: return "properties"
        }
    }
}

extension String {
    /// The string with its first character upper-cased (en-AU sentence case).
    var capitalisedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
