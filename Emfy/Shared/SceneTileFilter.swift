import CoreGraphics
import EMFEdit

/// Narrows a scene to the elements that can paint inside a tile's view rect, so the
/// editor's tiled renderer processes only the elements in each tile rather than the
/// whole scene per tile (E2b item 5). Elements whose device bounds (grown by their
/// stroke half-width) don't reach the tile paint nothing there, so dropping them is
/// exact — z-order among the survivors is preserved.
enum SceneTileFilter {
    /// `viewRect` is the tile's dirty rect in the tiled view's own coordinate space;
    /// `target` is the render target the view draws the page into (origin-zero, page
    /// size); `flipY` matches the tiled view's y convention (Mac y-up = true, iOS
    /// y-down = false).
    static func subscene(_ scene: EMFEdit.Scene, viewRect: CGRect, target: CGRect, flipY: Bool) -> EMFEdit.Scene {
        let mapping = EditorCanvasMapping(pageBoundsDevice: scene.pageBoundsDevice, target: target, flipY: flipY)
        let deviceRegion = mapping.deviceRect(fromView: viewRect).standardized
        guard deviceRegion.minX.isFinite, deviceRegion.minY.isFinite,
              deviceRegion.width.isFinite, deviceRegion.height.isFinite else { return scene }
        var layers = scene.layers
        var dropped = false
        for layerIndex in layers.indices {
            let before = layers[layerIndex].elements.count
            layers[layerIndex].elements = layers[layerIndex].elements.filter { element in
                let bounds = element.boundsDevice
                if bounds.isNull { return true }   // null-bounds content (structural passthrough) kept
                let half = EditorHitTest.strokeHalfWidthDevice(element)
                return bounds.standardized.insetBy(dx: -half, dy: -half).intersects(deviceRegion)
            }
            if layers[layerIndex].elements.count != before { dropped = true }
        }
        guard dropped else { return scene }
        return EMFEdit.Scene(pageBoundsDevice: scene.pageBoundsDevice, layers: layers, partition: scene.partition, source: scene.source)
    }
}
