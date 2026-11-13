// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R2 render coverage for EMR_OFFSETCLIPRGN (26) and EMR_SETMETARGN (28). A
/// clip rectangle is shifted by OFFSETCLIPRGN, then a full-canvas green fill
/// paints only the shifted clip box; SETMETARGN is a no-op on the visible clip.
/// The baseline was accepted by first principles (no LibreOffice) plus a visual
/// read: a single green box offset to (50,50)–(90,90), not the original
/// (10,10)–(50,50) clip.
@Suite("OFFSETCLIPRGN render snapshot")
struct SnapshotOffsetClipTests {

    private static func fixture() -> RenderFixture {
        var f = RenderFixture()
        f.bounds = (0, 0, 119, 119)

        f.createSolidBrush(index: 1, r: 40, g: 170, b: 70)
        f.selectObject(1)
        f.selectObject(0x8000_0008)           // NULL_PEN

        f.intersectClipRect(10, 10, 50, 50)   // clip to a 40×40 box
        f.offsetClipRgn(40, 40)               // shift the clip to (50,50)-(90,90)
        f.setMetaRgn()                        // no-op on the visible clip
        f.rectangle(0, 0, 119, 119)           // fills only the shifted clip
        return f
    }

    @Test("an offset clip region shifts the painted area to the accepted baseline")
    func offsetClip() throws {
        let file = try Self.fixture().parsed()
        let (image, _) = try #require(EMFRenderer.makeImage(file, scale: 1), "makeImage returned nil")
        #expect(image.width == 120)
        #expect(image.height == 120)

        let failure = SnapshotComparator.verify(image, baselineNamed: "r2-offsetclip")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
