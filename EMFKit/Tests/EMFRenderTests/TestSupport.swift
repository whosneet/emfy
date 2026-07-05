import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Filesystem anchors for corpus files, baselines, and failure artifacts.
///
/// FRAGILITY NOTE: all three locations are derived from `#filePath`, i.e.
/// from this source file's location at COMPILE time
/// (`<repo>/EMFKit/Tests/EMFRenderTests/`). Moving this file, renaming the
/// test directory, or building from a copied source tree without the
/// sibling `corpus/` directory breaks the lookup. SPM offers no supported
/// way to reference files outside the package, so this is the agreed
/// trade-off; the guard messages make a broken anchor obvious.
enum TestPaths {
    /// `<repo>/EMFKit/Tests/EMFRenderTests`
    static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `<repo>` — three levels above the test directory.
    static var repositoryRoot: URL {
        testsDirectory
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // EMFKit
            .deletingLastPathComponent()   // repo root
    }

    /// `<repo>/corpus/<name>`
    static func corpusFile(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent("corpus").appendingPathComponent(name)
    }

    /// The SOURCE baselines directory (where EMFY_RECORD=1 writes); the test
    /// bundle carries a copy of it as a resource.
    static var baselineSourceDirectory: URL {
        testsDirectory.appendingPathComponent("__Baselines__")
    }

    /// `<repo>/EMFKit/.build/emfy-snapshot-artifacts`
    static var artifactsDirectory: URL {
        testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build")
            .appendingPathComponent("emfy-snapshot-artifacts")
    }
}

/// True when the run should (re-)record snapshot baselines instead of
/// comparing against them.
var isRecordingBaselines: Bool {
    ProcessInfo.processInfo.environment["EMFY_RECORD"] == "1"
}

/// Parses a corpus EMF file.
func parseCorpusFile(_ name: String) throws -> EMFFile {
    let url = TestPaths.corpusFile(name)
    let data = try #require(
        try? Data(contentsOf: url),
        "corpus file not readable at \(url.path) — see TestPaths fragility note"
    )
    return try EMFFile.parse(data)
}

/// A CGImage decoded into straight RGBA8 bytes for pixel probing. Row 0 is
/// the TOP of the image, matching device-space y-down (EMFRenderer's canvas
/// flip maps device top to bitmap row 0).
struct RasterizedImage {
    let width: Int
    let height: Int
    /// RGBA, 4 bytes per pixel, `width * 4` bytes per row.
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
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
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The RGBA channels at image coordinates (x, y), y from the top.
    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "probe out of bounds")
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// True if any pixel in the (clamped) rectangle has a red channel below
    /// `threshold` — a cheap "did some dark ink land here" probe robust to
    /// antialiasing.
    func containsDarkPixel(
        in rect: (x: Int, y: Int, width: Int, height: Int),
        threshold: UInt8 = 200
    ) -> Bool {
        contains(in: rect) { $0.r < threshold }
    }

    /// True if any pixel in the (clamped) rectangle is dominantly blue (high
    /// blue, low red and green) — a "blue ink landed here" probe robust to
    /// antialiasing against a white background or red fill.
    func containsBluePixel(
        in rect: (x: Int, y: Int, width: Int, height: Int)
    ) -> Bool {
        contains(in: rect) { $0.b > 160 && $0.r < 120 && $0.g < 120 }
    }

    /// True if any pixel in the (clamped) rectangle satisfies `predicate`.
    func contains(
        in rect: (x: Int, y: Int, width: Int, height: Int),
        where predicate: ((r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool
    ) -> Bool {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return false }
        for y in y0 ..< y1 {
            for x in x0 ..< x1 where predicate(self[x, y]) {
                return true
            }
        }
        return false
    }
}
