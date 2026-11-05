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
}
