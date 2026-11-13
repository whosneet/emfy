import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for the 32-bit poly-poly records EMR_POLYPOLYLINE (7) and
/// EMR_POLYPOLYGON (8) ([MS-EMF] §2.3.5.30 / §2.3.5.28): a golden decode, the
/// per-poly-count-sum invariant, a truncated variant, and a lying count that
/// overruns the record (both `.malformed`, never a crash — primer §8).
@Suite("32-bit poly-poly record decode")
struct PayloadPolyPoly32Tests {

    private static let bounds = RectL(left: 0, top: 0, right: 200, bottom: 100)

    /// Builds a record body: Bounds, NumberOfPolys, total Count, the u32 count
    /// array, then the PointL values. `countsOverride`/`totalOverride` let a
    /// test write an inconsistent header.
    private static func record(
        type: UInt32,
        polygons: [[PointL]],
        totalOverride: UInt32? = nil
    ) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendInt32(bounds.left); b.appendInt32(bounds.top)
        b.appendInt32(bounds.right); b.appendInt32(bounds.bottom)
        let all = polygons.flatMap { $0 }
        b.appendUInt32(UInt32(polygons.count))
        b.appendUInt32(totalOverride ?? UInt32(all.count))
        for polygon in polygons { b.appendUInt32(UInt32(polygon.count)) }
        for p in all { b.appendInt32(p.x); b.appendInt32(p.y) }
        return FixtureBuilder.record(type: type, payload: b.bytes)
    }

    @Test("golden: two sub-polys decode with the shared 32-bit payload",
          arguments: [UInt32(7), 8])
    func golden(type: UInt32) throws {
        let polygons = [
            [PointL(x: 0, y: 0), PointL(x: 50, y: 0), PointL(x: 50, y: 50)],
            [PointL(x: 100, y: 10), PointL(x: 200, y: 10)],
        ]
        let payload = try decodeSingle(Self.record(type: type, polygons: polygons))
        #expect(payloadCaseMatches(type: type, payload: payload))
        let pp = try #require(payload.polyPoly32)
        #expect(pp.bounds == Self.bounds)
        #expect(pp.pointCounts == [3, 2])
        #expect(pp.points.count == 5)
        #expect(pp.points.first == PointL(x: 0, y: 0))
        #expect(pp.points.last == PointL(x: 200, y: 10))
    }

    @Test("a total Count that disagrees with the per-poly sum is malformed")
    func countMismatch() throws {
        // Two polys summing to 5, but the record claims a total of 4.
        let polygons = [
            [PointL(x: 0, y: 0), PointL(x: 1, y: 1), PointL(x: 2, y: 2)],
            [PointL(x: 3, y: 3), PointL(x: 4, y: 4)],
        ]
        let payload = try decodeSingle(Self.record(type: 8, polygons: polygons, totalOverride: 4))
        #expect(payload.malformedReason == .countMismatch(declaredTotal: 4, sumOfCounts: 5))
    }

    @Test("a total Count that cannot fit in nSize is rejected before allocating")
    func countTooLarge() throws {
        // NumberOfPolys 1, count [1], but total claims 100000 points.
        var b = FixtureBuilder()
        b.appendInt32(0); b.appendInt32(0); b.appendInt32(10); b.appendInt32(10)
        b.appendUInt32(1)           // NumberOfPolys
        b.appendUInt32(100_000)     // total Count — absurd
        b.appendUInt32(100_000)     // the single poly count
        b.appendInt32(1); b.appendInt32(1)   // one real point
        let payload = try decodeSingle(FixtureBuilder.record(type: 7, payload: b.bytes))
        #expect(payload.malformedReason != nil)
    }

    @Test("truncated record (no NumberOfPolys/Count) is malformed, not a crash")
    func truncated() throws {
        // Bounds only (16 payload bytes → 24-byte record).
        var b = FixtureBuilder()
        b.appendInt32(0); b.appendInt32(0); b.appendInt32(10); b.appendInt32(10)
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 8, payload: b.bytes))
        #expect(file.diagnostics.isEmpty)
        #expect(file.payload(of: record)
            == .malformed(type: 8, reason: .tooSmall(minimumSize: 32, actualSize: 24)))
    }

    @Test("a lying nSize that overruns the buffer stops the walk safely")
    func lyingSize() throws {
        var fixture = FixtureBuilder()
        fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
        var b = FixtureBuilder()
        b.appendInt32(0); b.appendInt32(0); b.appendInt32(10); b.appendInt32(10)
        b.appendUInt32(1); b.appendUInt32(1); b.appendUInt32(1)
        b.appendInt32(5); b.appendInt32(5)
        fixture.appendBytes(FixtureBuilder.record(type: 7, payload: b.bytes, sizeOverride: 4000))
        fixture.appendBytes(FixtureBuilder.eof())
        let file = try EMFFile.parse(fixture.data)
        #expect(file.records.count == 1)   // only the header walked
        #expect(file.diagnostics.contains { if case .sizeExceedsRemaining = $0 { return true }; return false })
    }
}
