import CoreGraphics
import EMFRender
import Foundation

/// Pure export scale/cap selection (S1a Export › Default PNG scale).
///
/// Picks the effective 1×/2×/3× multiplier for a picture, reducing it only to
/// keep the output within **one** area cap on both platforms — Mac/iOS export
/// parity (owner: docs/v3-plan.md, Export size). The cap is the renderer's own
/// 32 MP canvas-area constant, not a separate hard-coded number, so the two can
/// never drift. Nothing here renders — callers pass the base device-pixel size
/// and the cap, so the helper stays testable and framework-neutral.
enum ExportScale {
    /// The single export area cap, both platforms: the renderer's 32 MP
    /// canvas-area cap (`EMFRenderer.canvasAreaCap`).
    static var areaCap: Int { EMFRenderer.canvasAreaCap }

    struct Result: Equatable, Sendable {
        /// The multiplier actually applied (1, 2 or 3).
        let multiplier: Int
        /// Output pixel size — base × multiplier.
        let width: Int
        let height: Int
        /// True when `multiplier` was lowered from the request to fit the cap.
        let wasReduced: Bool
    }

    /// The largest multiplier in `1...requested` whose output area fits `areaCap`.
    /// Never upscales past `requested`; never drops below 1× (the renderer's own
    /// per-side/area clamp handles a picture still over the cap at 1×). Area is
    /// computed in `Int64` so a large picture can't overflow.
    static func select(baseWidth: Int, baseHeight: Int, requested: Int, areaCap: Int) -> Result {
        let w = max(1, baseWidth)
        let h = max(1, baseHeight)
        let want = min(max(requested, 1), 3)
        let cap = Int64(max(areaCap, 1))
        var m = want
        while m > 1, area(w, h, m) > cap { m -= 1 }
        return Result(multiplier: m, width: w * m, height: h * m, wasReduced: m < want)
    }

    /// Convenience over the `PNGScale` setting.
    static func select(
        baseWidth: Int,
        baseHeight: Int,
        requested: EmfySettings.PNGScale,
        areaCap: Int
    ) -> Result {
        select(baseWidth: baseWidth, baseHeight: baseHeight, requested: requested.multiplier, areaCap: areaCap)
    }

    private static func area(_ w: Int, _ h: Int, _ m: Int) -> Int64 {
        (Int64(w) * Int64(m)) * (Int64(h) * Int64(m))
    }

    /// The effective PNG render scale and background for a picture of
    /// `naturalSize`, reading the live Export settings (S1a-6): the Default PNG
    /// scale, reduced by the shared area cap when the picture is large, and the
    /// PNG background. One resolution point so every PNG export and share — Mac
    /// and iOS — chooses identically. `@MainActor` because it reads the settings
    /// store; callers capture the returned Sendable values into the off-main
    /// render.
    @MainActor
    static func pngOptions(for naturalSize: CGSize, settings: EmfySettings) -> (scale: CGFloat, background: RenderBackground) {
        let result = select(
            baseWidth: Int(naturalSize.width.rounded()),
            baseHeight: Int(naturalSize.height.rounded()),
            requested: settings.defaultPNGScale,
            areaCap: areaCap
        )
        let background: RenderBackground = settings.pngBackground == .transparent ? .transparent : .white
        return (CGFloat(result.multiplier), background)
    }
}

/// The order the two export formats appear in, primary (the Default export
/// format setting) first (S1a-6 Export › Default export format). Pure, so the
/// Mac File menu, the iOS share menu and the inspector's export rows all order
/// their PNG/PDF entries the same way and a single test covers the choice.
enum ExportMenuOrder {
    static func formats(default primary: EmfySettings.ExportFormat) -> [EmfySettings.ExportFormat] {
        primary == .png ? [.png, .pdf] : [.pdf, .png]
    }
}
