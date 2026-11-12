import CoreGraphics
import Foundation

// MARK: - Arrange (z-order within a layer, E3d)

/// Pure z-order reordering of one layer's elements. Array order is back (index 0)
/// to front (last), matching playback/draw order. Each direction preserves the
/// relative order of the selected elements and of the unselected ones, and is a
/// no-op at the edges — the Keynote "Arrange" semantics (design §4).
public enum SceneArrange {
    public enum Direction: Sendable, Equatable { case toFront, forward, backward, toBack }

    /// Reorders `elements` so the elements whose ids are in `selected` move per
    /// `direction`. Elements not in `selected` keep their relative order.
    public static func reorder(_ elements: [Element], selected: Set<Int>, _ direction: Direction) -> [Element] {
        guard !selected.isEmpty, elements.contains(where: { selected.contains($0.id) }) else { return elements }
        switch direction {
        case .toFront:
            return elements.filter { !selected.contains($0.id) } + elements.filter { selected.contains($0.id) }
        case .toBack:
            return elements.filter { selected.contains($0.id) } + elements.filter { !selected.contains($0.id) }
        case .forward:
            // Walk from the front-most-but-one down, so a contiguous selected block
            // shifts one step toward the front as a unit; a selected element already
            // at the front, or behind another selected element, does not move.
            var out = elements
            var i = out.count - 2
            while i >= 0 {
                if selected.contains(out[i].id) && !selected.contains(out[i + 1].id) { out.swapAt(i, i + 1) }
                i -= 1
            }
            return out
        case .backward:
            var out = elements
            var i = 1
            while i < out.count {
                if selected.contains(out[i].id) && !selected.contains(out[i - 1].id) { out.swapAt(i - 1, i) }
                i += 1
            }
            return out
        }
    }
}

// MARK: - Layer and arrange mutation primitives (E3d)

extension Scene {

    private func requireLayerOrder(ofLayer id: Int) throws(SceneEditError) -> Int {
        guard let order = layerOrder(ofLayer: id) else { throw .layerNotFound(id: id) }
        return order
    }

    /// Inserts a new empty layer named `name` at order index `at` (clamped to
    /// `0...layers.count`) and returns its id. Order 0 is the back-most layer.
    @discardableResult
    public mutating func addLayer(name: String, at order: Int) -> Int {
        let id = nextLayerID
        let clamped = Swift.max(0, Swift.min(order, layers.count))
        layers.insert(Layer(id: id, name: name, elements: []), at: clamped)
        return id
    }

    /// Removes the layer with `id` and every element it holds (design §3). Refuses
    /// to delete the only layer so a scene always keeps at least one.
    public mutating func deleteLayer(_ id: Int) throws(SceneEditError) {
        let order = try requireLayerOrder(ofLayer: id)
        guard layers.count > 1 else { throw .cannotDeleteOnlyLayer }
        layers.remove(at: order)
    }

    /// Renames the layer with `id`.
    public mutating func renameLayer(_ id: Int, _ name: String) throws(SceneEditError) {
        let order = try requireLayerOrder(ofLayer: id)
        layers[order].name = name
    }

    /// Sets the editor-only hidden state of the layer with `id`. Non-destructive:
    /// the layer's elements are still saved and still drawn by other apps (design
    /// §2); Emfy's own renderer and hit-test skip a hidden layer.
    public mutating func setLayerHidden(_ id: Int, _ hidden: Bool) throws(SceneEditError) {
        let order = try requireLayerOrder(ofLayer: id)
        layers[order].hidden = hidden
    }

    /// Sets the editor-only locked state of the layer with `id`. A locked layer
    /// still renders but cannot be selected (design §2).
    public mutating func setLayerLocked(_ id: Int, _ locked: Bool) throws(SceneEditError) {
        let order = try requireLayerOrder(ofLayer: id)
        layers[order].locked = locked
    }

    /// Reorders the layers to match `orderedIDs` (back-to-front). Must name every
    /// existing layer exactly once.
    public mutating func reorderLayers(_ orderedIDs: [Int]) throws(SceneEditError) {
        guard Set(orderedIDs) == Set(layers.map(\.id)), orderedIDs.count == layers.count else {
            throw .invalidLayerOrder
        }
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        layers = orderedIDs.compactMap { byID[$0] }
    }

    /// Moves the elements whose ids are in `ids` to the TOP (front) of the layer at
    /// order index `toLayer`, preserving their relative z-order. Elements not found,
    /// or already in the target layer, are left where sensible; locked/passthrough
    /// elements move too (moving between layers is not a content edit). The target
    /// index must be in range.
    public mutating func moveElements(_ ids: Set<Int>, toLayer order: Int) throws(SceneEditError) {
        guard order >= 0, order < layers.count else { throw .layerIndexOutOfRange(index: order) }
        guard !ids.isEmpty else { return }
        // Collect the moved elements in overall z-order, then remove them everywhere.
        var moved: [Element] = []
        for li in layers.indices {
            for element in layers[li].elements where ids.contains(element.id) { moved.append(element) }
        }
        guard !moved.isEmpty else { return }
        for li in layers.indices {
            layers[li].elements.removeAll { ids.contains($0.id) }
        }
        layers[order].elements.append(contentsOf: moved)
    }

    /// Inserts `element` at z-index `z` within the layer at order index `layer`
    /// (the active layer, design §3). `z` is clamped to the layer's bounds. An
    /// empty scene creates a default layer, matching `insert(_:at:)`.
    public mutating func insert(_ element: Element, at z: Int, inLayer layer: Int) throws(SceneEditError) {
        guard !layers.isEmpty else {
            layers = [Layer(id: 0, name: Scene.defaultLayerName, elements: [element])]
            return
        }
        guard layer >= 0, layer < layers.count else { throw .layerIndexOutOfRange(index: layer) }
        let clamped = Swift.max(0, Swift.min(z, layers[layer].elements.count))
        layers[layer].elements.insert(element, at: clamped)
    }

    /// Reorders the selected elements within THEIR OWN layer per `direction`
    /// (design §4). Elements in different layers each reorder inside their layer;
    /// z-order never crosses a layer boundary.
    public mutating func arrange(_ ids: Set<Int>, _ direction: SceneArrange.Direction) {
        guard !ids.isEmpty else { return }
        for li in layers.indices {
            let layerSelected = Set(layers[li].elements.filter { ids.contains($0.id) }.map(\.id))
            guard !layerSelected.isEmpty else { continue }
            layers[li].elements = SceneArrange.reorder(layers[li].elements, selected: layerSelected, direction)
        }
    }
}
