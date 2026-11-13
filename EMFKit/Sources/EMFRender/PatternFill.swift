import CoreGraphics
import EMFParse
import Foundation

/// Builds a tiling `CGPattern` for a DIB pattern brush (EMR_CREATEDIBPATTERNBRUSHPT
/// / EMR_CREATEMONOBRUSH, [MS-EMF] §2.3.7.4/.5).
///
/// GDI tiles a pattern brush at DEVICE resolution — one DIB pixel per device
/// pixel — anchored at the brush origin (EMR_SETBRUSHORGEX, §2.3.11.12), which
/// sets the pattern phase. This renderer draws in target space, so the pattern
/// matrix maps the pattern's device-space cell grid to target space via the
/// `deviceToTarget` fit, offset by the brush origin so a tile boundary lands on
/// that anchor. The tile is one DIB in size; `tiling` is `.constantSpacing` so
/// the cells abut with no seam.
enum PatternFill {

    /// A tiling colour pattern for `brush`, or `nil` when the DIB cannot be
    /// rasterised (defence in depth — the resolver only produces a `.pattern`
    /// brush for a `.pixels` DIB, so this is reached only for a degenerate one).
    /// `brushOrigin` is in device units; `base` is the device→target transform.
    static func makePattern(
        brush: PatternBrush,
        brushOrigin: PointL,
        deviceToTarget base: CGAffineTransform
    ) -> CGPattern? {
        guard let image = BitmapDecoder.cgImage(from: brush.dib),
              image.width > 0, image.height > 0 else { return nil }

        let tileWidth = CGFloat(image.width)
        let tileHeight = CGFloat(image.height)

        // Pattern (device) space → target space: translate by the brush origin so
        // the tile grid is phased to it, then apply the canvas fit.
        let matrix = CGAffineTransform(translationX: CGFloat(brushOrigin.x), y: CGFloat(brushOrigin.y))
            .concatenating(base)

        // Retain the image across the pattern's lifetime; the release callback
        // balances it. The draw callback is a C function and cannot capture, so
        // the image travels through `info`.
        let info = Unmanaged.passRetained(image).toOpaque()
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, ctx in
                guard let info else { return }
                let image = Unmanaged<CGImage>.fromOpaque(info).takeUnretainedValue()
                let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
                // The decoded image is TOP-DOWN (row 0 = top). The pattern cell's
                // space is device y-down (the device→target flip lives in the
                // pattern matrix), so flip within the cell to place row 0 at the
                // top, keeping the tile's orientation consistent with the rest of
                // the device-space pipeline.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: rect.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: rect)
                ctx.restoreGState()
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<CGImage>.fromOpaque(info).release()
            }
        )

        guard let pattern = CGPattern(
            info: info,
            bounds: CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight),
            matrix: matrix,
            xStep: tileWidth,
            yStep: tileHeight,
            tiling: .constantSpacing,
            isColored: true,
            callbacks: &callbacks
        ) else {
            // CGPattern did not take ownership; release the retain we made.
            Unmanaged<CGImage>.fromOpaque(info).release()
            return nil
        }
        return pattern
    }
}
