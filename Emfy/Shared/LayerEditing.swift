import CoreGraphics
import EMFEdit
import Foundation

// Pure helpers for the Layers panel, the active-layer insert and Arrange (E3d), kept
// out of the SwiftUI views and the AppKit/UIKit canvases so each decision unit-tests
// on any platform without a host.

/// Where a newly-created element lands: the active layer, falling back to the scene's
/// default active (top) layer when no layer is active or the active one was deleted.
enum ActiveLayerInsert {
    /// The order index (0 = back) of the active layer for a new insert: the resolved
    /// active id if it still exists, else the scene's default active (top) layer, else 0.
    static func order(activeLayerID: Int?, in scene: Scene) -> Int {
        if let id = activeLayerID, let order = scene.layerOrder(ofLayer: id) { return order }
        if let id = scene.defaultActiveLayerID, let order = scene.layerOrder(ofLayer: id) { return order }
        return 0
    }

    /// Rewrites a freshly-built `.insert(element:at:)` into an `.insertInLayer` that places
    /// the element on top of the active layer; any other command passes through unchanged.
    /// With a single layer the target is order 0 — identical to the pre-E3d `.insert`, so
    /// the E3a–c inserts are unchanged.
    static func route(_ command: SceneCommand, activeLayerID: Int?, in scene: Scene) -> SceneCommand {
        guard case .insert(let element, _) = command else { return command }
        let layer = order(activeLayerID: activeLayerID, in: scene)
        let z = (layer >= 0 && layer < scene.layers.count) ? scene.layers[layer].elements.count : 0
        return .insertInLayer(element: element, at: z, layer: layer)
    }
}

/// Layer-name hygiene for inline rename and the "+" auto-name (design §3).
enum LayerName {
    /// The hard cap on a layer name, matching the brief.
    static let maxLength = 256

    /// Trims surrounding whitespace/newlines, strips control characters (a layer name is a
    /// single line), and caps at 256 characters. Returns nil when nothing usable remains,
    /// so a rename keeps the previous name rather than blanking it.
    static func sanitised(_ raw: String) -> String? {
        let stripped = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    /// The default name for a new layer: "Layer N" with the smallest N not already taken by
    /// an existing layer name, so the "+" button never collides.
    static func nextDefault(existing names: [String]) -> String {
        let used = Set(names)
        var n = 1
        while used.contains("Layer \(n)") { n += 1 }
        return "Layer \(n)"
    }
}

/// The delete-"−" decision (design §3): a non-empty layer asks first.
enum LayerDeletion {
    /// Whether deleting a layer needs a confirmation (it still holds elements).
    static func needsConfirmation(elementCount: Int) -> Bool { elementCount > 0 }

    /// The confirmation question for a non-empty layer.
    static func confirmationMessage(name: String, elementCount: Int) -> String {
        "Delete “\(name)” and its \(elementCount) item\(elementCount == 1 ? "" : "s")?"
    }
}

/// The Arrange menu / context-menu enabled state (design §4).
enum ArrangeAvailability {
    /// Arrange is enabled only in edit mode with a non-empty selection.
    static func isEnabled(editing: Bool, selectionCount: Int) -> Bool {
        editing && selectionCount > 0
    }
}
