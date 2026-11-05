import CoreGraphics
import EMFRender

/// How a viewer tile is painted (S1a-4b): the page fill behind the drawing
/// (Page background) and the dark-mode treatment over it (Page in Dark Mode).
/// Both the Mac and iOS `CATiledLayer` views draw through `TilePainter` with this,
/// so the two platforms stay identical. `Sendable`/`Equatable` so it can cross the
/// tiled-layer's background thread and be diffed for a redraw.
struct TilePaint: Equatable, Sendable {
    enum Page: Equatable, Sendable { case white, dark, checkerboard }
    enum Treatment: Equatable, Sendable { case none, dim, invert }
    var page: Page
    var treatment: Treatment

    /// The historical default: white page, no treatment.
    static let plain = TilePaint(page: .white, treatment: .none)
}

/// Resolves the two viewer settings plus the live appearance into a `TilePaint`.
/// Pure, so the mapping is unit-tested without a view.
enum ViewerTilePaint {
    static func page(for background: EmfySettings.PageBackground, isDark: Bool) -> TilePaint.Page {
        switch background {
        case .whitePage: .white
        case .checkerboard: .checkerboard
        case .matchAppearance: isDark ? .dark : .white
        }
    }

    /// The dark-mode treatment is viewer-only and active ONLY while the system
    /// appearance is Dark — in Light it's always `.none`, whatever the setting.
    static func treatment(for mode: EmfySettings.DarkPageMode, isDark: Bool) -> TilePaint.Treatment {
        guard isDark else { return .none }
        switch mode {
        case .off: return .none
        case .dim: return .dim
        case .invert: return .invert
        }
    }

    static func make(
        background: EmfySettings.PageBackground,
        darkMode: EmfySettings.DarkPageMode,
        isDark: Bool
    ) -> TilePaint {
        let treatment = treatment(for: darkMode, isDark: isDark)
        var page = page(for: background, isDark: isDark)
        // Invert fills the tile with white under `.difference`, so the page is
        // inverted along with the ink: a dark "match appearance" page would come
        // out LIGHT, defeating the dark page the user asked for (S1a-4c fix). Under
        // invert the page must be white, so it inverts to dark. Dim darkens whatever
        // page is drawn, so a dark page under Dim is correct and left alone.
        if treatment == .invert, page == .dark {
            page = .white
        }
        return TilePaint(page: page, treatment: treatment)
    }
}

/// Draws one tile: the page, then the drawing, then the dark-mode treatment. The
/// treatment is done with blend modes inside the tile context — no extra bitmap,
/// so tiles stay crisp and memory stays bounded to the screen. Called on the
/// `CATiledLayer` background thread, so everything here is `static` over
/// `Sendable` inputs.
enum TilePainter {
    /// The dark page colour for "match light/dark" in Dark Mode — darker than the
    /// grey backdrop so the page edge still reads.
    static let darkPageColor = CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    /// Transparency-checkerboard tones (page coordinates, so they stay crisp per
    /// tile at any zoom).
    private static let checkerLight = CGColor(gray: 1, alpha: 1)
    private static let checkerDark = CGColor(gray: 0.82, alpha: 1)
    private static let checkerSquare: CGFloat = 16

    /// Paints `paint` for `rect` (the tile's page-space dirty rect). `replayInk`
    /// draws the metafile into the context in page space; the two platforms pass
    /// the same render call differing only in the y-flip they apply first.
    static func paint(
        _ paint: TilePaint,
        into context: CGContext,
        rect: CGRect,
        replayInk: (CGContext) -> Void
    ) {
        // 1. Page.
        switch paint.page {
        case .white:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        case .dark:
            context.setFillColor(darkPageColor)
            context.fill(rect)
        case .checkerboard:
            drawCheckerboard(into: context, rect: rect)
        }

        // 2. The drawing.
        context.saveGState()
        replayInk(context)
        context.restoreGState()

        // 3. The dark-mode treatment.
        switch paint.treatment {
        case .none:
            break
        case .dim:
            applyDim(into: context, rect: rect)
        case .invert:
            applyInvert(into: context, rect: rect, replayInk: replayInk)
        }
    }

    /// Dim: a modest translucent-black wash over the whole tile.
    static func applyDim(into context: CGContext, rect: CGRect) {
        context.setBlendMode(.normal)
        context.setFillColor(CGColor(gray: 0, alpha: 0.4))
        context.fill(rect)
        context.setBlendMode(.normal)
    }

    /// Hue-preserving invert, with no extra bitmap (owner's technique):
    /// (a) fill the tile with white under `.difference` → the tile is now inverted
    ///     (1 − colour), so white→black and black→white;
    /// (b) replay the drawing under `.hue` → the result keeps the ORIGINAL hue with
    ///     the inverted saturation and luminance. A dark drawing on a white page
    ///     becomes a light drawing on a dark page, colours recognisable.
    static func applyInvert(
        into context: CGContext,
        rect: CGRect,
        replayInk: (CGContext) -> Void
    ) {
        context.saveGState()
        context.setBlendMode(.difference)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.restoreGState()

        context.saveGState()
        context.setBlendMode(.hue)
        replayInk(context)
        context.restoreGState()

        context.setBlendMode(.normal)
    }

    private static func drawCheckerboard(into context: CGContext, rect: CGRect) {
        let size = checkerSquare
        context.setFillColor(checkerDark)
        context.fill(rect)
        context.setFillColor(checkerLight)
        let startX = (rect.minX / size).rounded(.down) * size
        let startY = (rect.minY / size).rounded(.down) * size
        var y = startY
        while y < rect.maxY {
            var x = startX
            while x < rect.maxX {
                let col = Int((x / size).rounded(.down))
                let row = Int((y / size).rounded(.down))
                if (col + row) % 2 == 0 {
                    context.fill(CGRect(x: x, y: y, width: size, height: size).intersection(rect))
                }
                x += size
            }
            y += size
        }
    }
}
