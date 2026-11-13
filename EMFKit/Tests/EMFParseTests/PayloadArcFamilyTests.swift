import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for the R1 arc-family records: EMR_CHORD (46), EMR_PIE (47)
/// and EMR_ARCTO (55) — all sharing EMR_ARC's 40-byte Box/Start/End layout
/// ([MS-EMF] §2.3.5.3/.4/.6) — plus the EMR_SETARCDIRECTION (57) state record
/// (§2.3.11.1). Each has a golden decode, a truncated variant (walk-valid but
/// too short → `.malformed`), and a lying-`nSize` variant (the walker
/// bounds-check stops and keeps what parsed, never crashing — primer §8).
@Suite("Arc-family record payload decode")
struct PayloadArcFamilyTests {

    private static let box = RectL(left: 10, top: 20, right: 110, bottom: 120)
    private static let start = PointL(x: 90, y: 25)
    private static let end = PointL(x: 15, y: 115)

    /// The 32-byte Box/Start/End body shared by ARC, ARCTO, CHORD, PIE.
    private static func arcBody() -> [UInt8] {
        var b = FixtureBuilder()
        b.appendBytes(FixtureBuilder.rectBytes(box))
        b.appendInt32(start.x); b.appendInt32(start.y)
        b.appendInt32(end.x); b.appendInt32(end.y)
        return b.bytes
    }

    private static let expectedArc = ArcPayload(box: box, start: start, end: end)

    // MARK: - Golden decodes

    @Test("CHORD, PIE, ARCTO share ARC's layout and decode to their own case")
    func arcLikeGolden() throws {
        let body = Self.arcBody()
        #expect(try decodeSingle(FixtureBuilder.record(type: 46, payload: body)) == .chord(Self.expectedArc))
        #expect(try decodeSingle(FixtureBuilder.record(type: 47, payload: body)) == .pie(Self.expectedArc))
        #expect(try decodeSingle(FixtureBuilder.record(type: 55, payload: body)) == .arcTo(Self.expectedArc))
    }

    @Test("SETARCDIRECTION decodes both defined directions and an unknown value")
    func setArcDirectionGolden() throws {
        func record(_ raw: UInt32) -> [UInt8] {
            var b = FixtureBuilder(); b.appendUInt32(raw)
            return FixtureBuilder.record(type: 57, payload: b.bytes)
        }
        #expect(try decodeSingle(record(1)) == .setArcDirection(.counterclockwise))
        #expect(try decodeSingle(record(2)) == .setArcDirection(.clockwise))
        #expect(try decodeSingle(record(99)) == .setArcDirection(.unknown(99)))
    }

    // MARK: - Truncated (walk-valid, body too short → malformed)

    @Test("truncated arc-like record is a malformed verdict, not a crash",
          arguments: [UInt32(46), 47, 55])
    func arcLikeTruncated(type: UInt32) throws {
        // Box only (16 payload bytes → 24-byte record): Start/End are missing.
        let short = Array(Self.arcBody().prefix(16))
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: type, payload: short))
        #expect(file.diagnostics.isEmpty)   // walk-valid: nSize matches the bytes
        #expect(file.payload(of: record)
            == .malformed(type: type, reason: .tooSmall(minimumSize: 40, actualSize: 24)))
    }

    @Test("truncated SETARCDIRECTION (no mode field) is malformed")
    func setArcDirectionTruncated() throws {
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 57, payload: []))
        #expect(file.payload(of: record)
            == .malformed(type: 57, reason: .tooSmall(minimumSize: 12, actualSize: 8)))
    }

    // MARK: - Lying nSize (claims more than the buffer holds → walk stops)

    @Test("an arc-like record whose nSize overruns the buffer stops the walk safely")
    func arcLikeLyingSize() throws {
        // Header + an EMR_PIE claiming nSize 400 while only its 40 real bytes
        // (plus the EOF) follow: the walker's bounds check (§8) must stop and
        // keep the header, never read past the buffer.
        var fixture = FixtureBuilder()
        fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
        fixture.appendBytes(FixtureBuilder.record(type: 47, payload: Self.arcBody(), sizeOverride: 400))
        fixture.appendBytes(FixtureBuilder.eof())
        let file = try EMFFile.parse(fixture.data)
        // Only the header walked; the oversized record was refused.
        #expect(file.records.count == 1)
        #expect(file.diagnostics.contains { if case .sizeExceedsRemaining = $0 { return true }; return false })
    }
}
