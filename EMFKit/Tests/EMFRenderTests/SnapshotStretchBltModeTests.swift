// Snapshot baselines are macOS-only; gated like the phase gates.
#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// R1 render coverage for EMR_SETSTRETCHBLTMODE (21). It affects interpolation
/// QUALITY only: a 2×2 checkerboard magnified to 80×80 renders as hard blocks
/// under the default BLACKONWHITE, and smoothly interpolated under HALFTONE.
/// The differential test proves the mode changed the pixels; the snapshot pins
/// the HALFTONE (smoothed) output.
@Suite("SETSTRETCHBLTMODE render")
struct SnapshotStretchBltModeTests {

    /// A 2×2 24-bit BI_RGB checkerboard (bottom-up): black/white, white/black.
    /// Row order on disk is bottom row first; each row padded to a 4-byte stride.
    private static let checkerBits: [UInt8] = [
        // bottom row: white, black  (B,G,R per pixel, then 2 pad bytes)
        255, 255, 255,  0, 0, 0,  0, 0,
        // top row: black, white
        0, 0, 0,  255, 255, 255,  0, 0,
    ]

    private static func render(halftone: Bool) throws -> CGImage {
        var f = RenderFixture()
        f.bounds = (0, 0, 99, 99)
        if halftone { f.setStretchBltMode(4) }   // HALFTONE
        f.stretchDIBits(
            bounds: (0, 0, 2, 2),
            dest: (x: 10, y: 10),
            destSize: (cx: 80, cy: 80),       // magnify 2×2 → 80×80
            src: (x: 0, y: 0),
            srcSize: (cx: 2, cy: 2),
            bmi: RenderFixture.bitmapInfoHeader(width: 2, height: 2, bitCount: 24),
            bits: checkerBits
        )
        return try #require(EMFRenderer.makeImage(f.parsed())?.0, "makeImage returned nil")
    }

    @Test("HALFTONE interpolates where the default BLACKONWHITE keeps hard blocks")
    func halftoneDiffersFromDefault() throws {
        let plain = try #require(RasterizedImage(try Self.render(halftone: false)))
        let smooth = try #require(RasterizedImage(try Self.render(halftone: true)))
        // Count pixels that differ by more than a channel of noise: a non-trivial
        // count proves HALFTONE changed the resample (nearest → interpolated).
        var differing = 0
        let n = plain.pixels.count
        for i in stride(from: 0, to: n, by: 4) where abs(Int(plain.pixels[i]) - Int(smooth.pixels[i])) > 8 {
            differing += 1
        }
        #expect(differing > 200, "HALFTONE made no visible difference (\(differing) px)")
    }

    @Test("HALFTONE magnified checkerboard matches the accepted baseline")
    func halftoneSnapshot() throws {
        let image = try Self.render(halftone: true)
        let failure = SnapshotComparator.verify(image, baselineNamed: "r1-stretchbltmode-halftone")
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }
}
#endif
