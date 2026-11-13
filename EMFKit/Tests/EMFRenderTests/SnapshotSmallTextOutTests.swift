// Snapshot baselines are macOS-only (CoreText text rasterisation); gated like
// the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for EMR_SMALLTEXTOUT (108). It routes through the same
/// CoreText path as the other text records. The fixture uses ETO_NO_RECT |
/// ETO_SMALL_CHARS so the record omits its Bounds and carries an 8-bit ANSI
/// string, exercising both compact-record flags end to end.
@Suite("SMALLTEXTOUT render snapshot")
struct SnapshotSmallTextOutTests {

    @Test("compact ANSI small-text renders legibly (ETO_NO_RECT | ETO_SMALL_CHARS)")
    func smallText() throws {
        var f = RenderFixture()
        f.bounds = (0, 0, 199, 59)
        f.setTextColor(r: 0, g: 0, b: 0)
        f.extCreateFontIndirectW(index: 1, height: -30, faceName: "Helvetica")
        f.selectObject(1)
        // "Small 123" as 8-bit ANSI, no Bounds rectangle.
        f.smallTextOut(x: 10, y: 15, options: 0x0300,
                       ansiBytes: Array("Small 123".utf8))
        let file = try f.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 200)
        #expect(image.height == 60)
        #expect(log.entries == [.unimplementedRecord(type: 14, count: 1)],
                "unexpected render log: \(log.entries)")

        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-smalltextout")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
