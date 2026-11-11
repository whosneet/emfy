import CoreGraphics
import Foundation

// MARK: - Action name

/// A plain, localisable name for an undoable step, surfaced in the app's
/// Undo/Redo menu (E2). `key` is a stable string the UI maps to a user-facing,
/// translated phrase — the model never hard-codes display text.
public enum SceneActionName: Sendable, Equatable, Hashable {
    case move
    case transform
    case delete
    case insert
    case changeFill
    case changeStroke
    case changeOpacity
    case changeText
    case changeFont
    /// A caller-named group (e.g. "Recolour", "Paste"). The payload is the
    /// localisation key.
    case group(String)

    /// A stable localisation key for this action.
    public var key: String {
        switch self {
        case .move: return "edit.action.move"
        case .transform: return "edit.action.transform"
        case .delete: return "edit.action.delete"
        case .insert: return "edit.action.insert"
        case .changeFill: return "edit.action.changeFill"
        case .changeStroke: return "edit.action.changeStroke"
        case .changeOpacity: return "edit.action.changeOpacity"
        case .changeText: return "edit.action.changeText"
        case .changeFont: return "edit.action.changeFont"
        case .group(let key): return key
        }
    }
}

// MARK: - Coalescing

/// Marks a run of edits to collapse into one undo step (an in-progress drag, a
/// colour-well scrub). Two consecutive `apply`s that pass the same non-nil key
/// over the same element set merge into a single step. The key is caller-chosen
/// and value-based — coalescing is explicit and timer-free, so it is
/// deterministic in tests (docs/v3-plan §11.1).
public struct SceneCoalescingKey: Sendable, Hashable {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Command

/// One undoable user operation over a `Scene`. A command is a pure description:
/// `SceneHistory` executes it against its scene, captures the exact inverse, and
/// records a reversible step. Every command maps 1:1 onto a `SceneMutation`
/// primitive, so it inherits the up-front validation — a command that is refused
/// throws `SceneEditError` and leaves the scene untouched.
public enum SceneCommand: Sendable, Equatable {
    case delete(ids: Set<Int>)
    case insert(element: Element, at: Int)
    case translate(ids: Set<Int>, dx: Double, dy: Double)
    case applyTransform(ids: Set<Int>, CGAffineTransform)
    /// Sets the fill of the named elements; `nil` clears it (no fill → NULL_BRUSH on
    /// GDI, no EMF+ fill, `fill="none"` on SVG), the Fill ▸ None action (E2c).
    case setFill(ids: Set<Int>, SceneFill?)
    case setStroke(ids: Set<Int>, SceneStroke?)
    case setOpacity(ids: Set<Int>, Double)
    case setText(id: Int, String)
    case setFont(id: Int, family: String, size: Int32, bold: Bool, italic: Bool)

    /// The default menu name for this command (the caller may override per apply).
    public var actionName: SceneActionName {
        switch self {
        case .delete: return .delete
        case .insert: return .insert
        case .translate: return .move
        case .applyTransform: return .transform
        case .setFill: return .changeFill
        case .setStroke: return .changeStroke
        case .setOpacity: return .changeOpacity
        case .setText: return .changeText
        case .setFont: return .changeFont
        }
    }
}

// MARK: - Reversible change (the recorded inverse)

/// The captured, reversible effect of a command.
///
/// Design: a *per-command inverse diff*, not a whole-scene snapshot. An in-place
/// edit stores only the touched elements' prior AND posterior values (`.edit`); a
/// structural edit stores the removed/inserted elements with their positions
/// (`.structural`). Undo and redo then just copy stored `Element` values back, so
/// both directions are byte-for-byte exact (`Scene` Equatable) — including
/// provenance.edited, ids, z-order, captured advances, layout rects and image
/// bytes — with none of the floating-point drift a mathematical inverse transform
/// would introduce. Cost is O(touched elements) per step, never O(scene): a
/// 60-step drag coalesces to two stored element values.
enum SceneChange: Sendable, Equatable {
    /// Elements edited in place (same id, same position). `before`→undo,
    /// `after`→redo.
    case edit([ElementSnapshot])
    /// A structural edit: the forward op removed `removed` and inserted
    /// `inserted` (each with its layer/index). `restoreToEmptyLayers` marks the
    /// edge case where an insert created the scene's sole layer.
    case structural(removed: [PlacedElement], inserted: [PlacedElement], restoreToEmptyLayers: Bool)
}

/// The prior and posterior value of one in-place-edited element.
struct ElementSnapshot: Sendable, Equatable {
    var id: Int
    var before: Element
    var after: Element
}

/// An element with the layer index and element index it occupied, for exact
/// structural restoration.
struct PlacedElement: Sendable, Equatable {
    var layer: Int
    var index: Int
    var element: Element
}

// MARK: - Execution

extension Scene {

    /// Executes `command`, mutating the scene and returning the reversible change,
    /// or throws `SceneEditError` (leaving the scene unchanged — the underlying
    /// mutation validates up front). The returned change is what `SceneHistory`
    /// records; it is never applied forward here (the mutation already did that).
    mutating func perform(_ command: SceneCommand) throws(SceneEditError) -> SceneChange {
        switch command {
        case .delete(let ids):
            // Capture positions BEFORE deletion; `delete` validates up front.
            let removed = placements(of: ids)
            try delete(ids)
            return .structural(removed: removed, inserted: [], restoreToEmptyLayers: false)

        case .insert(let element, let z):
            let wasEmpty = layers.isEmpty
            let clamped = wasEmpty ? 0 : Swift.max(0, Swift.min(z, layers[0].elements.count))
            insert(element, at: z)
            return .structural(removed: [], inserted: [PlacedElement(layer: 0, index: clamped, element: element)], restoreToEmptyLayers: wasEmpty)

        case .translate(let ids, let dx, let dy):
            let befores = elementsByID(ids)
            try translate(ids, dx: dx, dy: dy)
            return editChange(ids: ids, befores: befores)

        case .applyTransform(let ids, let t):
            let befores = elementsByID(ids)
            try applyTransform(ids, t)
            return editChange(ids: ids, befores: befores)

        case .setFill(let ids, let fill):
            let befores = elementsByID(ids)
            try setFill(ids, fill)
            return editChange(ids: ids, befores: befores)

        case .setStroke(let ids, let stroke):
            let befores = elementsByID(ids)
            try setStroke(ids, stroke)
            return editChange(ids: ids, befores: befores)

        case .setOpacity(let ids, let opacity):
            let befores = elementsByID(ids)
            try setOpacity(ids, opacity)
            return editChange(ids: ids, befores: befores)

        case .setText(let id, let string):
            let befores = elementsByID([id])
            try setText(id, string)
            return editChange(ids: [id], befores: befores)

        case .setFont(let id, let family, let size, let bold, let italic):
            let befores = elementsByID([id])
            try setFont(id, family: family, size: size, bold: bold, italic: italic)
            return editChange(ids: [id], befores: befores)
        }
    }

    /// Reverses `change` (the undo direction).
    mutating func undoChange(_ change: SceneChange) {
        switch change {
        case .edit(let snapshots):
            overwrite(snapshots.map { ($0.id, $0.before) })
        case .structural(let removed, let inserted, let restoreToEmptyLayers):
            // Undo the forward op: drop what it inserted, restore what it removed.
            removeByID(Set(inserted.map { $0.element.id }))
            if restoreToEmptyLayers { layers = [] }
            reinsert(removed)
        }
    }

    /// Re-applies `change` (the redo direction).
    mutating func redoChange(_ change: SceneChange) {
        switch change {
        case .edit(let snapshots):
            overwrite(snapshots.map { ($0.id, $0.after) })
        case .structural(let removed, let inserted, let restoreToEmptyLayers):
            removeByID(Set(removed.map { $0.element.id }))
            reinsert(inserted, createLayerIfEmpty: restoreToEmptyLayers)
        }
    }

    // MARK: Change helpers

    /// After an in-place mutation, pairs each touched element's prior value with
    /// its current value. One scan; order is id-sorted for deterministic steps.
    private func editChange(ids: Set<Int>, befores: [Int: Element]) -> SceneChange {
        let afters = elementsByID(ids)
        var snapshots: [ElementSnapshot] = []
        snapshots.reserveCapacity(befores.count)
        for id in ids.sorted() {
            guard let before = befores[id], let after = afters[id] else { continue }
            snapshots.append(ElementSnapshot(id: id, before: before, after: after))
        }
        return .edit(snapshots)
    }

    /// The current value of every element whose id is in `ids` (one scan). Copies
    /// only the touched elements — never the whole element array. Index-based so
    /// the scan reads ids in place (no per-element ARC traffic) on huge scenes.
    private func elementsByID(_ ids: Set<Int>) -> [Int: Element] {
        var out: [Int: Element] = [:]
        out.reserveCapacity(ids.count)
        for layerIndex in layers.indices {
            let elements = layers[layerIndex].elements
            for elementIndex in elements.indices where ids.contains(elements[elementIndex].id) {
                out[elements[elementIndex].id] = elements[elementIndex]
            }
        }
        return out
    }

    /// The (layer, index, element) of every element whose id is in `ids`, in
    /// ascending (layer, index) order (one scan).
    private func placements(of ids: Set<Int>) -> [PlacedElement] {
        var out: [PlacedElement] = []
        for layerIndex in layers.indices {
            let elements = layers[layerIndex].elements
            for elementIndex in elements.indices where ids.contains(elements[elementIndex].id) {
                out.append(PlacedElement(layer: layerIndex, index: elementIndex, element: elements[elementIndex]))
            }
        }
        return out
    }

    /// Overwrites each listed element (located by id, wherever it now sits) with
    /// the given value. Positions are unchanged by in-place edits, so this is exact.
    private mutating func overwrite(_ values: [(Int, Element)]) {
        guard !values.isEmpty else { return }
        let byID = Dictionary(values, uniquingKeysWith: { _, newer in newer })
        for layerIndex in layers.indices {
            for elementIndex in layers[layerIndex].elements.indices {
                if let value = byID[layers[layerIndex].elements[elementIndex].id] {
                    layers[layerIndex].elements[elementIndex] = value
                }
            }
        }
    }

    private mutating func removeByID(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        for layerIndex in layers.indices {
            layers[layerIndex].elements.removeAll { ids.contains($0.id) }
        }
    }

    /// Re-inserts placed elements at their recorded positions. Ascending
    /// (layer, index) order restores exact positions. `createLayerIfEmpty` handles
    /// the edge where the forward insert created the sole layer.
    private mutating func reinsert(_ placements: [PlacedElement], createLayerIfEmpty: Bool = false) {
        let ordered = placements.sorted {
            $0.layer != $1.layer ? $0.layer < $1.layer : $0.index < $1.index
        }
        for placement in ordered {
            if placement.layer < layers.count {
                let index = Swift.max(0, Swift.min(placement.index, layers[placement.layer].elements.count))
                layers[placement.layer].elements.insert(placement.element, at: index)
            } else if createLayerIfEmpty && layers.isEmpty && placement.layer == 0 {
                // Mirrors Scene.insert's empty-scene behaviour.
                layers = [Layer(id: 0, name: "Imported", elements: [placement.element])]
            } else if layers.isEmpty {
                layers = [Layer(id: 0, name: "Imported", elements: [placement.element])]
            } else {
                layers[layers.count - 1].elements.append(placement.element)
            }
        }
    }
}
