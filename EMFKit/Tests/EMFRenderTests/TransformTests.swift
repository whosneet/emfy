import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

@Suite("Coordinate pipeline")
struct TransformTests {

    /// A neutral header: metrics only matter for the fixed metric modes.
    private static func header(
        device: SizeL = SizeL(cx: 1000, cy: 1000),
        millimeters: SizeL = SizeL(cx: 250, cy: 250)
    ) -> EMFHeader {
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
            device: device,
            millimeters: millimeters,
            extension1: nil,
            extension2: nil,
            description: nil,
            variant: .extension2
        )
    }

    private static func makeDC() -> DeviceContext {
        DeviceContext(header: header())
    }

    private static func apply(_ payloads: [EMFRecordPayload], to dc: inout DeviceContext, log: inout EMFRenderLog) {
        for payload in payloads {
            _ = dc.apply(payload, log: &log)
        }
    }

    // MARK: - Map modes

    @Test("MM_TEXT default is the identity mapping")
    func mmTextIdentity() {
        let dc = Self.makeDC()
        #expect(dc.resolvedTransform == .identity)
    }

    @Test("MM_TEXT honours origins but ignores extents")
    func mmTextOriginsOnly() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            // Extents in MM_TEXT are GDI no-ops; these must change nothing.
            .setWindowExtEx(extent: SizeL(cx: 500, cy: 500)),
            .setViewportExtEx(extent: SizeL(cx: 50, cy: 50)),
            .setWindowOrgEx(origin: PointL(x: 10, y: 20)),
            .setViewportOrgEx(origin: PointL(x: -3, y: 4)),
        ], to: &dc, log: &log)

        let mapped = CGPoint(x: 100, y: 100).applying(dc.resolvedTransform)
        // device = (page − windowOrg) × 1 + viewportOrg
        #expect(mapped == CGPoint(x: 100 - 10 - 3, y: 100 - 20 + 4))
        #expect(log.isClean)
    }

    @Test("MM_ANISOTROPIC maps a known org/ext quadruple exactly")
    func anisotropicExactMapping() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setMapMode(.anisotropic),
            .setWindowOrgEx(origin: PointL(x: 10, y: 20)),
            .setWindowExtEx(extent: SizeL(cx: 100, cy: 200)),
            .setViewportOrgEx(origin: PointL(x: 5, y: -7)),
            .setViewportExtEx(extent: SizeL(cx: 50, cy: 400)),
        ], to: &dc, log: &log)

        // sx = 50/100 = 0.5, sy = 400/200 = 2:
        // x' = (110 − 10) × 0.5 + 5 = 55; y' = (120 − 20) × 2 − 7 = 193.
        let mapped = CGPoint(x: 110, y: 120).applying(dc.resolvedTransform)
        #expect(mapped == CGPoint(x: 55, y: 193))
        #expect(log.isClean)
    }

    @Test("MM_ISOTROPIC shrinks the larger extent scale, preserving signs")
    func isotropicAdjustment() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setMapMode(.isotropic),
            .setWindowExtEx(extent: SizeL(cx: 100, cy: 100)),
            // Raw scales: sx = 2, sy = −3 → |sy| shrinks to 2, sign kept.
            .setViewportExtEx(extent: SizeL(cx: 200, cy: -300)),
        ], to: &dc, log: &log)

        let mapped = CGPoint(x: 10, y: 10).applying(dc.resolvedTransform)
        #expect(mapped == CGPoint(x: 20, y: -20))
        #expect(log.isClean)
    }

    @Test("fixed metric modes scale from header metrics with y negated")
    func metricModeScale() {
        // 1000 px / 250 mm = 4 px per mm; MM_LOMETRIC unit = 0.1 mm →
        // 0.4 px per unit, y-up (negated).
        let scale = CoordinatePipeline.pageToDeviceScale(
            mapMode: .loMetric,
            windowExt: SizeL(cx: 1, cy: 1),
            viewportExt: SizeL(cx: 1, cy: 1),
            header: Self.header()
        )
        #expect(scale == CoordinatePipeline.Scale(sx: 0.4, sy: -0.4))
    }

    @Test("fixed metric modes fall back to 96 DPI on zero header metrics")
    func metricModeFallback() throws {
        let scale = try #require(CoordinatePipeline.pageToDeviceScale(
            mapMode: .hiMetric,
            windowExt: SizeL(cx: 1, cy: 1),
            viewportExt: SizeL(cx: 1, cy: 1),
            header: Self.header(millimeters: SizeL(cx: 0, cy: 0))
        ))
        // 96/25.4 px per mm × 0.01 mm per unit.
        let expected = 96.0 / 25.4 * 0.01
        #expect(abs(scale.sx - expected) < 1e-12)
        #expect(abs(scale.sy + expected) < 1e-12)
    }

    // MARK: - Zero extents

    @Test("zero window extent keeps the previous mapping and logs")
    func zeroWindowExtent() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setMapMode(.anisotropic),
            .setWindowExtEx(extent: SizeL(cx: 100, cy: 100)),
            .setViewportExtEx(extent: SizeL(cx: 200, cy: 200)),
        ], to: &dc, log: &log)
        let before = dc.resolvedTransform

        Self.apply([.setWindowExtEx(extent: SizeL(cx: 0, cy: 5))], to: &dc, log: &log)

        #expect(dc.resolvedTransform == before)
        #expect(log.entries == [.zeroExtentMapping])
    }

    @Test("zero viewport extent keeps the previous mapping and logs")
    func zeroViewportExtent() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setMapMode(.anisotropic),
            .setWindowExtEx(extent: SizeL(cx: 100, cy: 100)),
            .setViewportExtEx(extent: SizeL(cx: 200, cy: 200)),
        ], to: &dc, log: &log)
        let before = dc.resolvedTransform

        Self.apply([.setViewportExtEx(extent: SizeL(cx: 300, cy: 0))], to: &dc, log: &log)

        #expect(dc.resolvedTransform == before)
        #expect(log.entries == [.zeroExtentMapping])
    }

    // MARK: - World transform

    @Test("MWT_LEFTMULTIPLY applies the record transform first")
    func leftMultiplyOrder() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setWorldTransform(XForm(m11: 2, m12: 0, m21: 0, m22: 2, dx: 0, dy: 0)),
            .modifyWorldTransform(ModifyWorldTransformPayload(
                transform: XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 10, dy: 0),
                mode: .leftMultiply
            )),
        ], to: &dc, log: &log)

        // record × current = T(10,0) × S(2): translate FIRST, then scale —
        // (1,1) → (11,1) → (22,2). The translation is scaled.
        #expect(dc.state.world == CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 20, ty: 0))
        #expect(CGPoint(x: 1, y: 1).applying(dc.resolvedTransform) == CGPoint(x: 22, y: 2))
        #expect(log.isClean)
    }

    @Test("MWT_RIGHTMULTIPLY applies the record transform last")
    func rightMultiplyOrder() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setWorldTransform(XForm(m11: 2, m12: 0, m21: 0, m22: 2, dx: 0, dy: 0)),
            .modifyWorldTransform(ModifyWorldTransformPayload(
                transform: XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 10, dy: 0),
                mode: .rightMultiply
            )),
        ], to: &dc, log: &log)

        // current × record = S(2) × T(10,0): scale FIRST, then translate —
        // (1,1) → (2,2) → (12,2). The translation is NOT scaled: the two
        // multiply orders provably differ.
        #expect(dc.state.world == CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: 0))
        #expect(CGPoint(x: 1, y: 1).applying(dc.resolvedTransform) == CGPoint(x: 12, y: 2))
        #expect(log.isClean)
    }

    @Test("MWT_IDENTITY resets; MWT_SET replaces; unknown mode logs")
    func identitySetAndUnknownModes() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        let xform = XForm(m11: 3, m12: 0, m21: 0, m22: 3, dx: 1, dy: 2)

        Self.apply([
            .setWorldTransform(XForm(m11: 2, m12: 0, m21: 0, m22: 2, dx: 5, dy: 5)),
            .modifyWorldTransform(ModifyWorldTransformPayload(transform: xform, mode: .identity)),
        ], to: &dc, log: &log)
        #expect(dc.state.world == .identity)

        Self.apply([
            .modifyWorldTransform(ModifyWorldTransformPayload(transform: xform, mode: .set)),
        ], to: &dc, log: &log)
        #expect(dc.state.world == CGAffineTransform(a: 3, b: 0, c: 0, d: 3, tx: 1, ty: 2))

        Self.apply([
            .modifyWorldTransform(ModifyWorldTransformPayload(transform: xform, mode: .unknown(9))),
        ], to: &dc, log: &log)
        #expect(dc.state.world == CGAffineTransform(a: 3, b: 0, c: 0, d: 3, tx: 1, ty: 2))
        #expect(log.entries == [.unsupportedWorldTransformMode(rawMode: 9)])
    }

    @Test("world transform composes before the page→device mapping")
    func worldThenPageToDevice() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        Self.apply([
            .setMapMode(.anisotropic),
            .setWindowExtEx(extent: SizeL(cx: 100, cy: 100)),
            .setViewportExtEx(extent: SizeL(cx: 200, cy: 200)),   // page→device ×2
            .setWorldTransform(XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 7, dy: 0)),
        ], to: &dc, log: &log)

        // World first: (1,1) → (8,1); then ×2 → (16,2). If the order were
        // reversed the x would be 1×2 + 7 = 9.
        #expect(CGPoint(x: 1, y: 1).applying(dc.resolvedTransform) == CGPoint(x: 16, y: 2))
        #expect(log.isClean)
    }
}
