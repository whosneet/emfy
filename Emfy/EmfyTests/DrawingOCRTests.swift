import CoreGraphics
import Foundation
import Testing

// F3 unit tests for the pure OCR helpers (`OCRCacheKey`, `OCRGeometry`): the
// content-hash cache key, the downsample sizing against the 4096 px budget, and
// the Vision normalised-box → device-space mapping (y-flip and destination
// placement). The Vision request itself is exercised by the app's OCR service.

@Suite struct DrawingOCRTests {

    // MARK: Cache key

    @Test func cacheKeyIsStableAndContentAddressed() {
        let a = Data([1, 2, 3, 4])
        let b = Data([1, 2, 3, 4])
        let c = Data([9, 9, 9, 9])
        #expect(OCRCacheKey.make(forImageData: a) == OCRCacheKey.make(forImageData: b))
        #expect(OCRCacheKey.make(forImageData: a) != OCRCacheKey.make(forImageData: c))
        // SHA-256 hex is 64 characters.
        #expect(OCRCacheKey.make(forImageData: a).count == 64)
    }

    // MARK: Downsample sizing

    @Test func downsampleClampsLongSideToBudget() {
        let size = OCRGeometry.downsampledSize(for: CGSize(width: 8192, height: 4096))
        #expect(size.width == 4096)
        #expect(size.height == 2048)
    }

    @Test func downsampleLeavesSmallImagesUnchanged() {
        let size = OCRGeometry.downsampledSize(for: CGSize(width: 1000, height: 500))
        #expect(size == CGSize(width: 1000, height: 500))
    }

    @Test func downsampleHandlesDegenerateSize() {
        #expect(OCRGeometry.downsampledSize(for: CGSize(width: 0, height: 0)) == CGSize(width: 1, height: 1))
    }

    // MARK: Normalised box → device mapping

    @Test func fullBoxMapsToWholeDestination() {
        let dest = CGRect(x: 100, y: 200, width: 400, height: 300)
        let mapped = OCRGeometry.deviceBox(fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), destRectDevice: dest)
        #expect(mapped == dest)
    }

    @Test func topOfImageMapsToTopOfDestinationWithYFlip() {
        let dest = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Vision box in the TOP half of the image: y-up origin 0.5, height 0.5.
        let topHalf = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let mapped = OCRGeometry.deviceBox(fromNormalized: topHalf, destRectDevice: dest)
        // Device y-down: the top half is y 0…50.
        #expect(mapped == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test func transformIsApplied() {
        let dest = CGRect(x: 0, y: 0, width: 10, height: 10)
        let shift = CGAffineTransform(translationX: 5, y: 7)
        let mapped = OCRGeometry.deviceBox(fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), destRectDevice: dest, transform: shift)
        #expect(mapped == CGRect(x: 5, y: 7, width: 10, height: 10))
    }
}
