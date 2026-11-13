// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for EMR_GRADIENTFILL (118). A horizontal two-colour
/// rectangle gradient (red→blue, exact CGGradient) and a three-colour Gouraud
/// triangle (red/green/blue corners, mesh approximation) render to the accepted
/// baseline.
@Suite("GRADIENTFILL render snapshot")
struct SnapshotGradientFillTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 219, 119)

        // RECT_H: red (left) → blue (right), across a 90×40 box at (10,10).
        f.gradientFill(
            bounds: (10, 10, 100, 50),
            vertices: [
                RenderFixture.triVertex(x: 10, y: 10, r: 230, g: 30, b: 30),
                RenderFixture.triVertex(x: 100, y: 50, r: 30, g: 30, b: 230),
            ],
            mode: 0,   // GRADIENT_FILL_RECT_H
            mesh: [0, 1]
        )

        // TRIANGLE: red / green / blue corners.
        f.gradientFill(
            bounds: (10, 60, 120, 110),
            vertices: [
                RenderFixture.triVertex(x: 20, y: 105, r: 230, g: 20, b: 20),
                RenderFixture.triVertex(x: 110, y: 105, r: 20, g: 230, b: 20),
                RenderFixture.triVertex(x: 65, y: 62, r: 20, g: 20, b: 230),
            ],
            mode: 2,   // GRADIENT_FILL_TRIANGLE
            mesh: [0, 1, 2]
        )
        return f
    }

    @Test("rectangle and triangle gradients render to the accepted baseline")
    func gradients() throws {
        let file = try Self.fixture().parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 220)
        #expect(image.height == 120)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)],
                "unexpected render log: \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-gradientfill")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
