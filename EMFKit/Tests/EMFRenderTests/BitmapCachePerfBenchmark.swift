import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// A P2 performance harness, NOT part of the gate: both tests are no-ops unless
/// their environment switch is set, so the normal suite neither times nor
/// touches the filesystem. Run locally, in Release, to produce the before/after
/// table and to (re)generate the committed synthetic DIB corpus file.
///
/// Generate the 1 MiB-DIB corpus file (once; the file is committed):
///   EMFY_GENERATE_BIGDIB=1 swift test -c release --no-parallel \
///     --scratch-path <dir> --filter generateBigDIBCorpusFile
///
/// Benchmark (committed synthetic file always; extra files via a colon-separated
/// list of absolute paths in EMFY_BENCH_FILES, labelled by basename or by the
/// paired EMFY_BENCH_LABELS list so a confidential file is reported by label):
///   EMFY_BENCH=1 EMFY_BENCH_FILES=/abs/a.emf:/abs/b.emf \
///   EMFY_BENCH_LABELS=WS-B:libemf2svg-176 \
///     swift test -c release --no-parallel --scratch-path <dir> \
///     --filter bitmapCacheBeforeAfter
@Suite("Bitmap cache performance (manual)")
struct BitmapCachePerfBenchmark {

    /// The committed synthetic target: a 512×512 32-bpp DIB (exactly 1 MiB of
    /// pixels) blitted 1:1 over a 512×512 page.
    static let syntheticName = "gate-p2-bigdib.emf"
    private static let dibSide: Int32 = 512

    // MARK: - Corpus generation

    @Test("generate the committed 1 MiB-DIB corpus file")
    func generateBigDIBCorpusFile() throws {
        guard ProcessInfo.processInfo.environment["EMFY_GENERATE_BIGDIB"] == "1" else { return }
        let side = Self.dibSide
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, side - 1, side - 1)
        // 32-bpp BI_RGB pixels: a deterministic B,G,R,X pattern (self-generated,
        // CC0 — a smooth two-axis gradient), 512×512×4 = 1,048,576 bytes.
        var bits = [UInt8](repeating: 0, count: Int(side) * Int(side) * 4)
        var o = 0
        for y in 0 ..< Int(side) {
            for x in 0 ..< Int(side) {
                bits[o] = UInt8(x & 0xFF)             // B
                bits[o + 1] = UInt8(y & 0xFF)         // G
                bits[o + 2] = UInt8((x ^ y) & 0xFF)   // R
                bits[o + 3] = 0                        // X
                o += 4
            }
        }
        fixture.stretchDIBits(
            bounds: (0, 0, side - 1, side - 1),
            dest: (x: 0, y: 0),
            destSize: (cx: side, cy: side),
            src: (0, 0),
            srcSize: (cx: side, cy: side),
            bmi: RenderFixture.bitmapInfoHeader(width: side, height: side, bitCount: 32, colorUsed: 0),
            bits: bits
        )
        let data = fixture.data()
        let url = TestPaths.corpusFile(Self.syntheticName)
        try data.write(to: url)
        print("[bench] wrote \(url.path) (\(data.count) bytes, DIB payload \(bits.count) bytes)")
        // Sanity: it parses and renders.
        let file = try EMFFile.parse(data)
        #expect(EMFRenderer.makeImage(file)?.0 != nil)
    }

    /// A long render loop over one file (EMFY_BENCH_SAMPLE=/abs/path), so an
    /// external `sample <pid>` can show where EMF+ playback spends its time.
    @Test("sampling loop for an external profiler")
    func samplingLoop() throws {
        guard let path = ProcessInfo.processInfo.environment["EMFY_BENCH_SAMPLE"] else {
            return   // no-op unless asked
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try EMFFile.parse(data)
        let b = file.header.bounds
        let devW = Double(max(1, Int(b.right) - Int(b.left) + 1))
        let devH = Double(max(1, Int(b.bottom) - Int(b.top) + 1))
        let (pageW, pageH) = EMFRenderer.canvasPixelSize(deviceWidth: devW, deviceHeight: devH, scale: 1)
        let target = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        if ProcessInfo.processInfo.environment["EMFY_BENCH_HISTOGRAM"] == "1" {
            let stream = file.emfPlusStream()
            var hist: [UInt16: Int] = [:]
            for r in stream.records { hist[r.type, default: 0] += 1 }
            print("[bench] EMF+ records: \(stream.records.count), drawing: \(stream.records.filter(\.isDrawing).count)")
            for (type, n) in hist.sorted(by: { $0.value > $1.value }).prefix(20) {
                print(String(format: "[bench]   %@ : %d", EMFPlusRecordType.displayName(for: type), n))
            }
            return
        }
        let seconds = Double(ProcessInfo.processInfo.environment["EMFY_BENCH_SAMPLE_SECONDS"] ?? "") ?? 20
        let deadline = Date().addingTimeInterval(seconds)
        var n = 0
        while Date() < deadline {
            let ctx = Self.makeContext(pageW, pageH)
            _ = EMFRenderer.render(file, into: ctx, target: target)
            n += 1
        }
        print("[bench] sampling loop rendered \(n) full pages in \(seconds)s")
    }

    // MARK: - Benchmark

    @Test("bitmap cache before/after (full-page + per-tile, uncached vs cached)")
    func bitmapCacheBeforeAfter() throws {
        guard ProcessInfo.processInfo.environment["EMFY_BENCH"] == "1" else { return }

        var targets: [(label: String, url: URL)] = [
            (label: Self.syntheticName, url: TestPaths.corpusFile(Self.syntheticName))
        ]
        let env = ProcessInfo.processInfo.environment
        if let list = env["EMFY_BENCH_FILES"], !list.isEmpty {
            let paths = list.split(separator: ":").map(String.init)
            let labels = (env["EMFY_BENCH_LABELS"]?.split(separator: ":").map(String.init)) ?? []
            for (i, path) in paths.enumerated() {
                let label = i < labels.count ? labels[i] : URL(fileURLWithPath: path).lastPathComponent
                targets.append((label: label, url: URL(fileURLWithPath: path)))
            }
        }

        print("")
        print("[bench] file | parse+stream ms | full-page ms (uncache/cache) | per-tile ms (uncache/cache) | peak MB")
        for target in targets {
            try runOne(label: target.label, url: target.url)
        }
    }

    // MARK: - P2b adaptive-tile + placeholder report

    /// The P2b before/after: the cost of a fit-to-window repaint and a 400% repaint
    /// with the historical 512 tile versus the adaptive tile, plus the placeholder
    /// (time-to-first-visible-content) render and the per-tile memory. Manual, not
    /// part of the gate.
    ///
    ///   EMFY_BENCH_P2B=1 EMFY_BENCH_FILES=/abs/a.emf:/abs/b.emf \
    ///   EMFY_BENCH_LABELS=WS-B:WS-A \
    ///     swift test -c release --no-parallel --scratch-path <dir> \
    ///     --filter adaptiveTileReport
    @Test("adaptive tile size + placeholder (P2b)")
    func adaptiveTileReport() throws {
        guard ProcessInfo.processInfo.environment["EMFY_BENCH_P2B"] == "1" else { return }

        var targets: [(label: String, url: URL)] = [
            (label: Self.syntheticName, url: TestPaths.corpusFile(Self.syntheticName))
        ]
        let env = ProcessInfo.processInfo.environment
        if let list = env["EMFY_BENCH_FILES"], !list.isEmpty {
            let paths = list.split(separator: ":").map(String.init)
            let labels = (env["EMFY_BENCH_LABELS"]?.split(separator: ":").map(String.init)) ?? []
            for (i, path) in paths.enumerated() {
                let label = i < labels.count ? labels[i] : URL(fileURLWithPath: path).lastPathComponent
                targets.append((label: label, url: URL(fileURLWithPath: path)))
            }
        }

        print("")
        print("[p2b] viewport \(Int(Self.viewportPt.width))x\(Int(Self.viewportPt.height)) pt @\(Int(Self.backingScale))x backing")
        print("[p2b] file | ops | tileSide | per-tile ms | fit: tiles 512->adaptive (ms) | 400%: tiles 512->adaptive (ms) | first-content(placeholder) ms | tileMem MB 512->adaptive | placeholder MB")
        for target in targets {
            try runP2B(label: target.label, url: target.url)
        }
    }

    private static let viewportPt = CGSize(width: 1512, height: 982)
    private static let backingScale: CGFloat = 2
    // Mirror of ZoomMath (the app layer EMFKit cannot import); kept in sync by hand.
    private static let largeTileOpThreshold = 50_000
    private static let defaultTileSide = 512
    private static let largeTileSide = 1024
    private static let maxPlaceholderLongEdge: CGFloat = 1536

    private func runP2B(label: String, url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            print("[p2b] \(label): NOT READABLE — skipped"); return
        }
        guard let file = try? EMFFile.parse(data) else {
            print("[p2b] \(label): parse failed — skipped"); return
        }

        let ops = file.records.count
        let expensive = ops >= Self.largeTileOpThreshold
        let tileSide = expensive ? Self.largeTileSide : Self.defaultTileSide

        // Natural device size (header bounds), as the viewer sizes the page.
        let b = file.header.bounds
        let devW = Double(max(1, Int(b.right) - Int(b.left) + 1))
        let devH = Double(max(1, Int(b.bottom) - Int(b.top) + 1))
        let (pageW, pageH) = EMFRenderer.canvasPixelSize(deviceWidth: devW, deviceHeight: devH, scale: 1)
        let fullTarget = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        // Per-tile cost (area-independent): render the whole stream clipped to one
        // tile. Confirm it barely moves between 512 and the adaptive side.
        let cols512 = max(1, Int(ceil(Double(pageW) / 512)))
        let perTile512 = tileAverage(file: file, target: fullTarget, tile: 512, cols: cols512, tiles: min(cols512 * max(1, Int(ceil(Double(pageH) / 512))), 4), cache: nil)
        let colsAd = max(1, Int(ceil(Double(pageW) / Double(tileSide))))
        let perTileAd = tileAverage(file: file, target: fullTarget, tile: tileSide, cols: colsAd, tiles: min(colsAd * max(1, Int(ceil(Double(pageH) / Double(tileSide)))), 4), cache: nil)

        // Fit: the page scaled to fit the viewport (keeping aspect), rasterised at
        // the backing scale. Tiles needed = grid over that fit-resolution page.
        let fitScale = min(
            (Self.viewportPt.width) / devW,
            (Self.viewportPt.height) / devH, 1)
        let fitPxW = devW * fitScale * Double(Self.backingScale)
        let fitPxH = devH * fitScale * Double(Self.backingScale)
        let fitTiles512 = tileGridCount(fitPxW, fitPxH, tile: 512)
        let fitTilesAd = tileGridCount(fitPxW, fitPxH, tile: tileSide)

        // 400%: the viewport shows a 4× crop, so visible tiles depend on the
        // viewport in device pixels, not the page size.
        let vpxW = Double(Self.viewportPt.width) * Double(Self.backingScale)
        let vpxH = Double(Self.viewportPt.height) * Double(Self.backingScale)
        let tiles400_512 = tileGridCount(vpxW, vpxH, tile: 512)
        let tiles400Ad = tileGridCount(vpxW, vpxH, tile: tileSide)

        // Time to first visible content: one placeholder render (area-capped).
        let longSide = max(devW, devH)
        let phScale: CGFloat = longSide > Double(Self.maxPlaceholderLongEdge)
            ? Self.maxPlaceholderLongEdge / CGFloat(longSide) : 1
        let before = Self.physFootprintMB()
        var placeholderMB = 0.0
        let placeholderMs = median(iterations: expensive ? 3 : 7) {
            let r = EMFRenderer.makeImage(file, scale: phScale, background: .white)
            if let img = r?.0 {
                placeholderMB = Double(img.bytesPerRow * img.height) / (1024 * 1024)
            }
        }
        _ = before

        // Per-tile backing memory (constant across zoom): tile px² at backing × 4 B.
        func tileMemMB(_ side: Int) -> Double {
            let px = Double(side) * Double(Self.backingScale)
            return px * px * 4 / (1024 * 1024)
        }

        print(String(
            format: "[p2b] %@ | %d | %d | %.1f/%.1f | %d->%d (%.0f->%.0f) | %d->%d (%.0f->%.0f) | %.1f | %.1f->%.1f | %.1f",
            label, ops, tileSide,
            perTile512, perTileAd,
            fitTiles512, fitTilesAd, Double(fitTiles512) * perTile512, Double(fitTilesAd) * perTileAd,
            tiles400_512, tiles400Ad, Double(tiles400_512) * perTile512, Double(tiles400Ad) * perTileAd,
            placeholderMs, tileMemMB(512), tileMemMB(tileSide), placeholderMB))
    }

    private func tileGridCount(_ w: Double, _ h: Double, tile: Int) -> Int {
        let cols = max(1, Int(ceil(w / Double(tile))))
        let rows = max(1, Int(ceil(h / Double(tile))))
        return cols * rows
    }

    private func runOne(label: String, url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            print("[bench] \(label): NOT READABLE at \(url.path) — skipped")
            return
        }
        guard let file = try? EMFFile.parse(data) else {
            print("[bench] \(label): parse failed — skipped")
            return
        }

        // Natural device size (header bounds), capped like the viewer canvas.
        let b = file.header.bounds
        let devW = Double(max(1, Int(b.right) - Int(b.left) + 1))
        let devH = Double(max(1, Int(b.bottom) - Int(b.top) + 1))
        let (pageW, pageH) = EMFRenderer.canvasPixelSize(deviceWidth: devW, deviceHeight: devH, scale: 1)

        let target = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        // Probe one full-page render to size the workload: a multi-second page
        // (a big EMF+ file) gets few iterations/tiles so the run stays minutes,
        // not hours.
        let probe = ContinuousClock().measure {
            let ctx = Self.makeContext(pageW, pageH)
            _ = EMFRenderer.render(file, into: ctx, target: target)
        }
        let probeMs = Self.ms(probe)
        let fullIters = probeMs > 500 ? 3 : (probeMs > 50 ? 5 : 9)
        let tileCount = probeMs > 500 ? 4 : (probeMs > 50 ? 12 : 48)
        let scrollPasses = probeMs > 500 ? 2 : 6

        // EMF+ stream reassembly+walk cost (problem 2 locator): the per-tile
        // re-parse the renderer pays on every render of an EMF+ file.
        let streamMs = median(iterations: probeMs > 500 ? 5 : 15) {
            _ = file.emfPlusStream()
        }

        // Full page, uncached vs a cold cache.
        let fullUncached = median(iterations: fullIters) {
            let ctx = Self.makeContext(pageW, pageH)
            _ = EMFRenderer.render(file, into: ctx, target: target)
        }
        let fullCached = median(iterations: fullIters) {
            let ctx = Self.makeContext(pageW, pageH)
            _ = EMFRenderer.render(file, into: ctx, target: target, imageCache: DIBImageCache())
        }

        // Per-tile: render the whole page clipped to one 512×512 tile, as the
        // tiled layer does. Uncached re-decodes every tile; a shared warm cache
        // decodes once. Average over a grid of tiles.
        let tile = 512
        let cols = max(1, Int(ceil(Double(pageW) / Double(tile))))
        let rows = max(1, Int(ceil(Double(pageH) / Double(tile))))
        let tiles = min(cols * rows, tileCount)

        let perTileUncached = tileAverage(file: file, target: target, tile: tile, cols: cols, tiles: tiles, cache: nil)
        let warm = DIBImageCache()
        // Prime the warm cache with one full tile pass, then measure the steady
        // state a scroll/repaint actually hits.
        _ = tileAverage(file: file, target: target, tile: tile, cols: cols, tiles: tiles, cache: warm)
        let perTileCached = tileAverage(file: file, target: target, tile: tile, cols: cols, tiles: tiles, cache: warm)

        // Peak memory: footprint delta across a sustained cached tile replay (the
        // scroll workload), as a bound on the cache's residency.
        let before = Self.physFootprintMB()
        let scrollCache = DIBImageCache()
        for _ in 0 ..< scrollPasses {
            _ = tileAverage(file: file, target: target, tile: tile, cols: cols, tiles: tiles, cache: scrollCache)
        }
        let peak = Self.physFootprintMB() - before

        print(String(
            format: "[bench] %@ | %.2f | %.2f / %.2f | %.3f / %.3f | %.1f (resident %.2f MB)",
            label, streamMs, fullUncached, fullCached, perTileUncached, perTileCached,
            peak, Double(scrollCache.residentCost) / (1024 * 1024)))
    }

    /// Average single-tile render time over `tiles` tiles, each a 512×512 context
    /// offset to its grid cell (the whole page replayed under the tile clip).
    private func tileAverage(file: EMFFile, target: CGRect, tile: Int, cols: Int, tiles: Int, cache: DIBImageCache?) -> Double {
        var total = 0.0
        let clock = ContinuousClock()
        for i in 0 ..< tiles {
            let col = i % cols
            let row = i / cols
            let ctx = Self.makeContext(tile, tile)
            ctx.translateBy(x: -Double(col * tile), y: -Double(row * tile))
            let elapsed = clock.measure {
                _ = EMFRenderer.render(file, into: ctx, target: target, imageCache: cache)
            }
            total += Self.ms(elapsed)
        }
        return total / Double(max(1, tiles))
    }

    // MARK: - Helpers

    private func median(iterations: Int, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0 ..< max(1, iterations) {
            samples.append(Self.ms(clock.measure(body)))
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) * 1e-15
    }

    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}
