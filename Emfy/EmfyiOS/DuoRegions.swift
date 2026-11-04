import SwiftUI

/// iPhone Duo reserved-region helpers (axiom-swiftui iphone-duo.md). On a
/// partially folded Duo the display splits into a fold (division) region and,
/// when the inner camera runs, an occlusion region. Custom overlays — the zoom
/// pill and the partial-support banner — must move clear of both (displace,
/// never hide); the recents grid prefers an even column count when a division
/// region exists. All reads are `@available(iOS 27.1, *)`; before 27.1 only
/// system components know where the fold is, so the helpers return neutral
/// values and top-centre placement is fine.
enum DuoRegions {
    /// The active fold and camera frames, in the proxy's coordinate space.
    struct Active {
        var division: CGRect?
        var occlusion: CGRect?
    }

    /// Reads the active division and occlusion frames. Empty before iOS 27.1 or
    /// when neither region is active (flat, inner camera idle).
    static func active(in proxy: GeometryProxy) -> Active {
        guard #available(iOS 27.1, *) else { return Active() }
        let division = proxy.reservedRegions(kind: .division)
            .filter(\.isActive)
            .map(\.frame)
            .max { $0.width < $1.width }
        let occlusion = proxy.reservedRegions(kind: .occlusion)
            .filter(\.isActive)
            .map(\.frame)
            .max { $0.height < $1.height }
        return Active(division: division, occlusion: occlusion)
    }

    /// True when a division region exists at all (active or not) — the signal
    /// the grid uses to prefer an even column count (111463 7:36).
    static func hasDivisionRegion(in proxy: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
    }

    /// True when the fold runs horizontally across the whole width (the division
    /// spans the view), rather than vertically down the middle. Such a fold is
    /// cleared by moving overlays below it, not sideways.
    private static func isHorizontalFold(_ division: CGRect?, viewWidth: CGFloat) -> Bool {
        guard let d = division, isUsable(d) else { return false }
        return d.width >= viewWidth - 1
    }

    /// A horizontal offset that moves a horizontally-centred overlay to the
    /// centre of the larger side of a VERTICAL fold, so it never lands in the
    /// division. Zero when there is no active vertical fold (including a
    /// full-width horizontal fold, which is cleared vertically instead).
    static func centredOverlayXOffset(viewWidth: CGFloat, division: CGRect?) -> CGFloat {
        guard viewWidth.isFinite, viewWidth > 0,
              let division, isUsable(division),
              !isHorizontalFold(division, viewWidth: viewWidth)
        else { return 0 }
        let leftWidth = division.minX
        let rightWidth = viewWidth - division.maxX
        let targetCentre = leftWidth >= rightWidth
            ? leftWidth / 2
            : division.maxX + rightWidth / 2
        return targetCentre - viewWidth / 2
    }

    /// The usable width for a centred overlay — the larger side of a vertical
    /// fold, or the full width otherwise. The banner is constrained to this
    /// (minus margins) before offsetting, so Details and X never cross the fold.
    static func largerSideWidth(viewWidth: CGFloat, division: CGRect?) -> CGFloat {
        guard viewWidth.isFinite, viewWidth > 0,
              let division, isUsable(division),
              !isHorizontalFold(division, viewWidth: viewWidth)
        else { return max(1, viewWidth) }
        let leftWidth = division.minX
        let rightWidth = viewWidth - division.maxX
        return max(1, max(leftWidth, rightWidth))
    }

    /// The top inset a top-anchored overlay needs to clear the inner camera, and
    /// a full-width horizontal fold. Returns `base` when neither is in the way.
    static func overlayTopInset(base: CGFloat, occlusion: CGRect?, division: CGRect?, viewWidth: CGFloat) -> CGFloat {
        var inset = base
        if let occlusion, isUsable(occlusion) {
            inset = max(inset, occlusion.maxY + 8)
        }
        if isHorizontalFold(division, viewWidth: viewWidth), let division {
            inset = max(inset, division.maxY + 8)
        }
        return inset
    }

    /// A reserved-region frame is only usable when it is finite and has positive
    /// extent; degenerate frames are ignored.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width > 0 && rect.height > 0
    }

    /// An even column count for the recents grid. When a division region exists,
    /// an odd count is reduced by one so the middle gutter can straddle the fold
    /// rather than a tile (`GridItem(.adaptive(minimum:))` picks its own, often
    /// odd, count — so the column decision is made here instead).
    static func gridColumnCount(
        availableWidth: CGFloat,
        minTileWidth: CGFloat,
        spacing: CGFloat,
        preferEven: Bool
    ) -> Int {
        guard availableWidth > 0, minTileWidth > 0 else { return 1 }
        let raw = max(1, Int((availableWidth + spacing) / (minTileWidth + spacing)))
        if preferEven, raw > 1, raw % 2 == 1 {
            return raw - 1
        }
        return raw
    }
}
