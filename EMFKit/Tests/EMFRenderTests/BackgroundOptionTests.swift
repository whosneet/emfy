import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// S1a Export › PNG background: the one public image-API option added to EMFRender.
/// A `.white` render is byte-for-byte the historical default (opaque white page);
/// a `.transparent` render leaves the page clear but keeps every drawn pixel. The
/// fixture fills the left half of a 100×100 canvas solid red, so the right half is
/// background and the left half is ink.
@Suite struct BackgroundOptionTests {

    /// 100×100 EMF with a red polygon over the left half; right half is bare page.
    private func redLeftHalf() throws -> EMFFile {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 255, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)               // NULL_PEN — no outline
        fixture.polygon16([(0, 0), (50, 0), (50, 100), (0, 100)])
        return try fixture.parsed()
    }

    // A background sample well inside the right (undrawn) half.
    private let bg = (x: 80, y: 20)
    // An ink rectangle well inside the left (red) half.
    private let inkRect = (x: 5, y: 5, width: 30, height: 90)

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 200 && p.g < 80 && p.b < 80 && p.a > 200
    }

    @Test("default background is opaque white — unchanged from before the option")
    func defaultIsWhite() throws {
        let file = try redLeftHalf()
        let (image, _) = try #require(EMFRenderer.makeImage(file))     // no background arg
        let raster = try #require(RasterizedImage(image))
        let p = raster[bg.x, bg.y]
        #expect(p.r == 255 && p.g == 255 && p.b == 255 && p.a == 255)
        #expect(raster.contains(in: inkRect, where: isRed), "the drawing must still land")
    }

    @Test("explicit .white matches the default: opaque white page")
    func explicitWhite() throws {
        let file = try redLeftHalf()
        let (image, _) = try #require(EMFRenderer.makeImage(file, scale: 1, background: .white))
        let raster = try #require(RasterizedImage(image))
        let p = raster[bg.x, bg.y]
        #expect(p.r == 255 && p.g == 255 && p.b == 255 && p.a == 255)
    }

    @Test(".transparent clears the page but keeps the drawing")
    func transparentPage() throws {
        let file = try redLeftHalf()
        let (image, _) = try #require(EMFRenderer.makeImage(file, scale: 1, background: .transparent))
        let raster = try #require(RasterizedImage(image))
        // Background is fully clear...
        let p = raster[bg.x, bg.y]
        #expect(p.a == 0, "the undrawn page must be transparent")
        // ...and the ink is untouched.
        #expect(raster.contains(in: inkRect, where: isRed), "transparent must not drop the drawing")
    }

    @Test("MetafileRenderer threads the background through to a prepared EMF")
    func metafileRendererForwards() throws {
        let data = redLeftHalfData()
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened))

        let (whiteImage, _) = try #require(MetafileRenderer.makeImage(prepared, background: .white))
        let white = try #require(RasterizedImage(whiteImage))
        #expect(white[bg.x, bg.y].a == 255)

        let (clearImage, _) = try #require(MetafileRenderer.makeImage(prepared, background: .transparent))
        let clear = try #require(RasterizedImage(clearImage))
        #expect(clear[bg.x, bg.y].a == 0)
    }

    /// The same fixture as raw bytes, for the MetafileRenderer entry point.
    private func redLeftHalfData() -> Data {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 255, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)
        fixture.polygon16([(0, 0), (50, 0), (50, 100), (0, 100)])
        return fixture.data()
    }
}
