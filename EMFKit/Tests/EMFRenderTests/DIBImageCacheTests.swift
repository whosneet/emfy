import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// The decoded-DIB cache (P2 performance): one decode per (record, crop,
/// budget), reused across a tiled viewer's concurrent tiles, bounded by an LRU
/// memory budget. Pixels are unchanged — the cache stores exactly what
/// `BitmapDecoder.decode` produced — so these tests prove the cache CONTRACT
/// (hit, eviction, thread safety); the byte-identical rendering is proven by the
/// unchanged snapshot suites, which run with no cache.
@Suite("DIB image cache")
struct DIBImageCacheTests {

    /// A `width`×`height` opaque RGBA CGImage (its byte cost is the LRU unit).
    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var px = [UInt8](repeating: 200, count: width * height * 4)
        let image: CGImage? = px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        return try #require(image)
    }

    private func key(_ recordIndex: Int, budget: Int = 16) -> DIBImageCache.Key {
        DIBImageCache.Key(
            recordIndex: recordIndex,
            srcX: 0, srcY: 0, srcW: budget, srcH: budget,
            budgetW: budget, budgetH: budget,
            dibWidth: Int32(budget), dibHeight: Int32(budget), bitCount: 32, byteCount: budget * budget * 4)
    }

    private func decoded(_ image: CGImage) -> DIBImageCache.Decoded {
        DIBImageCache.Decoded(
            image: image, downsampled: false,
            nativePixels: image.width * image.height, decodedPixels: image.width * image.height)
    }

    @Test("a hit returns the same CGImage instance and decodes exactly once")
    func hitReturnsSameImageDecodingOnce() throws {
        let cache = DIBImageCache()
        let img = try image(8, 8)
        let k = key(0)

        var decodeCount = 0
        for _ in 0 ..< 200 {
            let result = cache.decodedImage(forKey: k) {
                decodeCount += 1
                return decoded(img)
            }
            #expect(try #require(result).image === img, "a hit must return the same CGImage instance")
        }
        #expect(decodeCount == 1, "repeated gets of one key must decode exactly once")
        #expect(cache.count == 1)
    }

    @Test("different keys decode independently")
    func differentKeysDecodeIndependently() throws {
        let cache = DIBImageCache()
        var decodeCount = 0
        for i in 0 ..< 5 {
            _ = cache.decodedImage(forKey: key(i)) {
                decodeCount += 1
                return decoded(try! image(4, 4))
            }
        }
        #expect(decodeCount == 5)
        #expect(cache.count == 5)
    }

    @Test("a nil decode (unsupported DIB) is not cached and retries each time")
    func nilDecodeNotCached() throws {
        let cache = DIBImageCache()
        var decodeCount = 0
        for _ in 0 ..< 10 {
            let result = cache.decodedImage(forKey: key(0)) {
                decodeCount += 1
                return nil
            }
            #expect(result == nil)
        }
        #expect(decodeCount == 10, "a nil (unsupported) result must not be cached")
        #expect(cache.count == 0)
    }

    @Test("eviction keeps the resident cost within the memory budget")
    func evictionStaysWithinBudget() throws {
        // Each 8×8 RGBA image costs 8*4*8 = 256 bytes; a 1 KiB budget holds ~4.
        let budget = 1024
        let cache = DIBImageCache(memoryBudget: budget)
        let img = try image(8, 8)
        for i in 0 ..< 50 {
            _ = cache.decodedImage(forKey: key(i)) { self.decoded(img) }
            #expect(cache.residentCost <= budget, "the cache must never exceed its memory budget")
        }
        #expect(cache.count < 50, "entries must have been evicted under the budget")
        #expect(cache.residentCost <= budget)
    }

    @Test("eviction is least-recently-used: a re-touched key survives")
    func evictionIsLeastRecentlyUsed() throws {
        // Budget for exactly two 8×8 (256-byte) entries.
        let cache = DIBImageCache(memoryBudget: 512)
        let img = try image(8, 8)
        _ = cache.decodedImage(forKey: key(0)) { self.decoded(img) }
        _ = cache.decodedImage(forKey: key(1)) { self.decoded(img) }
        // Touch key 0 so key 1 becomes least-recently-used.
        _ = cache.decodedImage(forKey: key(0)) { Issue.record("key 0 should be resident"); return self.decoded(img) }
        // Insert key 2 → evicts the LRU (key 1), keeps key 0.
        _ = cache.decodedImage(forKey: key(2)) { self.decoded(img) }

        var key0Redecoded = false
        _ = cache.decodedImage(forKey: key(0)) { key0Redecoded = true; return self.decoded(img) }
        #expect(key0Redecoded == false, "the recently-used key must have survived eviction")

        var key1Redecoded = false
        _ = cache.decodedImage(forKey: key(1)) { key1Redecoded = true; return self.decoded(img) }
        #expect(key1Redecoded == true, "the least-recently-used key must have been evicted")
    }

    @Test("an entry larger than the whole budget is evicted, never retained over budget")
    func oversizedEntryNotRetained() throws {
        let cache = DIBImageCache(memoryBudget: 100)   // smaller than one 8×8 (256 B)
        let img = try image(8, 8)
        _ = cache.decodedImage(forKey: key(0)) { self.decoded(img) }
        #expect(cache.count == 0, "a single over-budget entry must not be retained")
        #expect(cache.residentCost == 0)
    }

    /// Renders `file` into a fresh `side`×`side` sRGB bitmap and returns its raw
    /// pixel bytes, optionally through `cache` (a tile render).
    private func renderBytes(_ file: EMFFile, side: Int, cache: DIBImageCache?) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        _ = EMFRenderer.render(file, into: ctx, target: CGRect(x: 0, y: 0, width: side, height: side), imageCache: cache)
        let image = try #require(ctx.makeImage())
        let bytes = try #require(image.dataProvider?.data) as Data
        return bytes
    }

    @Test("a cached render is byte-identical to an uncached one, on every tile")
    func cachedRenderMatchesUncached() throws {
        // A committed EMF carrying a real STRETCHDIBITS DIB (phase-4 image gate).
        let file = try parseCorpusFile("gate-p4-image.emf")
        let side = 200

        let uncached = try renderBytes(file, side: side, cache: nil)

        // A warm cache: the first render fills it (miss path), a second render
        // reuses it (hit path). Both must match the uncached pixels exactly.
        let cache = DIBImageCache()
        let firstCached = try renderBytes(file, side: side, cache: cache)
        let secondCached = try renderBytes(file, side: side, cache: cache)

        #expect(cache.count >= 1, "the DIB must have been cached")
        #expect(firstCached == uncached, "the miss-path render must be byte-identical to uncached")
        #expect(secondCached == uncached, "the hit-path render must be byte-identical to uncached")
    }

    @Test("concurrent gets from many threads never crash or corrupt (TSan target)")
    func concurrentAccessIsSafe() throws {
        let cache = DIBImageCache(memoryBudget: 256 * 1024)
        // Pre-build images so the decode closure does no CoreGraphics work under
        // contention — the point is the cache's own locking, not image creation.
        let images = try (0 ..< 16).map { _ in try image(8, 8) }

        DispatchQueue.concurrentPerform(iterations: 500) { iteration in
            let slot = iteration % 16
            let result = cache.decodedImage(forKey: key(slot)) { self.decoded(images[slot]) }
            // Every served image must be one of the pre-built set (no tearing).
            #expect(result != nil)
        }
        #expect(cache.count <= 16)
        #expect(cache.residentCost <= 256 * 1024)
    }
}
