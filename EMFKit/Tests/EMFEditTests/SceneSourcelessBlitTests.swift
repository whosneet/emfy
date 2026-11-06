import CoreGraphics
import EMFParse
import EMFRender
import EMFWrite
import Foundation
import Testing
@testable import EMFEdit

/// Regression for the E1b1-review finding (robustness fix): a SOURCELESS BITBLT
/// (a PATCOPY-style rop fill, `dib == nil`) paints the destination rectangle with
/// the current brush, but `captureImageOp` used to drop it from the scene lift
/// (`guard … dib != nil else { return }`). The record then became a geometry-less
/// passthrough element with no replay op, so the scene render left the filled area
/// blank — the exact 26.6% divergence seen on corpus-local file index 46 (a chart
/// whose grey bar fills are sourceless BITBLTs). The fix captures the fill as a
/// passthrough op carrying its payload, so the scene replays it.
struct SceneSourcelessBlitTests {

    /// A 100×100 EMF: a solid grey brush, then a sourceless PATCOPY BITBLT filling
    /// the 20,20…80,80 square with that brush. No bitmap bits are embedded.
    private func sourcelessBlitEMF() throws -> Data {
        let bounds = RectL(left: 0, top: 0, right: 99, bottom: 99)
        let builder = EMFDocumentBuilder(bounds: bounds, frame: bounds, device: SizeL(cx: 0, cy: 0), millimeters: SizeL(cx: 0, cy: 0))
        try builder.append(.createBrushIndirect(CreateBrushPayload(ihBrush: 1, style: 0, color: ColorRef(red: 128, green: 128, blue: 128), hatch: 0)))
        try builder.append(.selectObject(.table(index: 1)))
        try builder.append(.bitBlt(BitBltPayload(
            bounds: RectL(left: 20, top: 20, right: 80, bottom: 80),
            dest: PointL(x: 20, y: 20),
            destSize: SizeL(cx: 60, cy: 60),
            rasterOperation: 0x00F0_0021,                 // PATCOPY ([MS-WMF] §2.1.1.31)
            src: PointL(x: 0, y: 0),
            xformSrc: XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 0, dy: 0),
            bkColorSrc: ColorRef(red: 0, green: 0, blue: 0),
            usageSrc: 0,
            srcSize: nil,
            dib: nil                                      // sourceless: a rop fill
        )))
        return try builder.finish()
    }

    @Test func sourcelessBlitFillSurvivesImportAndRender() throws {
        let data = try sourcelessBlitEMF()

        // The lift captures the fill as a passthrough element with real geometry.
        let scene = try SceneImporter.import(data: data)
        #expect(scene.partition.isComplete)
        let blitElements = scene.elements.filter { $0.kind == .passthrough && $0.passthroughReason == .rasterOp }
        #expect(blitElements.count == 1)
        try #require(blitElements.first != nil)
        #expect(!blitElements[0].boundsDevice.isNull, "sourceless blit must carry its device footprint, not empty geometry")

        // The scene render reproduces the source render: the grey square is present.
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened),
              let (sourceImage, _) = MetafileRenderer.makeImage(prepared),
              let sceneImage = SceneRenderer.makeImage(scene)
        else { Issue.record("render failed"); return }
        let diff = compareImages(sceneImage, sourceImage, tolerance: 16)
        #expect(diff.sameSize)
        #expect(diff.differingFraction <= 0.001, "sourceless blit fill diverges by \(diff.differingFraction * 100)%")

        // And the grey fill actually painted (not a blank canvas).
        guard let px = PixelImage(sceneImage) else { Issue.record("decode failed"); return }
        let centre = ((px.height / 2) * px.width + px.width / 2) * 4
        #expect(abs(Int(px.pixels[centre]) - 128) <= 8, "centre pixel should be grey ~128, got \(px.pixels[centre])")
    }
}
