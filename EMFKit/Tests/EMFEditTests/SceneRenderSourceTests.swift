import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// Slice E2b-3: a prepared `SceneRenderSource` (built once) must render a scene
/// pixel-identically to the internal-preparation path, and `makeImage` must place
/// an EDITED element at the same pixel rows as an equivalent `render` (no stray
/// y-flip). These pin both the perf refactor and the render orientation.
struct SceneRenderSourceTests {

    private func bitmap(_ w: Int, _ h: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    private func inkRows(_ image: CGImage) -> (minY: Int, maxY: Int, minX: Int, maxX: Int)? {
        guard let p = PixelImage(image) else { return nil }
        var minX = p.width, minY = p.height, maxX = -1, maxY = -1
        for y in 0 ..< p.height {
            for x in 0 ..< p.width {
                let o = (y * p.width + x) * 4
                if p.pixels[o] < 240 || p.pixels[o + 1] < 240 || p.pixels[o + 2] < 240 {
                    minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                    minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
                }
            }
        }
        return maxX >= 0 ? (minY, maxY, minX, maxX) : nil
    }

    // MARK: - Equivalence: prepared source == internal preparation (item 3)

    /// On every committed fixture with EMF+ or passthrough (text/image) content, a
    /// render reusing a prepared source is byte-identical to a render that prepares
    /// internally — before AND after an edit. The prepared source is the only
    /// difference, so any divergence is the refactor's fault.
    @Test(arguments: ["handmade-emfplus-shapes.emf", "handmade-emfplus-image.emf",
                      "handmade-emfplus-text.emf", "gate-p4-text.emf", "gate-p4-image.emf"])
    func preparedSourceMatchesInternal(_ name: String) throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name))
        var scene = try SceneImporter.import(data: data)
        #expect(SceneRenderer.requiresPreparedSource(scene), "\(name) should need a prepared source")
        // Edit one element so the edited-synthesis path is exercised alongside replay.
        if let id = scene.editableElements.first(where: { !$0.boundsDevice.isNull })?.id {
            try scene.translate([id], dx: 7, dy: 5)
        }
        let src = try #require(SceneRenderer.prepare(scene))
        let w = Int(scene.pageSizeDevice.width), h = Int(scene.pageSizeDevice.height)
        let target = CGRect(x: 0, y: 0, width: w, height: h)

        let a = bitmap(w, h); SceneRenderer.render(scene, into: a, target: target)
        let b = bitmap(w, h); SceneRenderer.render(scene, into: b, target: target, source: src)
        let ia = try #require(a.makeImage()), ib = try #require(b.makeImage())
        let diff = compareImages(ia, ib, tolerance: 0)
        #expect(diff.sameSize)
        #expect(diff.maxChannelDelta == 0, "\(name): prepared-source render differs (maxΔ \(diff.maxChannelDelta))")
        #expect(diff.differingFraction == 0, "\(name): \(diff.differingFraction * 100)% of pixels differ")
    }

    // MARK: - makeImage edited-element orientation (item 5)

    /// A synthetic 100×100 page with ONE filled rect at device y[50,90]. Edited
    /// (moved) it must still land at image rows [50,89] in `makeImage` — NOT the
    /// y-flipped rows [10,49] — matching a `render` into an equivalent bitmap
    /// pixel-for-pixel. Guards against a stray/doubled flip between `makeImage`'s
    /// context and the edited-element synthesis path.
    @Test func makeImageEditedRectIsNotYFlipped() throws {
        func scene(edited: Bool) -> Scene {
            let path = ScenePath(segments: [
                .move(CGPoint(x: 20, y: 50)), .line(CGPoint(x: 80, y: 50)),
                .line(CGPoint(x: 80, y: 90)), .line(CGPoint(x: 20, y: 90)), .close])
            var style = SceneStyle()
            style.fill = SceneFill(color: SceneColor(red: 0, green: 0, blue: 0, alpha: 1), evenOdd: false)
            let el = Element(id: 0, kind: .rect, geometryDevice: path, transform: .identity, style: style,
                             provenance: Provenance(sourceRecordIndices: edited ? [] : [1], edited: edited))
            let src = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
            let part = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
            return Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 100, height: 100),
                         layers: [Layer(id: 0, name: "L", elements: [el])], partition: part, source: src)
        }
        let edited = scene(edited: true)
        let img = try #require(SceneRenderer.makeImage(edited, scale: 1))
        let ink = try #require(inkRows(img))
        // device y[50,90] (y-down) → image rows [50,89] (top-down), not flipped.
        #expect(ink.minY == 50 && ink.maxY == 89, "edited rect at rows [\(ink.minY),\(ink.maxY)], expected [50,89]")
        #expect(ink.minX == 20 && ink.maxX == 79, "edited rect at cols [\(ink.minX),\(ink.maxX)], expected [20,79]")

        // makeImage must equal render into an equivalent context, pixel-for-pixel.
        let ctx = bitmap(img.width, img.height)
        SceneRenderer.render(edited, into: ctx, target: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let img2 = try #require(ctx.makeImage())
        #expect(compareImages(img, img2, tolerance: 0).maxChannelDelta == 0)

        // The edited render must sit exactly where the UNEDITED one does (same shape).
        let un = try #require(SceneRenderer.makeImage(scene(edited: false), scale: 1))
        #expect(compareImages(img, un, tolerance: 0).maxChannelDelta == 0, "edited vs unedited placement differs")
    }

    // MARK: - SceneRasterize orientation (item 5 finding)

    /// Scales a (sub)image into a fresh `side`×`side` top-down bitmap (default CTM,
    /// no flip), for a resample-robust orientation comparison.
    private func normalized(_ image: CGImage, side: Int = 48) -> CGImage? {
        let ctx = bitmap(side, side)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    /// `SceneRasterize.rasterGDI` renders an element into a top-down bitmap via the
    /// same single-y-flip `deviceToTarget` the renderer uses, then `makeImage()`. So
    /// the raster (row 0 = the element's device-min-y) must match the corresponding
    /// top-down crop of a direct render of that element — NOT its vertical mirror.
    /// Proves `SceneRasterize` does not share any y-flip fault. (A flipped rasteriser
    /// would diverge wildly, as an earlier CTM-flip placement of the raster showed.)
    @Test func sceneRasterizeIsNotYFlipped() throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-image.emf"))
        let scene = try SceneImporter.import(data: data)
        let imageEl = try #require(scene.elements.first { $0.kind == .image })
        let source = try #require(SceneRasterize.Source.make(scene, rasterize: { $0.id == imageEl.id }))
        let raster = try #require(SceneRasterize.raster(imageEl, scene: scene, source: source))

        // Direct render of just that image element (top-down, page-sized).
        var only = scene
        for li in only.layers.indices {
            for ei in only.layers[li].elements.indices where only.layers[li].elements[ei].id != imageEl.id {
                only.layers[li].elements[ei].hidden = true
            }
        }
        let direct = try #require(SceneRenderer.makeImage(only, scale: 1))

        // Crop `direct` to the raster's device rect (page origin 0, scale = img/page):
        // device y-down maps straight to image rows (top-down), the same convention
        // the raster image uses, so no flip is involved in the crop itself.
        let pageBounds = scene.pageBoundsDevice
        let sx = CGFloat(direct.width) / Swift.max(pageBounds.width, 1)
        let sy = CGFloat(direct.height) / Swift.max(pageBounds.height, 1)
        let r = raster.deviceRect
        let crop = CGRect(x: (r.minX - pageBounds.minX) * sx, y: (r.minY - pageBounds.minY) * sy,
                          width: r.width * sx, height: r.height * sy).integral
        let cropped = try #require(direct.cropping(to: crop))

        // Normalise both to a common size (the raster is oversampled) and compare. A
        // flip would mirror the rows → the differing fraction would be large.
        let a = try #require(normalized(raster.image))
        let b = try #require(normalized(cropped))
        let upright = compareImages(a, b, tolerance: 48)
        // Also compare against the VERTICALLY MIRRORED crop: if the raster were
        // flipped, this would match better than the upright one.
        let mirror = bitmap(b.width, b.height)
        mirror.translateBy(x: 0, y: CGFloat(b.height)); mirror.scaleBy(x: 1, y: -1)
        mirror.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        let flipped = compareImages(a, try #require(mirror.makeImage()), tolerance: 48)

        #expect(upright.differingFraction < flipped.differingFraction,
                "SceneRasterize orientation: upright \(String(format: "%.1f%%", upright.differingFraction * 100)) vs mirrored \(String(format: "%.1f%%", flipped.differingFraction * 100)) — the rasteriser appears y-flipped")
        #expect(upright.differingFraction < 0.25,
                "SceneRasterize upright mismatch \(String(format: "%.1f%%", upright.differingFraction * 100)) too high")
    }

    // MARK: - Synthesis cache (P9)

    /// Rendering an edited scene through ONE prepared source repeatedly — as a tiled
    /// canvas repaints every tile — is byte-identical to the first render, and the
    /// edited element's throwaway document is synthesised once and memoised rather than
    /// rebuilt per render.
    @Test func repeatedSourceRenderIsStableAndCachesTheSynthesis() throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("handmade-emfplus-shapes.emf"))
        var scene = try SceneImporter.import(data: data)
        let id = try #require(scene.editableElements.first { !$0.boundsDevice.isNull }?.id)
        try scene.translate([id], dx: 7, dy: 5)
        let src = try #require(SceneRenderer.prepare(scene))
        let w = Int(scene.pageSizeDevice.width), h = Int(scene.pageSizeDevice.height)
        let target = CGRect(x: 0, y: 0, width: w, height: h)

        let first = bitmap(w, h); SceneRenderer.render(scene, into: first, target: target, source: src)
        let ia = try #require(first.makeImage())
        for _ in 0 ..< 3 {
            let ctx = bitmap(w, h); SceneRenderer.render(scene, into: ctx, target: target, source: src)
            let ib = try #require(ctx.makeImage())
            #expect(compareImages(ia, ib, tolerance: 0).maxChannelDelta == 0, "a repeated per-tile render diverged")
        }
        #expect(src.synthesisCache.count >= 1, "the edited element should be synthesised and cached")
    }

    /// The synthesis cache rebuilds only when the element VALUE or the page bounds
    /// change (a tile subscene / ghost renders the same source at a different page
    /// bounds), and reuses the memoised document otherwise.
    @Test func synthesisCacheRevalidatesOnValueAndPageBounds() throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-image.emf"))
        let file = try EMFFile.parse(data)
        let cache = SceneRenderer.SynthesisCache()
        var builds = 0
        func build() -> EMFFile? { builds += 1; return file }
        let el = Element(id: 1, kind: .rect, geometryDevice: ScenePath(segments: []), transform: .identity,
                         provenance: Provenance(sourceRecordIndices: [], edited: true))
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        _ = cache.file(for: el, pageBounds: page, build: build)
        _ = cache.file(for: el, pageBounds: page, build: build)        // hit
        #expect(builds == 1)
        var moved = el; moved.transform = CGAffineTransform(translationX: 5, y: 0)
        _ = cache.file(for: moved, pageBounds: page, build: build)     // value changed → rebuild
        #expect(builds == 2)
        _ = cache.file(for: moved, pageBounds: CGRect(x: 0, y: 0, width: 50, height: 50), build: build) // page changed → rebuild
        #expect(builds == 3)
    }
}
