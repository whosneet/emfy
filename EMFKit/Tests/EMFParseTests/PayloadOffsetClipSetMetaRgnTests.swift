import Foundation
import Testing
@testable import EMFParse

/// EMR_OFFSETCLIPRGN (26, [MS-EMF] §2.3.2.4) and EMR_SETMETARGN (28, §2.3.2.6)
/// byte-fixture decode.
@Suite("OFFSETCLIPRGN and SETMETARGN payload decode")
struct PayloadOffsetClipSetMetaRgnTests {

    @Test("OFFSETCLIPRGN golden: a PointL offset")
    func offsetClipGolden() throws {
        var payload = FixtureBuilder()
        payload.appendInt32(30)
        payload.appendInt32(-12)
        let rec = FixtureBuilder.record(type: 26, payload: payload.bytes)
        let decoded = try decodeSingle(rec)
        guard case .offsetClipRgn(let offset) = decoded else {
            Issue.record("expected .offsetClipRgn, got \(decoded)"); return
        }
        #expect(offset.x == 30)
        #expect(offset.y == -12)
    }

    @Test("OFFSETCLIPRGN truncated below 16 bytes is .malformed")
    func offsetClipTruncated() throws {
        let rec = FixtureBuilder.record(type: 26, payload: [0, 0, 0, 0])
        let decoded = try decodeSingle(rec)
        #expect(decoded.malformedReason != nil)
    }

    @Test("SETMETARGN golden: a no-parameter record")
    func setMetaRgnGolden() throws {
        let rec = FixtureBuilder.record(type: 28, size: 8)
        let decoded = try decodeSingle(rec)
        guard case .setMetaRgn = decoded else {
            Issue.record("expected .setMetaRgn, got \(decoded)"); return
        }
    }
}
