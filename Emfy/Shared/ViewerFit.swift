import CoreGraphics
import Foundation

/// Pure fit-and-centre maths shared by the Mac and iOS viewers (v3-plan §9.1
/// "fit inside the bars while they show; full screen when hidden"). Extracted
/// from the views so the geometry is unit-tested: given the picture's natural
/// size, the viewport, and the safe-area insets the bars occupy, it returns the
/// scale that fits the picture inside the *visible* region and the inset that
/// centres it. When the bars are hidden the caller passes `.zero` insets, so the
/// picture fits the full screen.
enum ViewerFit {
    /// Platform-neutral safe-area insets; `UIEdgeInsets` / `NSEdgeInsets` convert
    /// in the views. All values are non-negative point distances from each edge.
    struct Insets: Equatable, Sendable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat

        static let zero = Insets(top: 0, leading: 0, bottom: 0, trailing: 0)

        init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }
    }

    /// The region of `viewport` left after removing the safe-area insets and a
    /// uniform `margin` on every side. Never smaller than 1×1, so callers never
    /// divide by zero.
    static func availableSize(viewport: CGSize, insets: Insets = .zero, margin: CGFloat = 0) -> CGSize {
        let width = viewport.width - insets.leading - insets.trailing - margin * 2
        let height = viewport.height - insets.top - insets.bottom - margin * 2
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /// The scale that fits `content` inside the safe-area-reduced viewport.
    /// Clamped to `[minScale, maxScale]`; `maxScale` defaults to 1 so fit never
    /// magnifies past actual size. Returns `minScale` for degenerate or
    /// non-finite inputs.
    static func fitScale(
        content: CGSize,
        viewport: CGSize,
        insets: Insets = .zero,
        margin: CGFloat = 0,
        minScale: CGFloat = 0.01,
        maxScale: CGFloat = 1
    ) -> CGFloat {
        guard content.width > 0, content.height > 0,
              content.width.isFinite, content.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return minScale
        }
        let available = availableSize(viewport: viewport, insets: insets, margin: margin)
        let fit = min(available.width / content.width, available.height / content.height)
        guard fit.isFinite else { return minScale }
        return min(max(fit, minScale), maxScale)
    }

    /// The clip-bounds origin that centres a `content` document within the
    /// *unobscured* region of a `bounds`-sized viewport (both in the clip view's
    /// bounds coordinates), given the `insets` the sidebar/toolbar occlude (same
    /// coordinates). Only an axis where the content is smaller than the viewport is
    /// re-centred; a larger axis keeps `proposed`, so a zoomed page scrolls freely.
    ///
    /// For the Mac's non-flipped clip view the `top` inset (toolbar) occludes the
    /// HIGH-y (visual top) edge, and the `leading` inset (floating sidebar) occludes
    /// the LOW-x (left) edge. The document centre must appear at the centre of the
    /// unobscured region `[leading, bounds − trailing]` × `[bottom, bounds − top]`,
    /// which gives the signs below. (C4b review #1: the former inline x formula
    /// added `leading` and subtracted `trailing`, centring in a rect anchored at the
    /// window's left edge, so a small page sat one sidebar-width left of the pane
    /// centre. The y formula was already correct for the non-flipped axis.)
    static func centeredClipOrigin(
        proposed: CGPoint,
        content: CGSize,
        bounds: CGSize,
        insets: Insets
    ) -> CGPoint {
        var origin = proposed
        if bounds.width > content.width {
            origin.x = (content.width - bounds.width + insets.trailing - insets.leading) / 2
        }
        if bounds.height > content.height {
            origin.y = (content.height - bounds.height + insets.top - insets.bottom) / 2
        }
        return origin
    }

    /// The editor's re-fit decision when the viewport changes (E3e fix B). The Mac editor
    /// must keep the page fully inside the visible pane — re-fitting when the inspector
    /// opens or closes and on window resize — while leaving a MANUAL zoom alone, exactly as
    /// the iPad already does. Returns the magnification to adopt, or nil to keep the
    /// current one.
    ///
    /// Re-fit when: it's the first layout (`hasFittedBefore == false`); or the viewport
    /// changed and the page was still at its fit scale (not manually zoomed); or the
    /// viewport changed and the page now OVERFLOWS the visible region (so a shrink — e.g.
    /// the inspector opening — never leaves it cut off), even after a manual zoom.
    static func editorRefitScale(
        content: CGSize,
        viewport: CGSize,
        insets: Insets,
        margin: CGFloat,
        minScale: CGFloat,
        maxScale: CGFloat,
        currentMagnification: CGFloat,
        previousFitScale: CGFloat,
        hasFittedBefore: Bool,
        viewportChanged: Bool
    ) -> CGFloat? {
        let fit = fitScale(content: content, viewport: viewport, insets: insets, margin: margin, minScale: minScale, maxScale: maxScale)
        guard hasFittedBefore else { return fit }
        guard viewportChanged else { return nil }
        // Still at the previous fit (within a small relative tolerance) → follow the new fit.
        if previousFitScale > 0, abs(currentMagnification - previousFitScale) <= previousFitScale * 0.01 {
            return fit
        }
        // Manually zoomed, but the page no longer fits the visible region → snap to fit so
        // it is never cut off.
        let available = availableSize(viewport: viewport, insets: insets, margin: margin)
        if content.width * currentMagnification > available.width + 0.5 ||
           content.height * currentMagnification > available.height + 0.5 {
            return fit
        }
        return nil
    }

    /// The inset that centres `content * scale` within the safe-area-reduced
    /// viewport (a scroll view's `contentInset`): the safe-area inset on each edge
    /// plus half the slack on each axis. Zero extra on an axis where the scaled
    /// content is larger than the available region.
    static func centringInset(
        content: CGSize,
        viewport: CGSize,
        scale: CGFloat,
        insets: Insets = .zero
    ) -> Insets {
        let available = availableSize(viewport: viewport, insets: insets)
        let extraX = max(0, (available.width - content.width * scale) / 2)
        let extraY = max(0, (available.height - content.height * scale) / 2)
        return Insets(
            top: insets.top + extraY,
            leading: insets.leading + extraX,
            bottom: insets.bottom + extraY,
            trailing: insets.trailing + extraX
        )
    }

    // MARK: - Adaptive tile size + placeholder (P2b)
    //
    // Pure policy shared by the Mac (`MacMetafileScrollView`) and iOS
    // (`ZoomableMetafileView`) tiled viewers. It lives here (not in ZoomMath,
    // which is macOS-only in the multiplatform target) so both platforms and the
    // unit tests see one copy.

    /// The estimated playback-op count (`Prepared.estimatedPlaybackOps`) at or
    /// above which the tiled viewer switches from 512 pt tiles to large tiles.
    /// Each tile re-executes the whole record stream, so the fit-view repaint ≈
    /// tile count × per-tile cost; above this the file is heavy enough that fewer,
    /// larger tiles pay off. Measured targets: a ~278k-record GDI file
    /// (~73 ms/tile) and a ~276k-record dual EMF+ file (~584 ms/tile) both
    /// qualify, while an ordinary file of a few thousand records stays on 512 and
    /// is untouched.
    static let largeTileOpThreshold = 50_000

    /// The historical tile side — kept exactly for a cheap document, so nothing
    /// changes for it.
    static let defaultTileSide: CGFloat = 512
    /// The large tile side for an expensive document. 1024 pt → 2048² px at a 2×
    /// backing scale = 16 MB per tile: a budget-safe quarter of a 2048-pt tile's
    /// 64 MB, and ~4× fewer tiles at fit, so a fit-to-window view of a heavy file
    /// replays the stream a handful of times instead of a dozen-plus. Levels of
    /// detail and the magnification bias are unchanged, so zoom-in stays crisp.
    static let largeTileSide: CGFloat = 1024

    /// Whether a document is expensive enough to replay that it earns large tiles
    /// and a render-once placeholder (P2b).
    static func isExpensiveToReplay(playbackOps: Int) -> Bool {
        playbackOps >= largeTileOpThreshold
    }

    /// The `CATiledLayer.tileSize` side (pt) for a document of `ops` estimated
    /// playback ops: `defaultTileSide` for a cheap one, `largeTileSide` for an
    /// expensive one.
    static func tileSide(forPlaybackOps ops: Int) -> CGFloat {
        isExpensiveToReplay(playbackOps: ops) ? largeTileSide : defaultTileSide
    }

    /// The long edge (px) the render-once placeholder beneath the tiles is capped
    /// to (P2b). The placeholder is a transient, blurry stand-in shown only while
    /// tiles fill in, so a modest resolution keeps its one render and its retained
    /// bitmap cheap (1536² × 4 ≈ 9 MB worst case).
    static let maxPlaceholderLongEdge: CGFloat = 1536

    /// The render scale for the placeholder image: the page's long side scaled to
    /// at most `maxPlaceholderLongEdge`, never upscaled past 1×.
    static func placeholderScale(forLongSide longSide: CGFloat) -> CGFloat {
        guard longSide.isFinite, longSide > maxPlaceholderLongEdge else { return 1 }
        return maxPlaceholderLongEdge / longSide
    }
}
