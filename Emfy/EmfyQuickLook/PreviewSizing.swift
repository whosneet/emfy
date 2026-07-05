import CoreGraphics
import EMFParse
import Foundation

/// Context-size math for the preview extension: aspect-fit the header's
/// device-pixel bounds into a long-edge cap. Kept in Int64 so a full-range
/// `rclBounds` cannot overflow the +1 (inclusive-inclusive) arithmetic
/// (primer §8: no unchecked arithmetic on parse-derived values).
enum PreviewSizing {
    /// The preview context size in points: the header bounds' aspect ratio
    /// scaled so the longer edge is at most `maxLongEdge`, never upscaled past
    /// the native pixel size, and never smaller than 1×1.
    static func contextSize(for header: EMFHeader, maxLongEdge: Int) -> CGSize {
        let bounds = header.bounds
        let width = Int64(bounds.right) - Int64(bounds.left) + 1
        let height = Int64(bounds.bottom) - Int64(bounds.top) + 1
        guard width > 0, height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let cap = Double(max(maxLongEdge, 1))
        let w = Double(width)
        let h = Double(height)
        let longEdge = max(w, h)
        // Scale down to the cap; never magnify beyond native.
        let scale = longEdge > cap ? cap / longEdge : 1
        let outWidth = max((w * scale).rounded(), 1)
        let outHeight = max((h * scale).rounded(), 1)
        return CGSize(width: outWidth, height: outHeight)
    }
}
