import CoreGraphics
import EMFEdit

/// Builds a scene with the given element ids hidden, so the tiled canvas can draw
/// everything EXCEPT the selection during a live drag (one re-render), while the
/// moving ghost raster sits on top (design call E2b-6).
enum SceneGhostSupport {
    static func hiding(ids: Set<Int>, in scene: Scene) -> Scene {
        guard !ids.isEmpty else { return scene }
        var copy = scene
        for layerIndex in copy.layers.indices {
            for elementIndex in copy.layers[layerIndex].elements.indices
            where ids.contains(copy.layers[layerIndex].elements[elementIndex].id) {
                copy.layers[layerIndex].elements[elementIndex].hidden = true
            }
        }
        return copy
    }
}

/// Rasterises just the selected elements into a transparent image, once at drag
/// start, so the live drag only moves/scales/rotates that image — never re-renders
/// the scene per frame (design call E2b-6).
enum GhostRasterizer {
    static func image(scene: Scene, ids: Set<Int>, deviceBounds: CGRect, pixelScale: CGFloat) -> CGImage? {
        guard !ids.isEmpty, deviceBounds.width > 0, deviceBounds.height > 0 else { return nil }
        let width = max(1, Int((deviceBounds.width * pixelScale).rounded()))
        let height = max(1, Int((deviceBounds.height * pixelScale).rounded()))
        // Cap the ghost so a huge selection at high zoom never allocates a monster.
        guard width <= 8192, height <= 8192,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // A subset scene whose page is the selection's device bounds, so the render
        // maps exactly the selection region onto the full transparent context.
        let selected = scene.elements.filter { ids.contains($0.id) }
        let layer = Layer(id: 0, name: "ghost", elements: selected)
        let subset = Scene(pageBoundsDevice: deviceBounds, layers: [layer], partition: scene.partition, source: scene.source)
        SceneRenderer.render(subset, into: context, target: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
