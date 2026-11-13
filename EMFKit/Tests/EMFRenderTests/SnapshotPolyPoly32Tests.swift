// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for the 32-bit poly-poly records EMR_POLYPOLYGON (8) and
/// EMR_POLYPOLYLINE (7). The fixture fills two sub-polygons as one brush-filled
/// figure (so the even-odd rule composes across them, like GDI's PolyPolygon),
/// then strokes a two-segment poly-polyline. Rendered in-memory and compared to
/// the accepted PNG baseline.
@Suite("32-bit poly-poly render snapshot")
struct SnapshotPolyPoly32Tests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 219, 139)
        f.createSolidBrush(index: 1, r: 70, g: 150, b: 220)   // blue fill
        f.createPen(index: 2, style: 0, width: 2, r: 0, g: 0, b: 0)
        f.selectObject(1)
        f.selectObject(2)

        // One PolyPolygon of two triangles — filled + outlined together.
        f.polyPolygon([
            [(10, 10), (90, 10), (50, 70)],
            [(110, 10), (190, 10), (150, 70)],
        ])

        // One PolyPolyline of two open strokes along the bottom.
        f.selectObject(0x8000_0007)   // BLACK_PEN stock, cosmetic
        f.polyPolyline([
            [(10, 90), (60, 130), (110, 90)],
            [(120, 130), (160, 90), (200, 130)],
        ])
        return f
    }

    @Test("polyPolygon fills two triangles, polyPolyline strokes two chevrons")
    func polyPoly() throws {
        let file = try Self.fixture().parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file, scale: 1),
                                        "makeImage returned nil")
        #expect(image.width == 220)
        #expect(image.height == 140)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)],
                "unexpected render log: \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-polypoly32")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
