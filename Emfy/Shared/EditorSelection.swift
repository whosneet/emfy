import CoreGraphics
import EMFEdit

/// The editor's selection — a pure value type over element ids, one per
/// session/window (design call E2b-4). It survives undo when the ids still exist
/// and prunes any that don't (`prune(to:)`).
struct EditorSelection: Equatable {
    private(set) var ids: Set<Int>

    init(_ ids: Set<Int> = []) { self.ids = ids }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: Int) -> Bool { ids.contains(id) }

    mutating func clear() { ids.removeAll() }
    mutating func replace(with id: Int) { ids = [id] }
    mutating func replace(with newIDs: Set<Int>) { ids = newIDs }
    mutating func toggle(_ id: Int) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// Selects every editable element in the scene (⌘A).
    mutating func selectAll(in scene: Scene) {
        ids = Set(scene.editableElements.map(\.id))
    }

    /// Drops any selected id no longer present in `scene` — after an undo/redo that
    /// removed an element, so the overlay never references a dead id (design call
    /// E2b-4).
    mutating func prune(to scene: Scene) {
        guard !ids.isEmpty else { return }
        let existing = Set(scene.elements.map(\.id))
        ids.formIntersection(existing)
    }

    /// The selection after a click or tap on `hit` (nil = empty space). `additive`
    /// is Shift/⌘ on the Mac: it toggles the hit; a plain click replaces the
    /// selection, or clears it on empty space. An additive click on empty space is a
    /// no-op (design call E2b-4).
    func afterClick(hit: Int?, additive: Bool) -> EditorSelection {
        var next = self
        if let hit {
            if additive { next.toggle(hit) } else { next.replace(with: hit) }
        } else if !additive {
            next.clear()
        }
        return next
    }

    /// The union device-space bounding box of the selected elements, or nil when
    /// nothing valid is selected — the box the overlay draws its handles around.
    func boundsDevice(in scene: Scene) -> CGRect? {
        var box = CGRect.null
        for element in scene.elements where ids.contains(element.id) {
            let bounds = element.boundsDevice
            if !bounds.isNull { box = box.isNull ? bounds : box.union(bounds) }
        }
        return box.isNull ? nil : box
    }
}
