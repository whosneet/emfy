import CoreGraphics
import Foundation
import Testing

/// Filesystem anchors for corpus files, derived from `#filePath` at compile time
/// (`<repo>/EMFKit/Tests/EMFEditTests/`). Same fragility trade-off as the
/// EMFRenderTests anchor: SPM has no supported way to reference files outside the
/// package, and the guard messages make a broken anchor obvious.
enum EditTestPaths {
    static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
    static var repositoryRoot: URL {
        testsDirectory
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // EMFKit
            .deletingLastPathComponent()   // repo root
    }
    static var corpusDirectory: URL {
        repositoryRoot.appendingPathComponent("corpus")
    }
    static var corpusLocalDirectory: URL {
        repositoryRoot.appendingPathComponent("corpus-local")
    }

    /// Every committed metafile in `corpus/`, sorted by name.
    static func committedMetafiles() -> [URL] {
        metafiles(in: corpusDirectory, recursive: false)
    }

    /// Every metafile under `corpus-local/` (gitignored; may be absent),
    /// recursively. Work-sourced files are anonymised: callers report COUNTS
    /// only, never names.
    static func localMetafiles() -> [URL] {
        metafiles(in: corpusLocalDirectory, recursive: true)
    }

    private static let metafileExtensions: Set<String> = ["emf", "emz", "wmf", "wmz"]

    private static func metafiles(in directory: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = recursive
            ? fm.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL })
            : (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        else { return [] }
        return enumerator
            .filter { metafileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Decodes a CGImage into straight RGBA8 and compares two images for the
/// fidelity gate.
struct PixelImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// The result of comparing two renders (the scene vs the source).
struct ImageDiff {
    var sameSize: Bool
    var maxChannelDelta: Int
    var differingFraction: Double
    var meanDelta: Double
}

/// Compares two CGImages channel-by-channel (RGBA8). A pixel "differs" when any
/// channel deviates by more than `tolerance`.
func compareImages(_ a: CGImage, _ b: CGImage, tolerance: Int = 16) -> ImageDiff {
    guard let pa = PixelImage(a), let pb = PixelImage(b) else {
        return ImageDiff(sameSize: false, maxChannelDelta: 255, differingFraction: 1, meanDelta: 255)
    }
    guard pa.width == pb.width, pa.height == pb.height else {
        return ImageDiff(sameSize: false, maxChannelDelta: 255, differingFraction: 1, meanDelta: 255)
    }
    var differing = 0
    var maxDelta = 0
    var totalDelta = 0
    let pixelCount = pa.pixels.count / 4
    for pixel in 0 ..< pixelCount {
        let offset = pixel * 4
        var pixelDiffers = false
        for channel in 0 ..< 4 {
            let delta = abs(Int(pa.pixels[offset + channel]) - Int(pb.pixels[offset + channel]))
            totalDelta += delta
            maxDelta = max(maxDelta, delta)
            if delta > tolerance { pixelDiffers = true }
        }
        if pixelDiffers { differing += 1 }
    }
    return ImageDiff(
        sameSize: true,
        maxChannelDelta: maxDelta,
        differingFraction: Double(differing) / Double(max(pixelCount, 1)),
        meanDelta: Double(totalDelta) / Double(max(pixelCount * 4, 1))
    )
}
