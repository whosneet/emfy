import CoreGraphics
import EMFParse
import Foundation

/// Context-size math for the thumbnail extension: aspect-fit the header's
/// device-pixel bounds into the requested maximum box. Kept in Int64 so a
/// full-range `rclBounds` cannot overflow the +1 (inclusive-inclusive)
/// arithmetic (primer §8: no unchecked arithmetic on parse-derived values).
enum ThumbnailSizing {
    /// The thumbnail context size in points: the header bounds' aspect ratio
    /// scaled to fit inside `maximumSize`, never upscaled past the native pixel
    /// size, and never smaller than 1×1. A degenerate maximum falls back to a
    /// 1×1 box.
    static func contextSize(for header: EMFHeader, maximumSize: CGSize) -> CGSize {
        let maxWidth = maximumSize.width
        let maxHeight = maximumSize.height
        guard maxWidth >= 1, maxHeight >= 1 else {
            return CGSize(width: 1, height: 1)
        }

        let bounds = header.bounds
        let width = Int64(bounds.right) - Int64(bounds.left) + 1
        let height = Int64(bounds.bottom) - Int64(bounds.top) + 1
        guard width > 0, height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let w = Double(width)
        let h = Double(height)
        // Fit inside the box; never magnify beyond native size.
        let fit = min(maxWidth / w, maxHeight / h, 1)
        let outWidth = max((w * fit).rounded(), 1)
        let outHeight = max((h * fit).rounded(), 1)
        return CGSize(width: outWidth, height: outHeight)
    }
}
