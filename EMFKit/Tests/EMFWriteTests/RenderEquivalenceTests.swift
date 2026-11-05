import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import EMFParse
import EMFRender
import EMFWrite
import WMFParse

// E0d render-equivalence gate (v3 plan §11.2): parse → write → parse proves an
// EQUAL record stream (E0a–c); this slice proves "write → render matches the
// original render within snapshot tolerance, across the corpus". Every writer
// surface (`reEmit`, `reEmit(repackageEMFPlus:)`, the from-scratch
// `EMFDocumentBuilder` rewrite, `WMFDocumentWriter.reEmit`, and the `GzipWriter`
// .wmz round trip) must drive the SAME pixels as the original file through the
// one renderer the app and Quick Look use (`MetafileRenderer`).
//
// The comparator is the project's locked model (toolchain decision, primer §2):
// a per-channel tolerance plus a max-differing-pixel-fraction budget, with a
// whole-image mean-delta guard. It lives here (a small equivalent of
// EMFRenderTests' `SnapshotComparator`) because that type is in a different test
// target; unlike snapshots it compares two freshly rendered images directly, so
// no PNG baseline is committed. Failures on COMMITTED files write side-by-side
// artefacts and name the file; corpus-local files are CONFIDENTIAL and reported
// as counts only, never named.

// MARK: - Render + compare support

/// A straight-RGBA8 view of a CGImage (row 0 = top), for pixel-level diffing.
private struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt8]   // RGBA, 4 bytes/pixel, width*4 bytes/row

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.width = w
        self.height = h
        self.pixels = buffer
    }
}

/// The outcome of comparing two rendered images.
struct RenderComparison {
    let sizeMatch: Bool
    let maxChannelDelta: Int
    let differingPixels: Int
    let totalPixels: Int
    let meanDelta: Double

    var differingFraction: Double { totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels) }
    /// Pixel-identical: same dimensions and not a single channel moved.
    var identical: Bool { sizeMatch && maxChannelDelta == 0 }

    /// Within the locked snapshot tolerance (per-channel 16/255, ≤ 1% of pixels
    /// differing, mean per-channel Δ ≤ 2.0) — the same budget the snapshot
    /// comparator passes a rendering change at.
    func withinTolerance(
        tolerance: Int = 16, maxFraction: Double = 0.01, meanTolerance: Double = 2.0
    ) -> Bool {
        sizeMatch && maxChannelDelta <= tolerance
            || (sizeMatch && differingFraction <= maxFraction && meanDelta <= meanTolerance)
    }

    var summary: String {
        guard sizeMatch else { return "SIZE-MISMATCH" }
        if identical { return "identical" }
        return String(format: "maxΔ=%d, %.3f%% px, meanΔ=%.3f",
                      maxChannelDelta, differingFraction * 100, meanDelta)
    }
}

enum RenderEquivalence {

    /// The per-channel tolerance a pixel must exceed to count as "differing"
    /// (matches `SnapshotComparator.defaultTolerance`).
    static let tolerance = 16

    /// Renders `data` through `MetafileRenderer` — the single door the app and
    /// Quick Look use — on an opaque white page, scaled so the longer side is at
    /// most `maxSide` (never upscaled). `nil` for an unreadable input.
    static func render(_ data: Data, maxSide: Int) -> CGImage? {
        guard let opened = try? OpenedMetafile.open(data),
              let prepared = MetafileRenderer.prepare(opened) else { return nil }
        let longest = max(prepared.naturalSize.width, prepared.naturalSize.height, 1)
        let scale = min(1.0, Double(maxSide) / Double(longest))
        return MetafileRenderer.makeImage(prepared, scale: CGFloat(scale), background: .white)?.0
    }

    /// Compares two rendered images per channel. Different dimensions are a hard
    /// fail (a size change is never tolerable drift).
    static func compare(_ a: CGImage, _ b: CGImage) -> RenderComparison {
        guard let ra = Raster(a), let rb = Raster(b) else {
            return RenderComparison(sizeMatch: false, maxChannelDelta: 255,
                                    differingPixels: 0, totalPixels: 0, meanDelta: 255)
        }
        guard ra.width == rb.width, ra.height == rb.height else {
            return RenderComparison(sizeMatch: false, maxChannelDelta: 255,
                                    differingPixels: 0, totalPixels: 0, meanDelta: 255)
        }
        let count = ra.pixels.count / 4
        var maxDelta = 0
        var differing = 0
        var totalDelta = 0
        for pixel in 0 ..< count {
            let o = pixel * 4
            var pixelDiffers = false
            for channel in 0 ..< 4 {
                let delta = abs(Int(ra.pixels[o + channel]) - Int(rb.pixels[o + channel]))
                totalDelta += delta
                if delta > maxDelta { maxDelta = delta }
                if delta > tolerance { pixelDiffers = true }
            }
            if pixelDiffers { differing += 1 }
        }
        let mean = Double(totalDelta) / Double(max(count * 4, 1))
        return RenderComparison(sizeMatch: true, maxChannelDelta: maxDelta,
                                differingPixels: differing, totalPixels: count, meanDelta: mean)
    }

    /// Rebuilds `file` from scratch through `EMFDocumentBuilder`, preserving the
    /// original header geometry and feeding every body record back: a faithfully
    /// encodable payload typed, an unencodable one as raw passthrough bytes (the
    /// same split `reEmit` makes). The builder owns the header and the trailing
    /// EMR_EOF, so the source header and any EMR_EOF are skipped.
    static func builderRewrite(of file: EMFFile, source: Data) throws -> Data {
        let builder = EMFDocumentBuilder(
            bounds: file.header.bounds, frame: file.header.frame,
            device: file.header.device, millimeters: file.header.millimeters,
            description: file.header.description)
        let src = [UInt8](source)
        guard file.records.count > 1 else { return try builder.finish() }
        for index in 1 ..< file.records.count {
            let record = file.records[index]
            if record.type == 14 { continue }   // EMR_EOF — the builder emits its own
            let payload = file.payload(of: record)
            if EMFRecordEncoder.isFaithfullyEncodable(payload) {
                try builder.append(payload)
            } else {
                let start = record.offset, size = Int(record.size)
                guard start >= 0, size >= 0, size <= src.count, start <= src.count - size else {
                    throw RewriteError.sourceOutOfBounds(offset: start, size: record.size)
                }
                builder.appendRaw(Array(src[start ..< start + size]))
            }
        }
        return try builder.finish()
    }

    enum RewriteError: Error { case sourceOutOfBounds(offset: Int, size: UInt32) }

    // MARK: - Artefacts (committed files only — names are safe there)

    /// `<repo>/EMFKit/.build/emfy-write-artifacts/<name>/`.
    static func artifactsDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EMFWriteTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent(".build")
            .appendingPathComponent("emfy-write-artifacts")
            .appendingPathComponent(name)
    }

    /// Writes actual/expected PNGs for a committed-file failure; returns the path
    /// for the message. Never called for corpus-local files (they are confidential).
    @discardableResult
    static func writeArtifacts(name: String, actual: CGImage, expected: CGImage) -> String {
        let dir = artifactsDirectory(name)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return "(artifact dir not writable)" }
        _ = writePNG(actual, to: dir.appendingPathComponent("actual.png"))
        _ = writePNG(expected, to: dir.appendingPathComponent("expected.png"))
        return dir.path
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

// (`committedWMFCorpus()` and `corpusLocalFiles()` live in the shared test
// support files `WMFWriteTestSupport` and `WriteTestSupport`.)

// MARK: - Committed EMF/EMZ render equivalence

@Suite("Render equivalence — committed EMF/EMZ corpus")
struct EMFRenderEquivalenceTests {

    static let maxSide = 512

    @Test func committedEMFFamilyRendersEquivalently() throws {
        print("[render-eq EMF] file | reEmit | repackage | builder-rewrite")
        for name in committedEMFCorpus() {
            let raw = try corpusData(name)
            let emf = try OpenedMetafile.open(raw).data
            let file = try EMFFile.parse(emf)
            let hasPlus = !file.emfPlusStream().records.isEmpty

            let original = try #require(RenderEquivalence.render(emf, maxSide: Self.maxSide),
                                        "\(name): original did not render")

            // (1) typed re-emit — must be pixel-identical.
            let reEmitted = try EMFDocumentWriter.reEmit(file, source: emf)
            let reEmitImg = try #require(RenderEquivalence.render(reEmitted, maxSide: Self.maxSide),
                                         "\(name): reEmit did not render")
            let reEmitCmp = RenderEquivalence.compare(original, reEmitImg)
            if !reEmitCmp.identical {
                let path = RenderEquivalence.writeArtifacts(name: "\(name).reemit", actual: reEmitImg, expected: original)
                Issue.record("\(name): reEmit render differs (\(reEmitCmp.summary)); artefacts at \(path)")
            }

            // (2) repackage EMF+ — only where there is EMF+ content; pixel-identical.
            var repackageSummary = "n/a"
            if hasPlus {
                let repackaged = try EMFDocumentWriter.reEmit(file, source: emf, repackageEMFPlus: true)
                let repackImg = try #require(RenderEquivalence.render(repackaged, maxSide: Self.maxSide),
                                             "\(name): repackage did not render")
                let repackCmp = RenderEquivalence.compare(original, repackImg)
                repackageSummary = repackCmp.summary
                if !repackCmp.identical {
                    let path = RenderEquivalence.writeArtifacts(name: "\(name).repackage", actual: repackImg, expected: original)
                    Issue.record("\(name): repackage render differs (\(repackCmp.summary)); artefacts at \(path)")
                }
            }

            // (3) from-scratch builder rewrite — pixel-identical or within tolerance.
            let rebuilt = try RenderEquivalence.builderRewrite(of: file, source: emf)
            let rebuiltImg = try #require(RenderEquivalence.render(rebuilt, maxSide: Self.maxSide),
                                          "\(name): builder rewrite did not render")
            let rebuiltCmp = RenderEquivalence.compare(original, rebuiltImg)
            if !rebuiltCmp.withinTolerance() {
                let path = RenderEquivalence.writeArtifacts(name: "\(name).builder", actual: rebuiltImg, expected: original)
                Issue.record("\(name): builder rewrite render out of tolerance (\(rebuiltCmp.summary)); artefacts at \(path)")
            }

            print("[render-eq EMF] \(name) | \(reEmitCmp.summary) | \(repackageSummary) | \(rebuiltCmp.summary)")
        }
    }
}

// MARK: - Committed WMF/WMZ render equivalence

@Suite("Render equivalence — committed WMF/WMZ corpus")
struct WMFRenderEquivalenceTests {

    static let maxSide = 512

    @Test func committedWMFFamilyRendersEquivalently() throws {
        print("[render-eq WMF] file | reEmit | wmz-roundtrip")
        for name in committedWMFCorpus() {
            let raw = try corpusData(name)
            let wmf = try OpenedMetafile.open(raw).data
            let file = try WMFFile.parse(wmf)

            let original = try #require(RenderEquivalence.render(wmf, maxSide: Self.maxSide),
                                        "\(name): original did not render")

            // (1) WMF re-emit — pixel-identical.
            let reEmitted = try WMFDocumentWriter.reEmit(file, source: wmf)
            let reEmitImg = try #require(RenderEquivalence.render(reEmitted, maxSide: Self.maxSide),
                                         "\(name): reEmit did not render")
            let reEmitCmp = RenderEquivalence.compare(original, reEmitImg)
            if !reEmitCmp.identical {
                let path = RenderEquivalence.writeArtifacts(name: "\(name).reemit", actual: reEmitImg, expected: original)
                Issue.record("\(name): WMF reEmit render differs (\(reEmitCmp.summary)); artefacts at \(path)")
            }

            // (2) WMZ round trip through GzipWriter — inflate then render; pixel-identical.
            let wmz = GzipWriter.compress(reEmitted)
            let wmzImg = try #require(RenderEquivalence.render(wmz, maxSide: Self.maxSide),
                                      "\(name): wmz round trip did not render")
            let wmzCmp = RenderEquivalence.compare(original, wmzImg)
            if !wmzCmp.identical {
                let path = RenderEquivalence.writeArtifacts(name: "\(name).wmz", actual: wmzImg, expected: original)
                Issue.record("\(name): wmz round-trip render differs (\(wmzCmp.summary)); artefacts at \(path)")
            }

            print("[render-eq WMF] \(name) | \(reEmitCmp.summary) | \(wmzCmp.summary)")
        }
    }
}

// MARK: - corpus-local render equivalence (COUNTS ONLY — never named)

@Suite("Render equivalence — corpus-local (counts only)")
struct CorpusLocalRenderEquivalenceTests {

    /// Aggressive render cap: there are a couple hundred files (two very large),
    /// and canvas size, not record count, is the per-file lever (§7).
    static let maxSide = 160

    /// corpus-local/ is gitignored and may be absent; work-sourced files there are
    /// CONFIDENTIAL. Every parseable file's original render must match its reEmit
    /// render pixel-for-pixel (or within tolerance). Results are reported as COUNTS
    /// ONLY — no names, no content, failures by index and cause.
    @Test func corpusLocalReEmitRendersEquivalently() throws {
        let files = corpusLocalFiles()
        let clock = ContinuousClock()
        let start = clock.now

        var rendered = 0, identical = 0, withinTolerance = 0, failed = 0
        for (index, url) in files.enumerated() {
            guard let raw = try? Data(contentsOf: url),
                  let emf = try? OpenedMetafile.open(raw).data,
                  let file = try? EMFFile.parse(emf),
                  let written = try? EMFDocumentWriter.reEmit(file, source: emf),
                  let originalImg = RenderEquivalence.render(emf, maxSide: Self.maxSide),
                  let writtenImg = RenderEquivalence.render(written, maxSide: Self.maxSide)
            else { continue }
            rendered += 1
            let cmp = RenderEquivalence.compare(originalImg, writtenImg)
            if cmp.identical {
                identical += 1
            } else if cmp.withinTolerance() {
                withinTolerance += 1
                print("[corpus-local] index \(index): within tolerance only (\(cmp.summary))")
            } else {
                failed += 1
                // By INDEX and cause only — never the name or any content.
                print("[corpus-local] index \(index): render DIFFERS (\(cmp.summary))")
            }
        }
        let elapsed = clock.now - start
        print("[corpus-local] present: \(files.count), rendered: \(rendered), "
              + "identical: \(identical), within-tolerance: \(withinTolerance), failed: \(failed), "
              + "runtime: \(elapsed)")
        // Every rendered file must match within tolerance; identical is the norm.
        #expect(failed == 0)
    }
}

// MARK: - Performance (write cost on the largest inputs)

@Suite("Write performance — reEmit and builder rewrite")
struct WritePerformanceTests {

    /// Times `reEmit` and the builder rewrite on the largest committed file and
    /// (when present) the largest corpus-local file. Reports ms and a rough RSS
    /// delta; corpus-local is reported by SIZE only, never named.
    @Test func largestInputsTiming() throws {
        if let largestCommitted = largestEMF(committedURLs()) {
            report(label: "largest committed", url: largestCommitted, named: true)
        }
        if let largestLocal = largestEMF(corpusLocalFiles()) {
            report(label: "largest corpus-local", url: largestLocal, named: false)
        }
    }

    private func committedURLs() -> [URL] {
        committedEMFCorpus().map {
            repoRootURL().appendingPathComponent("corpus").appendingPathComponent($0)
        }
    }

    private func largestEMF(_ urls: [URL]) -> URL? {
        urls.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    private func report(label: String, url: URL, named: Bool) {
        guard let raw = try? Data(contentsOf: url),
              let emf = try? OpenedMetafile.open(raw).data,
              let file = try? EMFFile.parse(emf) else { return }
        let who = named ? url.lastPathComponent : "size \(emf.count) bytes"
        let clock = ContinuousClock()

        let rssBefore = residentBytes()
        let reEmitStart = clock.now
        let written = (try? EMFDocumentWriter.reEmit(file, source: emf))
        let reEmitMs = (clock.now - reEmitStart).milliseconds

        let builderStart = clock.now
        let rebuilt = try? RenderEquivalence.builderRewrite(of: file, source: emf)
        let builderMs = (clock.now - builderStart).milliseconds
        let rssAfter = residentBytes()

        print(String(format: "[perf] %@ (%@): reEmit %.1f ms → %d B, builder-rewrite %.1f ms → %d B, RSS Δ %+d KB",
                     label, who, reEmitMs, written?.count ?? -1, builderMs, rebuilt?.count ?? -1,
                     (rssAfter - rssBefore) / 1024))
    }

    /// Resident memory in bytes (mach task info); 0 if unavailable.
    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}

private extension Duration {
    var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1_000_000_000_000_000
    }
}
