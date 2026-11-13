// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R2 render coverage for the EMF-decoded EMR_EXCLUDECLIPRECT (29) and
/// EMR_SETPIXELV (15), both routed to the existing clip/direct-draw paths.
/// A red rectangle fill with a rectangular hole excluded from the clip, plus
/// three blue single-pixel dots. The baseline was accepted by first principles
/// (no LibreOffice) plus a visual read: the red fill shows the excluded hole,
/// and the three dots sit at their pixel coordinates.
@Suite("SETPIXELV / EXCLUDECLIPRECT render snapshot")
struct SnapshotSetPixelVExcludeClipTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 119, 119)

        f.createSolidBrush(index: 1, r: 210, g: 40, b: 40)
        f.selectObject(1)
        f.selectObject(0x8000_0008)           // NULL_PEN

        // Carve a hole, then fill the rectangle: the hole stays unpainted.
        f.excludeClipRect(45, 45, 75, 75)
        f.rectangle(15, 15, 105, 105)

        // Three blue single pixels (device coordinates).
        f.setPixelV(20, 20, r: 20, g: 40, b: 220)
        f.setPixelV(60, 20, r: 20, g: 40, b: 220)
        f.setPixelV(100, 100, r: 20, g: 40, b: 220)
        return f
    }

    @Test("an EMF exclude-clip hole and SETPIXELV dots render to the accepted baseline")
    func excludeAndPixels() throws {
        let file = try Self.fixture().parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 120)
        #expect(image.height == 120)

        let failure = SnapshotComparator.verify(image, baselineNamed: "r2-setpixelv-excludeclip")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
