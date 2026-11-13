import Foundation
import Testing
@testable import EMFParse

/// EMR_SETPIXELV (15, [MS-EMF] §2.3.5.36) and EMR_EXCLUDECLIPRECT (29,
/// §2.3.2.1) byte-fixture decode. Both share a payload and a render path with
/// their WMF-translated analogues; these guard the EMF decoder's new cases.
@Suite("SETPIXELV and EXCLUDECLIPRECT payload decode")
struct PayloadSetPixelVExcludeClipTests {

    @Test("SETPIXELV golden: Pixel PointL then Color ColorRef")
    func setPixelVGolden() throws {
        var payload = FixtureBuilder()
        payload.appendInt32(40)        // Pixel.x
        payload.appendInt32(55)        // Pixel.y
        payload.appendBytes([200, 100, 20, 0])   // ColorRef R,G,B,Reserved
        let rec = FixtureBuilder.record(type: 15, payload: payload.bytes)
        let decoded = try decodeSingle(rec)
        guard case .setPixel(let point, let color) = decoded else {
            Issue.record("expected .setPixel, got \(decoded)"); return
        }
        #expect(point.x == 40)
        #expect(point.y == 55)
        #expect(color.red == 200)
        #expect(color.green == 100)
        #expect(color.blue == 20)
    }

    @Test("SETPIXELV truncated below 20 bytes is .malformed")
    func setPixelVTruncated() throws {
        // 8 payload bytes — a PointL + ColorRef needs 12.
        let rec = FixtureBuilder.record(type: 15, payload: [0, 0, 0, 0, 0, 0, 0, 0])
        let decoded = try decodeSingle(rec)
        #expect(decoded.malformedReason != nil)
    }

    @Test("EXCLUDECLIPRECT golden: a Clip RectL")
    func excludeClipRectGolden() throws {
        let rect = RectL(left: 5, top: 6, right: 70, bottom: 80)
        let rec = FixtureBuilder.record(type: 29, payload: FixtureBuilder.rectBytes(rect))
        let decoded = try decodeSingle(rec)
        guard case .excludeClipRect(let clip) = decoded else {
            Issue.record("expected .excludeClipRect, got \(decoded)"); return
        }
        #expect(clip == rect)
    }

    @Test("EXCLUDECLIPRECT truncated below 24 bytes is .malformed")
    func excludeClipRectTruncated() throws {
        let rec = FixtureBuilder.record(type: 29, payload: [0, 0, 0, 0, 0, 0, 0, 0])
        let decoded = try decodeSingle(rec)
        #expect(decoded.malformedReason != nil)
    }
}
