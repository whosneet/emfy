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
    ///
    /// `minimumSize` is the request's floor: `QLThumbnailReply` rejects a
    /// context smaller than it, so each axis is raised to at least the
    /// corresponding minimum when that component is positive. When
    /// `minimumSize` is `.zero` (the common Finder case) the result is
    /// byte-identical to fitting alone.
    static func contextSize(
        for header: EMFHeader,
        maximumSize: CGSize,
        minimumSize: CGSize
    ) -> CGSize {
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
        var outWidth = max((w * fit).rounded(), 1)
        var outHeight = max((h * fit).rounded(), 1)

        // Raise each axis to the requested minimum (the accept threshold),
        // still clamped to the maximum. If minimum exceeds maximum on an axis,
        // prefer satisfying the minimum — that is what QLThumbnailReply checks.
        if minimumSize.width > 0 {
            let minWidth = minimumSize.width.rounded(.up)
            outWidth = max(min(outWidth, maxWidth), minWidth)
        }
        if minimumSize.height > 0 {
            let minHeight = minimumSize.height.rounded(.up)
            outHeight = max(min(outHeight, maxHeight), minHeight)
        }

        return CGSize(width: outWidth, height: outHeight)
    }
}
