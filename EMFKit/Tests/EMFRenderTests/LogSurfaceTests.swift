import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// The phase-3 render-log redesign: coalesced unsupported-ROP2 counts and the
/// previously-silent unknown-enum fallbacks (phase-2 backlog).
@Suite("Render log surface")
struct LogSurfaceTests {

    private static func dc() -> DeviceContext {
        DeviceContext(header: RenderFixtureHeader.make())
    }

    @Test("unsupported ROP2 modes coalesce by mode with a count")
    func rop2Coalesces() {
        var dc = Self.dc()
        var log = EMFRenderLog()

        for _ in 0 ..< 5 { _ = dc.apply(.setROP2(rawMode: 0x06), log: &log) }   // R2_XORPEN ×5
        for _ in 0 ..< 3 { _ = dc.apply(.setROP2(rawMode: 0x07), log: &log) }   // R2_ANDPEN ×3
        _ = dc.apply(.setROP2(rawMode: 0x0D), log: &log)                        // R2_COPYPEN (silent)

        #expect(log.entries == [
            .unsupportedROP2(rawMode: 0x06, count: 5),
            .unsupportedROP2(rawMode: 0x07, count: 3),
        ])
    }

    @Test("ROP2 coalescing survives makeImage's log re-feed")
    func rop2CoalescesThroughMakeImage() throws {
        var fixture = RenderFixture()
        // A hostile canvas forces a leading canvasClamped entry, exercising the
        // re-feed path in makeImage that could otherwise split the count.
        fixture.bounds = (left: 0, top: 0, right: 999_999_999, bottom: 99)
        for _ in 0 ..< 4 { fixture.setROP2(0x06) }
        let file = try fixture.parsed()
        let (_, log) = try #require(EMFRenderer.makeImage(file))
        #expect(log.entries.contains(.unsupportedROP2(rawMode: 0x06, count: 4)),
                "the four SETROP2s coalesce into one counted entry despite the clamp entry")
    }

    @Test("unknown SETMAPMODE falls back and logs")
    func unknownMapMode() {
        var dc = Self.dc()
        var log = EMFRenderLog()
        _ = dc.apply(.setMapMode(MapMode(0x99)), log: &log)
        #expect(log.entries == [.unknownEnumValue(record: 17, rawValue: 0x99)])
    }

    @Test("unknown SETPOLYFILLMODE keeps the current mode and logs")
    func unknownPolyFillMode() {
        var dc = Self.dc()
        var log = EMFRenderLog()
        let before = dc.state.polyFillMode
        _ = dc.apply(.setPolyFillMode(PolygonFillMode(0x40)), log: &log)
        #expect(dc.state.polyFillMode == before, "unknown value must not change the mode")
        #expect(log.entries == [.unknownEnumValue(record: 19, rawValue: 0x40)])
    }

    @Test("unknown SETBKMODE keeps the current mode and logs")
    func unknownBkMode() {
        var dc = Self.dc()
        var log = EMFRenderLog()
        let before = dc.state.bkMode
        _ = dc.apply(.setBkMode(BackgroundMode(0x77)), log: &log)
        #expect(dc.state.bkMode == before)
        #expect(log.entries == [.unknownEnumValue(record: 18, rawValue: 0x77)])
    }

    @Test("defined enum values do not log")
    func definedEnumsSilent() {
        var dc = Self.dc()
        var log = EMFRenderLog()
        _ = dc.apply(.setMapMode(.anisotropic), log: &log)
        _ = dc.apply(.setPolyFillMode(.winding), log: &log)
        _ = dc.apply(.setBkMode(.transparent), log: &log)
        #expect(log.isClean)
    }

    // MARK: - Bounded growth (anti-hang, R1)

    @Test("distinct keys then repeats of an existing key give correct counts")
    func distinctThenRepeatCounts() {
        var log = EMFRenderLog()
        // N distinct rop values, first-occurrence order preserved.
        let n = 100
        for value in 0 ..< n { log.noteUnsupportedRasterOp(rasterOperation: UInt32(value)) }
        #expect(log.entries.count == n)
        // M more of an already-present key (0) bump only that entry's count.
        let m = 50
        for _ in 0 ..< m { log.noteUnsupportedRasterOp(rasterOperation: 0) }
        #expect(log.entries.count == n, "repeats never add entries")
        #expect(log.entries.first == .unsupportedRasterOp(rasterOperation: 0, count: 1 + m))
        #expect(log.entries.last == .unsupportedRasterOp(rasterOperation: UInt32(n - 1), count: 1))
    }

    @Test("a flood of distinct coalescing keys is capped and does not hang")
    func distinctKeysAreCappedFast() {
        let clock = ContinuousClock()
        var log = EMFRenderLog()
        let elapsed = clock.measure {
            // Far more distinct keys than the cap; with the O(1) index map this
            // is linear, not quadratic. Pre-map this was ~2e8 comparisons.
            for value in 0 ..< 20_000 { log.noteUnsupportedRasterOp(rasterOperation: UInt32(value)) }
        }
        #expect(log.entries.count == EMFRenderLog.maxDistinctEntries,
                "distinct entries are hard-capped")
        // Counts on already-present keys must still increment past the cap.
        log.noteUnsupportedRasterOp(rasterOperation: 0)
        #expect(log.entries.first == .unsupportedRasterOp(rasterOperation: 0, count: 2))
        // Wall-clock sanity: linear work over 20k inserts is milliseconds.
        #expect(elapsed < .seconds(1), "must not hang: \(elapsed)")
    }

    @Test("distinct unsupported-DIB reasons stay separate; repeats coalesce")
    func dibReasonsCoalesceByReason() {
        var log = EMFRenderLog()
        log.noteUnsupportedDIB(reason: .bitCount(1))
        log.noteUnsupportedDIB(reason: .bitCount(4))
        log.noteUnsupportedDIB(reason: nil)          // render-declined
        log.noteUnsupportedDIB(reason: .bitCount(1)) // repeat of the first
        #expect(log.entries == [
            .unsupportedDIB(reason: .bitCount(1), count: 2),
            .unsupportedDIB(reason: .bitCount(4), count: 1),
            .unsupportedDIB(reason: nil, count: 1),
        ])
    }
}
