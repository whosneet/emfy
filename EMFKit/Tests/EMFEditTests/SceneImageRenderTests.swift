import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// E3c review: an edited/new image element draws straight from decoded pixels (cached
/// once), not synthesise → STRETCHDIBITS → per-pixel re-decode per tile. These prove the
/// direct draw is upright, matches the synthesis path within snapshot tolerance, and is
/// fast enough that a large inserted image no longer wedges a tiled repaint.
struct SceneImageRenderTests {

    private func a4Landscape() throws -> Scene {
        try SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
    }

    // MARK: - Orientation

    @Test func insertedImageOrientationMatchesSynthesisPath() throws {
        // An image whose two halves are clearly different colours (red / blue) decisively
        // catches a vertical flip. The direct path must place red and blue the SAME way the
        // oracle STRETCHDIBITS path does — a convention-independent orientation proof.
        let cg = try halfRedHalfBlue(width: 160, height: 160)
        var scene = try a4Landscape()
        let rect = CGRect(x: 200, y: 150, width: 300, height: 220)
        scene.insert(try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: rect, id: 0)), at: 0)

        let direct = try #require(SceneRenderer.makeImage(scene, scale: 0.5))
        let exported = try SceneExporter.export(scene, as: .emf)
        let opened = try #require(try? OpenedMetafile.open(exported.data))
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let reference = try #require(MetafileRenderer.makeImage(prepared, scale: 0.5)).0

        let directBands = redBlueCentroidY(direct)
        let refBands = redBlueCentroidY(reference)
        #expect(directBands.redN > 200 && directBands.blueN > 200)
        #expect(refBands.redN > 200 && refBands.blueN > 200)
        // Same vertical ordering in both: no flip introduced by the direct draw. (A
        // vertical flip would reverse the sign of redY-blueY.)
        let directAbove = directBands.redY < directBands.blueY
        let refAbove = refBands.redY < refBands.blueY
        #expect(directAbove == refAbove)
        // And a full-image compare confirms it pixel-for-pixel within tolerance.
        let diff = compareImages(direct, reference, tolerance: 24)
        #expect(diff.sameSize && diff.differingFraction < 0.03)
    }

    /// The average bottom-origin row of the red and blue pixels in a rendered image.
    private func redBlueCentroidY(_ image: CGImage) -> (redY: Double, redN: Int, blueY: Double, blueN: Int) {
        guard let pixels = PixelImage(image) else { return (0, 0, 0, 0) }
        var redSumY = 0, redN = 0, blueSumY = 0, blueN = 0
        for y in 0 ..< pixels.height {
            for x in 0 ..< pixels.width {
                let i = (y * pixels.width + x) * 4
                let r = pixels.pixels[i], g = pixels.pixels[i + 1], b = pixels.pixels[i + 2]
                if r > 180 && g < 80 && b < 80 { redSumY += y; redN += 1 }
                else if b > 180 && g < 80 && r < 80 { blueSumY += y; blueN += 1 }
            }
        }
        return (Double(redSumY) / Double(max(redN, 1)), redN, Double(blueSumY) / Double(max(blueN, 1)), blueN)
    }

    // MARK: - Equivalence with the synthesis (STRETCHDIBITS) path

    @Test func directImageRenderMatchesExportedEMF() throws {
        var scene = try a4Landscape()
        let cg = try gradientImage(width: 320, height: 200)
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 320, height: 200), pageBoundsDevice: scene.pageBoundsDevice)
        scene.insert(try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: rect, id: 0)), at: 0)

        // The direct (new) path.
        let direct = try #require(SceneRenderer.makeImage(scene, scale: 0.5))
        // The synthesis path: export (STRETCHDIBITS) then render through the viewer's engine.
        let exported = try SceneExporter.export(scene, as: .emf)
        let opened = try #require(try? OpenedMetafile.open(exported.data))
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let reference = try #require(MetafileRenderer.makeImage(prepared, scale: 0.5)).0

        let diff = compareImages(direct, reference, tolerance: 24)
        #expect(diff.sameSize)
        // The two engines interpolate slightly differently at the gradient; the bulk of the
        // canvas matches.
        #expect(diff.differingFraction < 0.03)
    }

    // MARK: - Performance (the review hang)

    @Test func largeInsertedImageTileRenderIsFast() throws {
        // A 4096 × 3072 image inserted into an A4 page — the review's trigger.
        var scene = try a4Landscape()
        let cg = try gradientImage(width: 4096, height: 3072)
        let rect = SceneFactory.fitImageRect(imagePixelSize: CGSize(width: 4096, height: 3072), pageBoundsDevice: scene.pageBoundsDevice)
        scene.insert(try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: rect, id: 0)), at: 0)

        // A tiled canvas prepares the source once and renders every tile reusing it.
        let source = try #require(SceneRenderer.prepare(scene))
        let target = CGRect(origin: .zero, size: scene.pageSizeDevice)

        var times: [Double] = []
        let tileCount = 24
        for _ in 0 ..< tileCount {
            let ctx = try #require(tile(512, 512))
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                SceneRenderer.render(scene, into: ctx, target: target, source: source)
            }
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        times.sort()
        let median = times[times.count / 2]
        let total = times.reduce(0, +)
        print("[perf] large inserted-image 512^2 render: median=\(String(format: "%.1f", median)) ms, total(\(tileCount))=\(String(format: "%.1f", total)) ms, first=\(String(format: "%.1f", times.isEmpty ? 0 : times[0])) ms")
        // The hang was multiple SECONDS PER tile (whole-canvas capture never finished). With
        // the decode cached once, each tile render is well under this generous Debug bound.
        #expect(median < 500)
        #expect(total < 4000)
    }

    @Test func imageDecodeCacheDecodesOnce() throws {
        var scene = try a4Landscape()
        let cg = try gradientImage(width: 256, height: 256)
        scene.insert(try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: CGRect(x: 100, y: 100, width: 300, height: 300), id: 0)), at: 0)
        let source = try #require(SceneRenderer.prepare(scene))
        let element = try #require(scene.editableElements.first { $0.kind == .image })
        let first = source.imageCache.image(for: element)
        let second = source.imageCache.image(for: element)
        #expect(first != nil)
        // Same decoded instance returned (memoised, not re-decoded).
        #expect(first === second)
    }

    // MARK: - Fixtures

    private func gradientImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.3, blue: 0.1, alpha: 1)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return try #require(ctx.makeImage())
    }

    /// A top-down image: the top half red, the bottom half blue.
    private func halfRedHalfBlue(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // The context is bottom-origin; the TOP half of the image is the HIGH-y rows.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))   // bottom half → blue
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))   // top half → red
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try #require(ctx.makeImage())
    }

    private func tile(_ width: Int, _ height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
