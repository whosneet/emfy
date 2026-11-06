import CoreGraphics
import Foundation

/// Why a scene edit was refused. Edits are value-type and total: a mutation
/// either applies to every named element or throws, leaving the scene untouched
/// (so an undoable command, E1c, never half-applies). Locked and passthrough
/// elements — verbatim content the editor shows but cannot represent editably —
/// reject every mutation (docs/v3-plan §11.1).
public enum SceneEditError: Error, Sendable, Equatable {
    /// No element in any layer carries `id`.
    case elementNotFound(id: Int)
    /// The element is locked, or is a passthrough element (which is always
    /// locked): its content is kept verbatim and cannot be edited in v1.
    case elementLocked(id: Int)
    /// `setText`/`setFont` named an element that is not a text run.
    case notTextElement(id: Int)
}

// MARK: - Element-level edit helpers (internal)

extension Element {
    /// True when this element rejects mutation: explicitly locked, or a
    /// passthrough element (verbatim content with a reason code).
    var rejectsMutation: Bool {
        locked || kind == .passthrough || passthroughReason != nil
    }

    /// Recomputes `boundsDevice` from the current geometry and clip — the same
    /// rule `init` applies. Called after any geometry mutation.
    mutating func recomputeBoundsDevice() {
        var box = geometryDevice.boundingBox
        if let clip = clipDevice, !clip.isEmpty {
            box = box.isNull ? clip.boundingBox : box.intersection(clip.boundingBox)
        }
        boundsDevice = box
    }

    /// Applies a DEVICE-space affine to this element's geometry, clip, image
    /// destination and transform, and flags it edited. Pure value mutation.
    mutating func applyDeviceTransform(_ t: CGAffineTransform) {
        geometryDevice = geometryDevice.applying(t)
        if let clip = clipDevice { clipDevice = clip.applying(t) }
        // The transform carries the logical→device mapping; post-composing the
        // device-space edit keeps text/image synthesis (which maps through it)
        // in step with the moved geometry. Harmless for geometry elements, whose
        // position lives in `geometryDevice`.
        transform = transform.concatenating(t)
        if var img = image {
            // A rotation/shear (or an already-tracked parallelogram) must keep the
            // true four device corners — standardising to a bounding box would
            // silently drop the rotation. An axis-aligned edit keeps the fast
            // bounding-box path. `destRectDevice` always holds the bounding box.
            if img.destCornersDevice != nil || t.b != 0 || t.c != 0 {
                let corners = (img.destCornersDevice ?? img.destRectDevice.standardized.cornersTLTRBRBL).map { $0.applying(t) }
                img.destCornersDevice = corners
                img.destRectDevice = Element.boundingBox(of: corners)
            } else {
                img.destRectDevice = img.destRectDevice.applying(t).standardized
            }
            image = img
        }
        recomputeBoundsDevice()
        provenance.edited = true
    }

    /// The axis-aligned bounding box of device-space points (`.null` if empty).
    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGRect {
    /// The rect's four corners in EMF+ DrawImagePoints order: upper-left,
    /// upper-right, lower-right, lower-left ([MS-EMFPLUS] §2.3.4.9).
    var cornersTLTRBRBL: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
         CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

// MARK: - Scene mutation primitives (E1b1)
//
// Pure value operations E1c will wrap in undoable commands. Each validates
// every named element up front (exists, editable) so a failure leaves the scene
// unchanged. A geometry edit marks provenance `edited`, which the exporter uses
// to synthesise that element in place while re-emitting the rest verbatim.

extension Scene {

    /// Locates an element by id across layers, or nil.
    func element(id: Int) -> Element? {
        for layer in layers {
            if let found = layer.elements.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Validates that each id names an existing, editable element. Throws on the
    /// first problem so the scene is never partially mutated.
    private func validateEditable(_ ids: some Sequence<Int>) throws(SceneEditError) {
        for id in ids {
            guard let element = element(id: id) else { throw .elementNotFound(id: id) }
            if element.rejectsMutation { throw .elementLocked(id: id) }
        }
    }

    /// Mutates every element whose id is in `ids` in place, after validation.
    private mutating func mutate(
        _ ids: Set<Int>,
        _ body: (inout Element) -> Void
    ) throws(SceneEditError) {
        try validateEditable(ids)
        for li in layers.indices {
            for ei in layers[li].elements.indices where ids.contains(layers[li].elements[ei].id) {
                body(&layers[li].elements[ei])
            }
        }
    }

    // MARK: Structural

    /// Removes the named elements. Deleting an element drops only its own drawing
    /// records on export — never the shared state records later elements depend
    /// on (the exporter keeps every state/structural record, docs/v3-plan §11.1).
    public mutating func delete(_ ids: Set<Int>) throws(SceneEditError) {
        try validateEditable(ids)
        for li in layers.indices {
            layers[li].elements.removeAll { ids.contains($0.id) }
        }
    }

    /// Inserts a new element at z-index `z` within the first (imported) layer.
    /// A new element carries no provenance, so the exporter synthesises it after
    /// the last drawing record. `z` is clamped to the layer's bounds.
    public mutating func insert(_ element: Element, at z: Int) {
        guard !layers.isEmpty else {
            layers = [Layer(id: 0, name: "Imported", elements: [element])]
            return
        }
        let clamped = Swift.max(0, Swift.min(z, layers[0].elements.count))
        layers[0].elements.insert(element, at: clamped)
    }

    // MARK: Geometry

    /// Translates the named elements by `(dx, dy)` in DEVICE space.
    public mutating func translate(_ ids: Set<Int>, dx: Double, dy: Double) throws(SceneEditError) {
        try applyTransform(ids, CGAffineTransform(translationX: dx, y: dy))
    }

    /// Applies a DEVICE-space affine to the named elements.
    public mutating func applyTransform(_ ids: Set<Int>, _ t: CGAffineTransform) throws(SceneEditError) {
        try mutate(ids) { $0.applyDeviceTransform(t) }
    }

    // MARK: Paint

    /// Sets the fill of the named elements. For a text run the fill colour is the
    /// text colour (a run's "paint" is its colour), so the change renders and
    /// round-trips; `style.fill` is also recorded for shape elements.
    public mutating func setFill(_ ids: Set<Int>, _ fill: SceneFill) throws(SceneEditError) {
        try mutate(ids) { element in
            element.style.fill = fill
            if element.text != nil { element.text?.color = fill.color }
            element.provenance.edited = true
        }
    }

    /// Sets (or clears, with `nil`) the stroke of the named elements.
    public mutating func setStroke(_ ids: Set<Int>, _ stroke: SceneStroke?) throws(SceneEditError) {
        try mutate(ids) { element in
            element.style.stroke = stroke
            element.provenance.edited = true
        }
    }

    /// Sets the opacity (0…1) of the named elements. GDI export drops sub-1
    /// opacity with a warning (E1b1); E1b2 writes it as EMF+.
    public mutating func setOpacity(_ ids: Set<Int>, _ opacity: Double) throws(SceneEditError) {
        let clamped = Swift.max(0, Swift.min(opacity, 1))
        try mutate(ids) { element in
            element.style.opacity = clamped
            element.provenance.edited = true
        }
    }

    // MARK: Text

    /// Replaces a text run's string.
    public mutating func setText(_ id: Int, _ string: String) throws(SceneEditError) {
        try requireTextElement(id)
        try mutate([id]) { element in
            element.text?.string = string
            element.provenance.edited = true
        }
    }

    /// Sets a text run's font family, size (logical cell/em height, taken as an
    /// em height so the sign matches a LOGFONT negative height), and style. The
    /// requested family is what the exporter re-emits.
    public mutating func setFont(
        _ id: Int, family: String, size: Int32, bold: Bool, italic: Bool
    ) throws(SceneEditError) {
        try requireTextElement(id)
        try mutate([id]) { element in
            element.text?.requestedFamily = family
            element.text?.fontFamily = family
            // Store as a negative (em) height, matching LOGFONT.height semantics
            // ([MS-EMF] §2.2.13); size is treated as the em height in device-
            // independent logical units of the run's current transform.
            element.text?.logicalHeight = -abs(size)
            element.text?.bold = bold
            element.text?.italic = italic
            element.provenance.edited = true
        }
    }

    private func requireTextElement(_ id: Int) throws(SceneEditError) {
        guard let element = element(id: id) else { throw .elementNotFound(id: id) }
        if element.rejectsMutation { throw .elementLocked(id: id) }
        guard element.kind == .text, element.text != nil else { throw .notTextElement(id: id) }
    }
}
