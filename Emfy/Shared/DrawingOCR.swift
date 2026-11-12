import CoreGraphics
import CryptoKit
import Foundation

// MARK: - OCR of embedded pictures (F3)
//
// The pure helpers behind Vision text recognition of a drawing's embedded
// pictures: the per-file budget, the content-hash cache key, the downsample
// sizing, and the normalised-box → device-space mapping. The Vision request
// itself (VNRecognizeTextRequest, accurate, on-device) and the in-memory + on-disk
// caches live in the app's concrete OCR service; these helpers carry the geometry
// and bookkeeping so they can be tested without the Vision runtime.

/// The hard budget for OCR over one file (§8 / design call #3). A hostile file
/// must not drive Vision into an unbounded amount of work.
enum OCRBudget {
    /// At most this many embedded pictures are recognised per file.
    static let maxImages = 50
    /// Each picture is downsampled so its long side is at most this many pixels.
    static let maxLongSidePixels: CGFloat = 4096
    /// The whole-file OCR pass is abandoned after this many seconds.
    static let perFileTimeoutSeconds: TimeInterval = 20
}

/// The content-hash cache key for a picture. Keying by content (not by position
/// or record index) means the same bitmap drawn many times is recognised once.
enum OCRCacheKey {
    /// SHA-256 of the picture's raw bytes, lower-case hex. Stable across launches,
    /// so it also names the on-disk cache entry.
    static func make(forImageData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum OCRGeometry {

    /// The pixel size a picture is downsampled to before recognition: the long
    /// side is clamped to `OCRBudget.maxLongSidePixels`, aspect preserved. A
    /// picture already within budget is returned unchanged (rounded to whole
    /// pixels). A degenerate size returns a 1×1.
    static func downsampledSize(for pixelSize: CGSize, maxLongSide: CGFloat = OCRBudget.maxLongSidePixels) -> CGSize {
        let w = pixelSize.width, h = pixelSize.height
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return CGSize(width: 1, height: 1) }
        let longest = max(w, h)
        guard longest > maxLongSide else {
            return CGSize(width: w.rounded(), height: h.rounded())
        }
        let scale = maxLongSide / longest
        return CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
    }

    /// Maps a Vision bounding box into device space. Vision boxes are normalised
    /// to the recognised image with a BOTTOM-LEFT origin (y-up), 0…1 on each
    /// axis; device space is y-DOWN. The box is placed inside `destRectDevice`
    /// (the picture's device-space destination), flipping y, then `transform`
    /// (the element transform in effect) is applied and its bounding box returned.
    static func deviceBox(
        fromNormalized box: CGRect,
        destRectDevice: CGRect,
        transform: CGAffineTransform = .identity
    ) -> CGRect {
        let x = destRectDevice.minX + box.minX * destRectDevice.width
        // Vision y-up → device y-down: the box's TOP edge (box.maxY) is nearer the
        // destination's top (smaller device y).
        let y = destRectDevice.minY + (1 - box.maxY) * destRectDevice.height
        let w = box.width * destRectDevice.width
        let h = box.height * destRectDevice.height
        let placed = CGRect(x: x, y: y, width: w, height: h)
        return transform.isIdentity ? placed : placed.applying(transform)
    }
}
