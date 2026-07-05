import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The hand-rolled snapshot comparator (locked toolchain decision, primer §2):
/// CGImage vs committed PNG baseline, exact dimension match, per-channel
/// tolerance plus a max-differing-pixel-fraction budget. Failures write
/// actual/expected/diff PNGs into `.build/emfy-snapshot-artifacts/<test>/`
/// and name that path in the failure message.
enum SnapshotComparator {

    /// Per-channel tolerance: a pixel differs when any RGBA channel deviates
    /// by more than this.
    static let defaultTolerance: UInt8 = 16
    /// Budget of differing pixels as a fraction of the total.
    static let defaultMaxDifferingFraction = 0.01

    /// Verifies `image` against the baseline PNG named `name`.
    ///
    /// Returns `nil` on a pass, or a human-readable failure message. In
    /// record mode (`EMFY_RECORD=1`) the image is written as the new baseline
    /// into the SOURCE tree and a deliberate failure message is returned so a
    /// recording run can never masquerade as green.
    static func verify(
        _ image: CGImage,
        baselineNamed name: String,
        tolerance: UInt8 = defaultTolerance,
        maxDifferingFraction: Double = defaultMaxDifferingFraction
    ) -> String? {
        if isRecordingBaselines {
            return record(image, name: name)
        }

        guard let baselineURL = Bundle.module.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "__Baselines__"
        ) else {
            return "no baseline named \(name).png in the test bundle — record one with EMFY_RECORD=1 swift test"
        }
        guard let source = CGImageSourceCreateWithURL(baselineURL as CFURL, nil),
              let baseline = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return "baseline \(name).png exists but did not decode as an image"
        }

        // Dimensions must match exactly — a size change is always a real
        // rendering change, never tolerable drift.
        guard image.width == baseline.width, image.height == baseline.height else {
            let artifactPath = writeArtifacts(name: name, actual: image, expected: baseline, diff: nil)
            return "size mismatch: rendered \(image.width)×\(image.height), baseline "
                + "\(baseline.width)×\(baseline.height); artifacts at \(artifactPath)"
        }

        guard let actualPixels = RasterizedImage(image),
              let expectedPixels = RasterizedImage(baseline)
        else {
            return "could not rasterize images for comparison"
        }

        var differing = 0
        var diffPixels = [UInt8](repeating: 255, count: actualPixels.pixels.count)
        let count = actualPixels.pixels.count / 4
        for pixel in 0 ..< count {
            let offset = pixel * 4
            var pixelDiffers = false
            for channel in 0 ..< 4 {
                let a = Int(actualPixels.pixels[offset + channel])
                let b = Int(expectedPixels.pixels[offset + channel])
                if abs(a - b) > Int(tolerance) {
                    pixelDiffers = true
                    break
                }
            }
            if pixelDiffers {
                differing += 1
                diffPixels[offset] = 255      // red marker
                diffPixels[offset + 1] = 0
                diffPixels[offset + 2] = 0
                diffPixels[offset + 3] = 255
            }
        }

        let fraction = Double(differing) / Double(max(count, 1))
        guard fraction > maxDifferingFraction else { return nil }

        let diffImage = makeImage(
            rgba: diffPixels,
            width: actualPixels.width,
            height: actualPixels.height
        )
        let artifactPath = writeArtifacts(name: name, actual: image, expected: baseline, diff: diffImage)
        return String(
            format: "snapshot mismatch for %@: %.2f%% of pixels differ (budget %.2f%%, tolerance %d/255); artifacts at %@",
            name, fraction * 100, maxDifferingFraction * 100, Int(tolerance), artifactPath
        )
    }

    // MARK: - Recording

    private static func record(_ image: CGImage, name: String) -> String {
        let directory = TestPaths.baselineSourceDirectory
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "EMFY_RECORD: could not create \(directory.path): \(error)"
        }
        guard writePNG(image, to: url) else {
            return "EMFY_RECORD: could not write \(url.path)"
        }
        return "recorded baseline \(name).png — re-run without EMFY_RECORD to compare"
    }

    // MARK: - Artifacts

    /// Writes actual/expected(/diff) PNGs and returns the directory path for
    /// the failure message. Write problems degrade to a note in the returned
    /// path — artifact IO must never mask the real assertion.
    private static func writeArtifacts(
        name: String,
        actual: CGImage,
        expected: CGImage,
        diff: CGImage?
    ) -> String {
        let directory = TestPaths.artifactsDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "(artifact directory not writable: \(error))"
        }
        var allWritten = writePNG(actual, to: directory.appendingPathComponent("actual.png"))
        allWritten = writePNG(expected, to: directory.appendingPathComponent("expected.png")) && allWritten
        if let diff {
            allWritten = writePNG(diff, to: directory.appendingPathComponent("diff.png")) && allWritten
        }
        return directory.path + (allWritten ? "" : " (some artifacts failed to write)")
    }

    // MARK: - PNG IO

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// A CGImage over straight RGBA8 bytes (diff visualisation).
    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgba.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = rgba
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
    }
}
