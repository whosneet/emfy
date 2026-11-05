import Foundation
import Testing
import EMFParse
import EMFWrite

/// The five WMF-sourced payloads are never produced by the EMF decoder (they
/// arrive only from the WMF translator), so they have no decode→encode
/// round-trip through EMFParse. Four of them lower to real EMF records — these
/// tests pin the exact bytes against the spec layout; `.patBlt` has no single
/// EMF record and must raise a typed error (it belongs to the WMF writer, E0c).
@Suite("WMF-sourced payload encoding (byte shape; no EMF round-trip)")
struct WMFSourcedEncodeTests {

    static func rectBytes(_ r: RectL) -> [UInt8] {
        var w = LE(); w.i32(r.left); w.i32(r.top); w.i32(r.right); w.i32(r.bottom); return w.bytes
    }

    @Test func pieLowersToEMRPie() throws {
        let box = RectL(left: 0, top: 0, right: 20, bottom: 20)
        let payload = EMFRecordPayload.pie(ArcPayload(box: box,
                                                      start: PointL(x: 20, y: 10),
                                                      end: PointL(x: 0, y: 10)))
        let bytes = [UInt8](try EMFRecordEncoder.encode(payload))
        var expect = LE()
        expect.u32(47); expect.u32(40)
        expect.raw(Self.rectBytes(box))
        expect.i32(20); expect.i32(10); expect.i32(0); expect.i32(10)
        #expect(bytes == expect.bytes)
    }

    @Test func chordLowersToEMRChord() throws {
        let box = RectL(left: 1, top: 2, right: 30, bottom: 40)
        let payload = EMFRecordPayload.chord(ArcPayload(box: box,
                                                        start: PointL(x: 5, y: 6),
                                                        end: PointL(x: 7, y: 8)))
        let bytes = [UInt8](try EMFRecordEncoder.encode(payload))
        #expect(bytes.count == 40)
        #expect(bytes[0] == 46 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0)  // type 46
    }

    @Test func setPixelLowersToEMRSetPixelV() throws {
        let payload = EMFRecordPayload.setPixel(point: PointL(x: 3, y: 4),
                                                color: ColorRef(red: 10, green: 20, blue: 30))
        let bytes = [UInt8](try EMFRecordEncoder.encode(payload))
        var expect = LE()
        expect.u32(15); expect.u32(20)
        expect.i32(3); expect.i32(4)
        expect.raw([10, 20, 30, 0])
        #expect(bytes == expect.bytes)
    }

    @Test func excludeClipRectLowersToEMRExcludeClipRect() throws {
        let clip = RectL(left: 1, top: 2, right: 3, bottom: 4)
        let payload = EMFRecordPayload.excludeClipRect(clip: clip)
        let bytes = [UInt8](try EMFRecordEncoder.encode(payload))
        var expect = LE()
        expect.u32(29); expect.u32(24)
        expect.raw(Self.rectBytes(clip))
        #expect(bytes == expect.bytes)
    }

    @Test func patBltIsTypedError() {
        let payload = EMFRecordPayload.patBlt(bounds: RectL(left: 0, top: 0, right: 5, bottom: 5),
                                              rasterOperation: 0x00F0_0021)
        #expect(throws: EMFWriteError.self) {
            _ = try EMFRecordEncoder.encode(payload)
        }
        #expect(!EMFRecordEncoder.isFaithfullyEncodable(payload))
    }
}
