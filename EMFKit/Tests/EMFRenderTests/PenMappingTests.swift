import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

@Suite("Pen resolution and stroke mapping")
struct PenMappingTests {

    private static let black = ColorRef(red: 0, green: 0, blue: 0)

    private static func geometricStroke(
        width: Double,
        lineStyle: ResolvedLineStyle = .solid
    ) -> ResolvedStroke {
        ResolvedStroke(
            color: black, isCosmetic: false, width: width,
            lineStyle: lineStyle, cap: .round, join: .round
        )
    }

    private static let cosmeticStroke = ResolvedStroke(
        color: black, isCosmetic: true, width: 0,
        lineStyle: .solid, cap: .round, join: .round
    )

    // MARK: - Width scaling

    @Test("geometric width scales with the full logical→target transform")
    func geometricWidthScales() {
        let parameters = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 5),
            logicalToTarget: CGAffineTransform(scaleX: 2, y: 2),
            deviceToTarget: .identity
        )
        #expect(parameters.width == 10)
    }

    @Test("cosmetic pens are one device pixel regardless of the logical transform")
    func cosmeticWidthIgnoresLogicalTransform() {
        let parameters = StrokeMapper.deviceStroke(
            for: Self.cosmeticStroke,
            logicalToTarget: CGAffineTransform(scaleX: 8, y: 8),
            deviceToTarget: .identity
        )
        #expect(parameters.width == 1)

        // The canvas fit (device→target) DOES scale a cosmetic pen: a 2×
        // makeImage canvas doubles every device pixel.
        let scaled = StrokeMapper.deviceStroke(
            for: Self.cosmeticStroke,
            logicalToTarget: CGAffineTransform(scaleX: 8, y: 8),
            deviceToTarget: CGAffineTransform(scaleX: 2, y: 2)
        )
        #expect(scaled.width == 2)
    }

    @Test("anisotropic transforms use the average of the axis scales")
    func averageScaleApproximation() {
        let parameters = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 10),
            logicalToTarget: CGAffineTransform(scaleX: 1, y: 3),
            deviceToTarget: .identity
        )
        // (|1| + |3|) / 2 = 2 — the documented approximation.
        #expect(parameters.width == 20)
    }

    // MARK: - Dash patterns

    @Test("PS_DASH pattern is dash/gap multiples of the line width")
    func standardDashPattern() {
        let parameters = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 4, lineStyle: .dash),
            logicalToTarget: .identity,
            deviceToTarget: .identity
        )
        #expect(parameters.width == 4)
        #expect(parameters.dash == [12, 4])

        let dot = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 4, lineStyle: .dot),
            logicalToTarget: .identity,
            deviceToTarget: .identity
        )
        #expect(dot.dash == [4, 4])
    }

    @Test("dash multiples floor at one target unit for hairlines")
    func hairlineDashFloor() {
        let parameters = StrokeMapper.deviceStroke(
            for: Self.cosmeticStroke.withLineStyle(.dash),
            logicalToTarget: .identity,
            deviceToTarget: CGAffineTransform(scaleX: 0.25, y: 0.25)
        )
        // Width 0.25 target units; dash basis floors at 1 → [3, 1].
        #expect(parameters.width == 0.25)
        #expect(parameters.dash == [3, 1])
    }

    @Test("PS_USERSTYLE entries are absolute lengths in the pen's unit space")
    func userStyleDashes() {
        // Geometric: entries are logical units → scale by the full transform.
        let geometric = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 2, lineStyle: .userStyle([4, 2])),
            logicalToTarget: CGAffineTransform(scaleX: 2, y: 2),
            deviceToTarget: .identity
        )
        #expect(geometric.width == 4)
        #expect(geometric.dash == [8, 4])

        // Cosmetic: entries are device units → scale by the canvas fit only.
        let cosmetic = StrokeMapper.deviceStroke(
            for: Self.cosmeticStroke.withLineStyle(.userStyle([6, 3])),
            logicalToTarget: CGAffineTransform(scaleX: 10, y: 10),
            deviceToTarget: .identity
        )
        #expect(cosmetic.dash == [6, 3])

        // An all-zero user pattern degrades to solid.
        let zeros = StrokeMapper.deviceStroke(
            for: Self.geometricStroke(width: 2, lineStyle: .userStyle([0, 0])),
            logicalToTarget: .identity,
            deviceToTarget: .identity
        )
        #expect(zeros.dash.isEmpty)
    }

    // MARK: - Payload resolution

    @Test("CreatePen: PS_NULL, zero width, and style resolution")
    func createPenResolution() {
        var log = EMFRenderLog()

        let null = ObjectResolver.resolve(
            CreatePenPayload(ihPen: 1, style: 5, width: PointL(x: 7, y: 0), color: Self.black),
            log: &log
        )
        #expect(null == ResolvedPen.none)

        // Width 0 → one device pixel regardless of transform (wingdi
        // CreatePen contract).
        let hairline = ObjectResolver.resolve(
            CreatePenPayload(ihPen: 1, style: 0, width: PointL(x: 0, y: 0), color: Self.black),
            log: &log
        )
        guard case .stroke(let stroke) = hairline else {
            Issue.record("expected a stroking pen")
            return
        }
        #expect(stroke.isCosmetic)
        #expect(log.isClean)

        // PS_INSIDEFRAME is outside the supported set: logs, draws solid.
        let inside = ObjectResolver.resolve(
            CreatePenPayload(ihPen: 1, style: 6, width: PointL(x: 2, y: 0), color: Self.black),
            log: &log
        )
        guard case .stroke(let insideStroke) = inside else {
            Issue.record("expected a stroking pen")
            return
        }
        #expect(insideStroke.lineStyle == .solid)
        #expect(log.entries == [.unsupportedPenStyle(rawStyle: 6)])
    }

    @Test("ExtCreatePen: geometric bits, caps, joins, and user style")
    func extCreatePenResolution() {
        var log = EMFRenderLog()
        // PS_GEOMETRIC | PS_USERSTYLE | PS_ENDCAP_FLAT | PS_JOIN_BEVEL
        let style: UInt32 = 0x0001_0000 | 0x07 | 0x200 | 0x1000
        let payload = ExtCreatePenPayload(
            ihPen: 1, offBmi: 0, cbBmi: 0, offBits: 0, cbBits: 0,
            style: style, width: 4,
            brushStyle: 0,          // BS_SOLID
            color: Self.black, brushHatch: 0,
            styleEntries: [9, 3]
        )
        let pen = ObjectResolver.resolve(payload, log: &log)
        #expect(pen == .stroke(ResolvedStroke(
            color: Self.black, isCosmetic: false, width: 4,
            lineStyle: .userStyle([9, 3]), cap: .butt, join: .bevel
        )))
        #expect(log.isClean)

        // A cosmetic ExtCreatePen ignores its width field (spec: MUST be 1
        // device unit).
        let cosmetic = ObjectResolver.resolve(
            ExtCreatePenPayload(
                ihPen: 1, offBmi: 0, cbBmi: 0, offBits: 0, cbBits: 0,
                style: 0, width: 44, brushStyle: 0,
                color: Self.black, brushHatch: 0, styleEntries: []
            ),
            log: &log
        )
        guard case .stroke(let stroke) = cosmetic else {
            Issue.record("expected a stroking pen")
            return
        }
        #expect(stroke.isCosmetic)

        // A hatched pen brush logs and falls back to the solid colour.
        _ = ObjectResolver.resolve(
            ExtCreatePenPayload(
                ihPen: 1, offBmi: 0, cbBmi: 0, offBits: 0, cbBits: 0,
                style: 0x0001_0000, width: 2, brushStyle: 2,   // BS_HATCHED
                color: Self.black, brushHatch: 0, styleEntries: []
            ),
            log: &log
        )
        #expect(log.entries == [.unsupportedBrushStyle(rawStyle: 2)])
    }

    @Test("brush resolution: solid, null, and the logged fallback")
    func brushResolution() {
        var log = EMFRenderLog()
        let red = ColorRef(red: 255, green: 0, blue: 0)

        #expect(ObjectResolver.resolve(
            CreateBrushPayload(ihBrush: 1, style: 0, color: red, hatch: 0), log: &log
        ) == .solid(red))
        #expect(ObjectResolver.resolve(
            CreateBrushPayload(ihBrush: 1, style: 1, color: red, hatch: 0), log: &log
        ) == ResolvedBrush.none)
        #expect(log.isClean)

        // BS_HATCHED: logged, solid fallback from the payload colour.
        #expect(ObjectResolver.resolve(
            CreateBrushPayload(ihBrush: 1, style: 2, color: red, hatch: 4), log: &log
        ) == .solid(red))
        #expect(log.entries == [.unsupportedBrushStyle(rawStyle: 2)])
    }
}

extension ResolvedStroke {
    fileprivate func withLineStyle(_ style: ResolvedLineStyle) -> ResolvedStroke {
        var copy = self
        copy.lineStyle = style
        return copy
    }
}
