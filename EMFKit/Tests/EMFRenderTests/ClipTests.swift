import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Phase-3 clipping ([MS-EMF] §2.3.2): EMR_INTERSECTCLIPRECT, EMR_SELECTCLIPPATH,
/// EMR_EXTSELECTCLIPRGN, held in device space and applied per draw inside a
/// gstate save/restore. Probes on the 100×100 MM_TEXT canvas (logical == device
/// == image pixel).
@Suite("Clipping")
struct ClipTests {

    /// A black brush + NULL pen; the full canvas is then filled by a rectangle
    /// so the ONLY thing shaping the ink is the clip.
    private static func fillFullCanvas(_ fixture: inout RenderFixture) {
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)     // NULL_PEN
    }

    private static func fullRect(_ fixture: inout RenderFixture) {
        fixture.rectangle(0, 0, 100, 100)
    }

    private static func render(_ fixture: RenderFixture) throws -> (RasterizedImage, EMFRenderLog) {
        let file = try fixture.parsed()
        let (image, log) = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
        return (try #require(RasterizedImage(image)), log)
    }

    private static let eofOnly: [EMFRenderLog.Entry] = [.unimplementedRecord(type: 14, count: 1)]

    private static func isBlack(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r < 40 && p.g < 40 && p.b < 40
    }
    private static func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 220 && p.g > 220 && p.b > 220
    }

    // MARK: - INTERSECTCLIPRECT

    @Test("INTERSECTCLIPRECT shrinks subsequent drawing")
    func intersectClipRectShrinks() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 50, 100)   // clip to the LEFT half
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 50]), "inside clip: painted")
        #expect(Self.isWhite(image[75, 50]), "outside clip: unpainted")
    }

    @Test("two INTERSECTCLIPRECTs intersect to their overlap")
    func intersectClipRectStacks() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 60, 100)   // left 0..60
        fixture.intersectClipRect(40, 0, 100, 100) // right 40..100 → overlap 40..60
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[50, 50]), "in the 40..60 overlap: painted")
        #expect(Self.isWhite(image[20, 50]), "left of overlap: clipped out")
        #expect(Self.isWhite(image[80, 50]), "right of overlap: clipped out")
    }

    @Test("the clip survives across unrelated records")
    func clipSurvivesUnrelatedRecords() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 50, 100)
        // Unrelated state records between the clip and the draw.
        fixture.setROP2(0x0D)                 // R2_COPYPEN (silent)
        fixture.setBkMode(0x01)               // TRANSPARENT
        fixture.moveToEx(10, 10)
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 50]), "clip still in effect after unrelated records")
        #expect(Self.isWhite(image[75, 50]))
    }

    @Test("RestoreDC restores the pre-SaveDC clip")
    func restoreDCRestoresClip() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.saveDC()
        fixture.intersectClipRect(0, 0, 50, 100)   // narrow the clip after saving
        fixture.restoreDC(-1)                       // …then restore: clip is gone
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        // The whole canvas paints again — the narrowing was undone.
        #expect(Self.isBlack(image[25, 50]))
        #expect(Self.isBlack(image[75, 50]), "RestoreDC brought back the wide (no) clip")
    }

    @Test("a clip set inside SaveDC does not leak past RestoreDC to later draws")
    func clipDoesNotLeak() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.saveDC()
        fixture.intersectClipRect(0, 0, 50, 100)
        Self.fullRect(&fixture)                     // drawn clipped (left half)
        fixture.restoreDC(-1)
        fixture.rectangle(50, 0, 100, 100)          // right half, now UNclipped
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 50]), "first draw: clipped to left")
        #expect(Self.isBlack(image[75, 50]), "second draw: right half paints, clip did not leak")
    }

    // MARK: - SELECTCLIPPATH

    /// Records a rectangle (0,0)-(50,100) into a bracket and closes it, ready
    /// for SELECTCLIPPATH.
    private static func leftHalfPathBracket(_ fixture: inout RenderFixture) {
        fixture.beginPath()
        fixture.rectangle(0, 0, 50, 100)
        fixture.endPath()
    }

    @Test("SELECTCLIPPATH RGN_COPY replaces the clip with the path")
    func selectClipPathCopy() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        Self.leftHalfPathBracket(&fixture)
        fixture.selectClipPath(0x05)          // RGN_COPY
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 50]), "inside the path clip")
        #expect(Self.isWhite(image[75, 50]), "outside the path clip")
    }

    @Test("SELECTCLIPPATH RGN_AND intersects the clip with the path")
    func selectClipPathAnd() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 100, 50)   // existing clip: TOP half
        Self.leftHalfPathBracket(&fixture)          // path: LEFT half
        fixture.selectClipPath(0x01)                // RGN_AND → top-left quadrant
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 25]), "top-left quadrant: painted")
        #expect(Self.isWhite(image[75, 25]), "top-right: clipped by path")
        #expect(Self.isWhite(image[25, 75]), "bottom-left: clipped by rect")
    }

    @Test("SELECTCLIPPATH with no current path logs noCurrentPath")
    func selectClipPathNoPath() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.selectClipPath(0x05)          // no bracket → nothing to select
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == [
            .noCurrentPath(record: 67),
            .unimplementedRecord(type: 14, count: 1),
        ])
        // With no clip applied, the whole canvas paints.
        #expect(Self.isBlack(image[25, 50]))
        #expect(Self.isBlack(image[75, 50]))
    }

    @Test("SELECTCLIPPATH RGN_OR/XOR/DIFF log and leave the clip unchanged")
    func selectClipPathUnsupportedModes() throws {
        for raw in [UInt32(0x02), 0x03, 0x04] {   // OR, XOR, DIFF
            var fixture = RenderFixture()
            Self.fillFullCanvas(&fixture)
            Self.leftHalfPathBracket(&fixture)
            fixture.selectClipPath(raw)
            Self.fullRect(&fixture)
            let (image, log) = try Self.render(fixture)
            #expect(log.entries == [
                .unsupportedClipMode(record: 67, rawMode: raw),
                .unimplementedRecord(type: 14, count: 1),
            ])
            // Clip unchanged (still none): the whole canvas paints.
            #expect(Self.isBlack(image[25, 50]))
            #expect(Self.isBlack(image[75, 50]), "mode \(raw): clip left unchanged")
        }
    }

    // MARK: - EXTSELECTCLIPRGN

    @Test("EXTSELECTCLIPRGN RGN_COPY with two rects clips to their union")
    func extSelectClipRgnUnion() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        // Two disjoint vertical bands with a gap between (20..40 and 60..80).
        fixture.extSelectClipRgn(mode: 0x05, rects: [   // RGN_COPY
            (l: 20, t: 0, r: 40, b: 100),
            (l: 60, t: 0, r: 80, b: 100),
        ])
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[30, 50]), "first band paints")
        #expect(Self.isBlack(image[70, 50]), "second band paints")
        #expect(Self.isWhite(image[50, 50]), "the gap between bands does NOT paint")
        #expect(Self.isWhite(image[10, 50]), "left of both bands: clipped out")
    }

    @Test("EXTSELECTCLIPRGN RGN_AND intersects the union with the current clip")
    func extSelectClipRgnAnd() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 100, 50)   // existing: TOP half
        fixture.extSelectClipRgn(mode: 0x01, rects: [ // RGN_AND, LEFT band 0..50
            (l: 0, t: 0, r: 50, b: 100),
        ])
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 25]), "top-left: in both")
        #expect(Self.isWhite(image[75, 25]), "top-right: outside the region")
        #expect(Self.isWhite(image[25, 75]), "bottom-left: outside the rect clip")
    }

    @Test("EXTSELECTCLIPRGN reset form (RGN_COPY, no rects) re-opens the full canvas")
    func extSelectClipRgnReset() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        fixture.intersectClipRect(0, 0, 50, 100)   // narrow first
        fixture.extSelectClipRgn(mode: 0x05, rects: [])  // reset to default clip
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[25, 50]))
        #expect(Self.isBlack(image[75, 50]), "reset restored the whole canvas")
    }

    @Test("EXTSELECTCLIPRGN RGN_OR/XOR/DIFF log and leave the clip unchanged")
    func extSelectClipRgnUnsupportedModes() throws {
        for raw in [UInt32(0x02), 0x03, 0x04] {   // OR, XOR, DIFF
            var fixture = RenderFixture()
            Self.fillFullCanvas(&fixture)
            fixture.extSelectClipRgn(mode: raw, rects: [(l: 0, t: 0, r: 50, b: 100)])
            Self.fullRect(&fixture)
            let (image, log) = try Self.render(fixture)
            #expect(log.entries == [
                .unsupportedClipMode(record: 75, rawMode: raw),
                .unimplementedRecord(type: 14, count: 1),
            ])
            #expect(Self.isBlack(image[25, 50]))
            #expect(Self.isBlack(image[75, 50]), "mode \(raw): clip left unchanged")
        }
    }

    // MARK: - Clip state is saved/restored (DC unit level)

    @Test("SaveDC/RestoreDC round-trips the clip region as saved state")
    func clipIsSavedState() throws {
        var dc = DeviceContext(header: RenderFixtureHeader.make())
        var log = EMFRenderLog()

        _ = dc.apply(.intersectClipRect(clip: RectL(left: 0, top: 0, right: 50, bottom: 100)), log: &log)
        #expect(!dc.state.clip.isEmpty)
        let narrowed = dc.state.clip

        _ = dc.apply(.saveDC, log: &log)
        _ = dc.apply(.intersectClipRect(clip: RectL(left: 0, top: 0, right: 10, bottom: 10)), log: &log)
        #expect(dc.state.clip != narrowed, "clip changed under the save")

        _ = dc.apply(.restoreDC(savedDC: -1), log: &log)
        #expect(dc.state.clip == narrowed, "RestoreDC brought the saved clip back")
        #expect(log.isClean)
    }

    // MARK: - Bounded clip growth (anti-hang, R2)

    @Test("a long INTERSECTCLIPRECT chain folds to one rect equal to the intersection")
    func intersectClipRectChainFoldsAndStaysBounded() throws {
        var dc = DeviceContext(header: RenderFixtureHeader.make())
        var log = EMFRenderLog()
        // A hostile-length chain of single-rect intersections. Each fold is
        // O(1); the list must never grow beyond one primitive.
        for _ in 0 ..< 10_000 {
            _ = dc.apply(.intersectClipRect(clip: RectL(left: 0, top: 0, right: 60, bottom: 100)), log: &log)
            _ = dc.apply(.intersectClipRect(clip: RectL(left: 40, top: 0, right: 100, bottom: 100)), log: &log)
        }
        #expect(dc.state.clip.primitives.count == 1,
                "consecutive single-rect intersections fold in place")
        // The folded clip equals the geometric intersection 40..60 × 0..100.
        guard case .rects(let rects) = dc.state.clip.primitives.first, rects.count == 1 else {
            Issue.record("expected a single folded rect")
            return
        }
        #expect(rects[0] == CGRect(x: 40, y: 0, width: 20, height: 100))
        #expect(log.isClean)
    }

    @Test("the folded clip chain still shapes ink to the intersection")
    func foldedClipChainClipsCorrectly() throws {
        var fixture = RenderFixture()
        Self.fillFullCanvas(&fixture)
        // Many overlapping intersections that reduce to the 40..60 column.
        fixture.intersectClipRect(0, 0, 60, 100)
        fixture.intersectClipRect(40, 0, 100, 100)
        fixture.intersectClipRect(0, 0, 60, 100)
        fixture.intersectClipRect(40, 0, 100, 100)
        Self.fullRect(&fixture)
        let (image, log) = try Self.render(fixture)
        #expect(log.entries == Self.eofOnly)
        #expect(Self.isBlack(image[50, 50]), "inside the folded 40..60 clip: painted")
        #expect(Self.isWhite(image[20, 50]), "left of clip: out")
        #expect(Self.isWhite(image[80, 50]), "right of clip: out")
    }
}

/// A minimal header for constructing a bare `DeviceContext` in unit tests.
enum RenderFixtureHeader {
    static func make() -> EMFHeader {
        EMFHeader(
            bounds: RectL(left: 0, top: 0, right: 99, bottom: 99),
            frame: RectL(left: 0, top: 0, right: 2646, bottom: 2646),
            recordSignature: 0x464D_4520,
            version: 0x0001_0000,
            bytes: 0,
            records: 0,
            handles: 1,
            nDescription: 0,
            offDescription: 0,
            nPalEntries: 0,
            device: SizeL(cx: 1000, cy: 1000),
            millimeters: SizeL(cx: 250, cy: 250),
            extension1: nil,
            extension2: nil,
            description: nil,
            variant: .extension2
        )
    }
}
