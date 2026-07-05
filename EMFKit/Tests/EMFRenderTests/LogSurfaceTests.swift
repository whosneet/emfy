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
}
