import CoreGraphics
import Foundation

/// Context-size math for the preview extension: aspect-fit a metafile's natural
/// device-pixel size into a long-edge cap. The natural size comes from EMFKit
/// (`MetafileRenderer.Prepared.naturalSize`: the EMF header bounds or the WMF
/// program canvas), already clamped to at least 1×1.
enum PreviewSizing {
    /// The preview context size in points: the natural size's aspect ratio
    /// scaled so the longer edge is at most `maxLongEdge`, never upscaled past
    /// the native pixel size, and never smaller than 1×1.
    static func contextSize(for naturalSize: CGSize, maxLongEdge: Int) -> CGSize {
        let width = naturalSize.width
        let height = naturalSize.height
        guard width >= 1, height >= 1 else {
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
