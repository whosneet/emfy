import Foundation
import Testing
@testable import EMFParse

@Suite("Geometry record payload decode")
struct PayloadGeometryTests {

    /// Bounds used by all poly fixtures.
    private static let bounds = RectL(left: -100, top: -400, right: 300, bottom: 200)

    private static func appendBounds(_ b: inout FixtureBuilder) {
        b.appendInt32(bounds.left)
        b.appendInt32(bounds.top)
        b.appendInt32(bounds.right)
        b.appendInt32(bounds.bottom)
    }

    private static func poly32Record(type: UInt32, points: [PointL]) -> [UInt8] {
        var b = FixtureBuilder()
        appendBounds(&b)
        b.appendUInt32(UInt32(points.count))
        for p in points {
            b.appendInt32(p.x)
            b.appendInt32(p.y)
        }
        return FixtureBuilder.record(type: type, payload: b.bytes)
    }

    private static func poly16Record(type: UInt32, points: [PointS]) -> [UInt8] {
        var b = FixtureBuilder()
        appendBounds(&b)
        b.appendUInt32(UInt32(points.count))
        for p in points {
            b.appendInt16(p.x)
            b.appendInt16(p.y)
        }
        return FixtureBuilder.record(type: type, payload: b.bytes)
    }

    // MARK: - Golden decodes

    @Test("32-bit poly family golden", arguments: [UInt32(2), 3, 4, 5, 6])
    func poly32Golden(type: UInt32) throws {
        let points = [
            PointL(x: -100, y: 200),
            PointL(x: 300, y: -400),
            PointL(x: 0, y: 7),
        ]
        let record = Self.poly32Record(type: type, points: points)
        // PointL is 8 bytes: record = 8 header + 16 bounds + 4 count + 24.
        #expect(record.count == 28 + points.count * 8)

        let payload = try decodeSingle(record)
        #expect(payloadCaseMatches(type: type, payload: payload))
        let poly = try #require(payload.poly32)
        #expect(poly.bounds == Self.bounds)
        #expect(poly.points == points)
    }

    @Test("16-bit poly family golden", arguments: [UInt32(85), 86, 87, 88, 89])
    func poly16Golden(type: UInt32) throws {
        let points = [
            PointS(x: -100, y: 200),
            PointS(x: 32767, y: -32768),   // Int16 extremes
            PointS(x: 0, y: 7),
        ]
        let record = Self.poly16Record(type: type, points: points)
        // PointS is 4 bytes: record = 28 + 12 — half the point bytes of the
        // 32-bit layout. The explicit width check.
        #expect(record.count == 28 + points.count * 4)

        let payload = try decodeSingle(record)
        #expect(payloadCaseMatches(type: type, payload: payload))
        let poly = try #require(payload.poly16)
        #expect(poly.bounds == Self.bounds)
        #expect(poly.points == points)
    }

    @Test("16-bit vs 32-bit point width, same coordinates")
    func pointWidthExplicit() throws {
        // Identical coordinate list, both representable in Int16.
        let wide = Self.poly32Record(type: 4, points: [PointL(x: -5, y: 6), PointL(x: 7, y: -8)])
        let narrow = Self.poly16Record(type: 87, points: [PointS(x: -5, y: 6), PointS(x: 7, y: -8)])
        #expect(wide.count == 28 + 16)
        #expect(narrow.count == 28 + 8)

        let widePoints = try #require(try decodeSingle(wide).poly32).points
        let narrowPoints = try #require(try decodeSingle(narrow).poly16).points
        #expect(widePoints == [PointL(x: -5, y: 6), PointL(x: 7, y: -8)])
        #expect(narrowPoints == [PointS(x: -5, y: 6), PointS(x: 7, y: -8)])
        // Same coordinates decode from both widths.
        #expect(narrowPoints.map { PointL(x: Int32($0.x), y: Int32($0.y)) } == widePoints)
    }

    // MARK: - Lying counts (every array-carrying record)

    @Test(
        "lying point count: countTooLarge, walk unaffected",
        arguments: [
            (UInt32(2), false), (UInt32(3), false), (UInt32(4), false),
            (UInt32(5), false), (UInt32(6), false),
            (UInt32(85), true), (UInt32(86), true), (UInt32(87), true),
            (UInt32(88), true), (UInt32(89), true),
        ]
    )
    func lyingPointCount(type: UInt32, is16Bit: Bool) throws {
        // Two real points, but Count claims 1000.
        var b = FixtureBuilder()
        Self.appendBounds(&b)
        b.appendUInt32(1000)
        if is16Bit {
            b.appendInt16(1); b.appendInt16(2)
            b.appendInt16(3); b.appendInt16(4)
        } else {
            b.appendInt32(1); b.appendInt32(2)
            b.appendInt32(3); b.appendInt32(4)
        }
        let record = FixtureBuilder.record(type: type, payload: b.bytes)

        let (file, raw) = try parseWithSingleRecord(record)
        #expect(file.diagnostics.isEmpty)      // record is walk-valid
        #expect(file.records.count == 3)       // earlier/later records intact
        #expect(file.payload(of: raw)
            == .malformed(type: type, reason: .countTooLarge(declared: 1000, maxFitting: 2)))
    }

    @Test(
        "polyPoly16 lying NumberOfPolys: countTooLarge",
        arguments: [UInt32(90), 91]
    )
    func polyPolyLyingPolyCount(type: UInt32) throws {
        var b = FixtureBuilder()
        Self.appendBounds(&b)
        b.appendUInt32(1000)                    // NumberOfPolys: LIES
        b.appendUInt32(0)                       // Count
        b.appendUInt32(2)                       // 8 bytes of "counts array"
        b.appendUInt32(2)
        let record = FixtureBuilder.record(type: type, payload: b.bytes)
        #expect(try decodeSingle(record)
            == .malformed(type: type, reason: .countTooLarge(declared: 1000, maxFitting: 2)))
    }

    // MARK: - PolyPoly16

    private static func polyPoly16Record(
        type: UInt32,
        counts: [UInt32],
        declaredTotal: UInt32,
        points: [PointS]
    ) -> [UInt8] {
        var b = FixtureBuilder()
        appendBounds(&b)
        b.appendUInt32(UInt32(counts.count))
        b.appendUInt32(declaredTotal)
        for c in counts { b.appendUInt32(c) }
        for p in points {
            b.appendInt16(p.x)
            b.appendInt16(p.y)
        }
        return FixtureBuilder.record(type: type, payload: b.bytes)
    }

    @Test("polyPoly16 golden: 2 sub-polygons", arguments: [UInt32(90), 91])
    func polyPoly16Golden(type: UInt32) throws {
        let points = (1 ... 7).map { PointS(x: Int16($0), y: Int16(-$0)) }
        let record = Self.polyPoly16Record(
            type: type,
            counts: [3, 4],
            declaredTotal: 7,
            points: points
        )
        // 8 header + 16 bounds + 4 + 4 + 8 counts + 28 points = 68.
        #expect(record.count == 68)

        let payload = try decodeSingle(record)
        #expect(payloadCaseMatches(type: type, payload: payload))
        let poly = try #require(payload.polyPoly16)
        #expect(poly.bounds == Self.bounds)
        #expect(poly.pointCounts == [3, 4])
        #expect(poly.points == points)
    }

    @Test("polyPoly16 counts not summing to Count: countMismatch")
    func polyPoly16CountMismatch() throws {
        // 8 points present and declared, but the per-polygon counts sum to 7.
        let points = (1 ... 8).map { PointS(x: Int16($0), y: Int16($0)) }
        let record = Self.polyPoly16Record(
            type: 91,
            counts: [3, 4],
            declaredTotal: 8,
            points: points
        )
        #expect(try decodeSingle(record)
            == .malformed(type: 91, reason: .countMismatch(declaredTotal: 8, sumOfCounts: 7)))
    }

    // MARK: - Fixed-shape geometry

    @Test("moveToEx and lineTo golden")
    func currentPositionRecords() throws {
        var move = FixtureBuilder()
        move.appendInt32(-5)
        move.appendInt32(9)
        #expect(try decodeSingle(FixtureBuilder.record(type: 27, payload: move.bytes))
            == .moveToEx(point: PointL(x: -5, y: 9)))

        var line = FixtureBuilder()
        line.appendInt32(55)
        line.appendInt32(-66)
        #expect(try decodeSingle(FixtureBuilder.record(type: 54, payload: line.bytes))
            == .lineTo(point: PointL(x: 55, y: -66)))
    }

    @Test("ellipse, rectangle, roundRect, arc golden")
    func boxRecords() throws {
        var box = FixtureBuilder()
        box.appendInt32(1)
        box.appendInt32(2)
        box.appendInt32(101)
        box.appendInt32(202)
        let rect = RectL(left: 1, top: 2, right: 101, bottom: 202)

        #expect(try decodeSingle(FixtureBuilder.record(type: 42, payload: box.bytes))
            == .ellipse(box: rect))
        #expect(try decodeSingle(FixtureBuilder.record(type: 43, payload: box.bytes))
            == .rectangle(box: rect))

        var round = FixtureBuilder()
        round.appendBytes(box.bytes)
        round.appendInt32(16)                   // Corner.cx
        round.appendInt32(12)                   // Corner.cy
        #expect(try decodeSingle(FixtureBuilder.record(type: 44, payload: round.bytes))
            == .roundRect(RoundRectPayload(box: rect, corner: SizeL(cx: 16, cy: 12))))

        var arc = FixtureBuilder()
        arc.appendBytes(box.bytes)
        arc.appendInt32(50)                     // Start
        arc.appendInt32(2)
        arc.appendInt32(1)                      // End
        arc.appendInt32(100)
        #expect(try decodeSingle(FixtureBuilder.record(type: 45, payload: arc.bytes))
            == .arc(ArcPayload(
                box: rect,
                start: PointL(x: 50, y: 2),
                end: PointL(x: 1, y: 100)
            )))
    }

    // MARK: - Unimplemented fallback

    @Test("types outside the phase-2 set are unimplemented, not errors")
    func unimplementedTypes() throws {
        // EMR_COMMENT (70) is not decoded in phase 2.
        let (file, record) = try parseWithSingleRecord(
            FixtureBuilder.record(type: 70, payload: [0, 0, 0, 0])
        )
        #expect(file.payload(of: record) == .unimplemented(type: 70))
        // The header record decodes via file.header, not payload(of:).
        #expect(file.payload(of: file.records[0]) == .unimplemented(type: 1))
        // EMR_EOF likewise.
        #expect(file.payload(of: file.records[2]) == .unimplemented(type: 14))
    }
}
