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
            let bounds = element.selectionBoundsDevice
            if !bounds.isNull { box = box.isNull ? bounds : box.union(bounds) }
        }
        return box.isNull ? nil : box
    }
}

extension Element {
    /// The element's device-space bounds for the editor's selection box and handles.
    /// For most elements this is `boundsDevice` (geometry ∩ clip). A GDI
    /// text run usually has NO device geometry, so EMFEdit's `boundsDevice` collapses
    /// to the inherited clip — which for a full-page run is the WHOLE PAGE, giving a
    /// page-tall selection box. For those runs a tight box is derived from the run's
    /// own metrics instead (the same estimate EMFEdit's rasteriser uses to place the
    /// glyphs; all fields are public on `SceneText`).
    var selectionBoundsDevice: CGRect {
        if kind == .text, let tight = EditorTextBounds.device(for: self) { return tight }
        return boundsDevice
    }
}

/// A tight device-space bounding box for a text run, from its font metrics and
/// reference point — used when the run carries no device geometry so `boundsDevice`
/// is the inherited page clip. The box is built in the run's PRE-transform
/// (logical/world) space then mapped by `element.transform`; the horizontal anchor
/// follows the text-alignment flags ([MS-EMF] §2.3.11.25) and the vertical band is
/// anchor-agnostic. Mirrors `SceneRasterize.estimatedTextBounds`.
enum EditorTextBounds {
    static func device(for element: Element) -> CGRect? {
        guard element.kind == .text, let text = element.text else { return nil }
        let count = text.string.utf16.count
        guard count > 0 else { return nil }
        var em = abs(Double(text.logicalHeight))
        if em < 1 { em = text.emSize > 0 ? text.emSize : 16 }
        let ref = Double(text.referenceLogical.x)
        let refY = Double(text.referenceLogical.y)
        let advanceSum = text.advancesLogical.reduce(0.0) { $0 + Double($1) }
        let width = advanceSum > 0 ? advanceSum : Double(count) * em
        let x0: Double
        switch text.alignRawValue & 0x6 {
        case 0x2: x0 = ref - width        // TA_RIGHT
        case 0x6: x0 = ref - width / 2    // TA_CENTER
        default:  x0 = ref                // TA_LEFT
        }
        let marginX = em
        let box = CGRect(x: x0 - marginX, y: refY - em * 1.4, width: width + 2 * marginX, height: em * 2.8)
        let device = box.applying(element.transform).standardized
        guard device.origin.x.isFinite, device.origin.y.isFinite,
              device.width.isFinite, device.height.isFinite,
              !device.isNull, device.width > 0, device.height > 0 else { return nil }
        return device
    }
}
