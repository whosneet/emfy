import CoreGraphics

/// Pure page-fit maths for printing (F1 design call 1). Given the drawing's natural
/// device size and a page's printable rect, it computes the rect to draw the
/// (vector) drawing into — centred, aspect preserved for Fit to Page; at natural
/// point size centred for Actual Size — and picks the page orientation from the
/// drawing's aspect. Framework-light (CoreGraphics geometry only) so it is unit
/// tested without a print operation or a window.
enum PrintLayout {
    /// The print-panel accessory's "Scale" choice.
    enum Scaling: Sendable, Equatable, CaseIterable {
        /// Scale the drawing to fill the printable area, aspect preserved (up or down).
        case fitToPage
        /// Draw at one point per device pixel, centred (a large drawing is clipped by
        /// the page, exactly as a 1:1 print would be).
        case actualSize
    }

    /// A page orientation, derived from the drawing's aspect so a wide drawing prints
    /// landscape and a tall one portrait.
    enum Orientation: Sendable, Equatable {
        case portrait
        case landscape
    }

    /// The orientation that best matches the drawing: landscape when it is strictly
    /// wider than tall, otherwise portrait (a square or degenerate size prints
    /// portrait).
    static func orientation(for naturalSize: CGSize) -> Orientation {
        naturalSize.width > naturalSize.height ? .landscape : .portrait
    }

    /// The rect — in the page's coordinate space, where `printable.origin` is the
    /// printable area's origin — to draw the drawing into.
    ///
    /// - `fitToPage`: the largest aspect-preserving rect that fits inside `printable`,
    ///   centred. Upscales a small drawing and downscales a large one.
    /// - `actualSize`: `naturalSize` at one point per device pixel, centred on the
    ///   printable area (which may place it partly outside `printable` when the
    ///   drawing is larger than the page — the page then clips it).
    ///
    /// A non-positive natural dimension is floored at 1 so the maths never divides by
    /// zero or yields a null rect.
    static func drawRect(naturalSize: CGSize, printable: CGRect, scaling: Scaling) -> CGRect {
        let width = max(1, naturalSize.width)
        let height = max(1, naturalSize.height)
        switch scaling {
        case .actualSize:
            return centred(size: CGSize(width: width, height: height), in: printable)
        case .fitToPage:
            let scale = min(printable.width / width, printable.height / height)
            let size = CGSize(width: width * scale, height: height * scale)
            return centred(size: size, in: printable)
        }
    }

    private static func centred(size: CGSize, in printable: CGRect) -> CGRect {
        CGRect(
            x: printable.midX - size.width / 2,
            y: printable.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
