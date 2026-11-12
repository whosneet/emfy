import CoreGraphics
import Foundation
import ImageIO

/// Decodes UNTRUSTED image bytes (a file the user picks, a Photos item, a dropped
/// image) into a pixels-only `CGImage`, enforcing the E3c §8/privacy caps before any
/// allocation: input-byte and pixel-count ceilings, and a long-side downsample. The
/// decode goes through ImageIO (an approved EMFEdit dependency, as in
/// `SceneImageCoding`) and never touches a parse path. The returned image carries
/// pixels only; `SceneFactory.makeImage` re-encodes it to a compressed PNG, which is
/// what the scene stores — so EXIF/GPS metadata never reaches the document.
public enum SceneImageImport {
    /// The maximum accepted input size (40 MB): a larger blob is rejected unread.
    public static let maxInputBytes = 40 * 1024 * 1024
    /// The maximum accepted source resolution (64 megapixels).
    public static let maxPixels = 64_000_000
    /// Anything larger than this on the long side is downsampled to it on decode.
    public static let maxLongSide = 4096

    /// Why an untrusted image could not be ingested (a toast in the UI; never a trap).
    public enum Failure: Error, Sendable, Equatable {
        case tooLarge          // input bytes over `maxInputBytes`
        case tooManyPixels     // source over `maxPixels`
        case undecodable       // not a decodable image
    }

    /// What to do with a source of `pixelWidth` × `pixelHeight` from `inputBytes` of
    /// input: reject it, decode it downsampled, or decode it in full.
    public enum Decision: Sendable, Equatable {
        case reject(Failure)
        case downsample
        case full
    }

    /// The §8 cap decision, split out from the ImageIO decode so the ceilings are
    /// unit-tested without materialising a 64-megapixel image: reject input over
    /// `maxInputBytes` or a source over `maxPixels` (or a non-positive size), else
    /// downsample when the long side exceeds `maxLongSide`, else decode in full. The
    /// pixel product is computed in 64-bit so a hostile dimension pair never overflows.
    public static func decision(inputBytes: Int, pixelWidth: Int, pixelHeight: Int) -> Decision {
        if inputBytes > maxInputBytes { return .reject(.tooLarge) }
        guard pixelWidth > 0, pixelHeight > 0 else { return .reject(.undecodable) }
        guard Int64(pixelWidth) * Int64(pixelHeight) <= Int64(maxPixels) else { return .reject(.tooManyPixels) }
        return max(pixelWidth, pixelHeight) > maxLongSide ? .downsample : .full
    }

    /// Decodes `data` to a pixels-only `CGImage` or a typed `Failure`. Reads the source
    /// pixel dimensions from the image properties BEFORE decoding, so an over-cap image
    /// is rejected without materialising it (`decision`); an over-`maxLongSide` image
    /// decodes through a thumbnail bounded to `maxLongSide`
    /// (`kCGImageSourceThumbnailMaxPixelSize`).
    public static func decode(_ data: Data) -> Result<CGImage, Failure> {
        guard data.count <= maxInputBytes else { return .failure(.tooLarge) }
        let baseOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, baseOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return .failure(.undecodable) }

        switch decision(inputBytes: data.count, pixelWidth: width, pixelHeight: height) {
        case .reject(let failure):
            return .failure(failure)
        case .downsample:
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
                kCGImageSourceShouldCache: false,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return .failure(.undecodable)
            }
            return .success(cg)
        case .full:
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, baseOptions as CFDictionary) else {
                return .failure(.undecodable)
            }
            return .success(cg)
        }
    }
}
