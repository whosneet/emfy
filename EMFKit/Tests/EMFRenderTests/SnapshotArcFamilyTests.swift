// Snapshot baselines are macOS-only (CoreText/CoreGraphics rasterisation is
// platform-specific); gated to macOS like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for the arc family: EMR_PIE (47), EMR_CHORD (46),
/// EMR_ARCTO (55) and EMR_SETARCDIRECTION (57). The fixture draws one filled
/// pie, one filled chord, one stroked arc, and one stroked ArcTo figure under
/// the default AD_COUNTERCLOCKWISE direction, then the SAME pie/chord under
/// AD_CLOCKWISE so the baseline proves the direction flips the swept region.
/// Rendered in-memory from a hand-built EMF (no committed corpus file) and
/// compared to the accepted PNG baseline.
@Suite("Arc-family render snapshot")
struct SnapshotArcFamilyTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 319, 159)

        // An orange solid brush (#1) and a 2px black geometric pen (#2).
        f.createSolidBrush(index: 1, r: 230, g: 120, b: 30)
        f.createPen(index: 2, style: 0, width: 2, r: 0, g: 0, b: 0)   // PS_SOLID geometric
        f.selectObject(1)
        f.selectObject(2)

        // Row 1 — default AD_COUNTERCLOCKWISE.
        f.pie(box: (10, 10, 90, 90), start: (90, 10), end: (10, 10))       // top-half wedge
        f.chord(box: (110, 10, 190, 90), start: (190, 10), end: (110, 10)) // top chord
        f.arc(box: (210, 10, 290, 90), start: (290, 10), end: (210, 10))   // stroked arc

        // An ArcTo figure: move, then connect-and-sweep (updates the position).
        f.moveToEx(10, 150)
        f.arcTo(box: (110, 110, 190, 150), start: (190, 110), end: (110, 110))

        // Row 2 — AD_CLOCKWISE: the same pie/chord sweep the complementary side.
        f.setArcDirection(2)
        f.pie(box: (210, 110, 290, 150), start: (290, 110), end: (210, 110))
        f.chord(box: (110, 110, 190, 150), start: (190, 110), end: (110, 110))
        return f
    }

    @Test("pie, chord, arc, arcTo and arc-direction render to the accepted baseline")
    func arcFamily() throws {
        let file = try Self.fixture().parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file, scale: 1),
                                        "makeImage returned nil")
        #expect(image.width == 320)
        #expect(image.height == 160)
        // Coverage pin: only EOF is skipped — every arc-family record is honoured.
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)],
                "unexpected render log: \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-arc-family")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
