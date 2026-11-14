import CoreGraphics
import Foundation
import Testing
@testable import EMFEdit

/// A tiny lock-guarded counter for asserting how many times a decode closure ran
/// under concurrency (the in-flight-dedupe proof).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// The edited/new-image decode cache (M2): a cost-bounded LRU keyed by (id, budget),
/// decoding once per key with the lock released and in-flight dedupe. These pin the
/// cache CONTRACT; the budgeted downsampling and rendering are proven by the scene
/// render/fidelity suites.
struct ImageDecodeCacheTests {

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

    private func key(_ id: Int) -> SceneRenderer.ImageDecodeCache.Key {
        SceneRenderer.ImageDecodeCache.Key(id: id, budgetW: 0, budgetH: 0)
    }

    @Test("a hit returns the cached image and decodes exactly once")
    func hitDecodesOnce() throws {
        let cache = SceneRenderer.ImageDecodeCache()
        let img = try image(8, 8)
        var decodeCount = 0
        for _ in 0 ..< 100 {
            let result = cache.cached(forKey: key(0)) { decodeCount += 1; return img }
            #expect(result === img)
        }
        #expect(decodeCount == 1)
        #expect(cache.count == 1)
    }

    @Test("eviction keeps the resident cost within the memory budget")
    func evictionStaysWithinBudget() throws {
        // Each 8×8 RGBA image costs 8*4*8 = 256 bytes; a 1 KiB budget holds ~4.
        let budget = 1024
        let cache = SceneRenderer.ImageDecodeCache(memoryBudget: budget)
        let img = try image(8, 8)
        for i in 0 ..< 50 {
            _ = cache.cached(forKey: key(i)) { img }
            #expect(cache.residentCost <= budget)
        }
        #expect(cache.count < 50, "entries must have been evicted under the budget")
        #expect(cache.residentCost <= budget)
    }

    @Test("eviction is least-recently-used: a re-touched key survives")
    func evictionIsLRU() throws {
        let cache = SceneRenderer.ImageDecodeCache(memoryBudget: 512) // two 8×8 entries
        let img = try image(8, 8)
        _ = cache.cached(forKey: key(0)) { img }
        _ = cache.cached(forKey: key(1)) { img }
        _ = cache.cached(forKey: key(0)) { Issue.record("key 0 should be resident"); return img }
        _ = cache.cached(forKey: key(2)) { img } // evicts LRU (key 1)

        var key0Redecoded = false
        _ = cache.cached(forKey: key(0)) { key0Redecoded = true; return img }
        #expect(key0Redecoded == false, "the recently-used key must survive eviction")

        var key1Redecoded = false
        _ = cache.cached(forKey: key(1)) { key1Redecoded = true; return img }
        #expect(key1Redecoded == true, "the least-recently-used key must have been evicted")
    }

    @Test("an over-budget entry is returned uncached and leaves the resident set intact (M2)")
    func oversizedEntryLeavesOthersResident() throws {
        let cache = SceneRenderer.ImageDecodeCache(memoryBudget: 512)
        let small = try image(8, 8)
        _ = cache.cached(forKey: key(0)) { small }
        _ = cache.cached(forKey: key(1)) { small }
        #expect(cache.count == 2)

        let big = try image(32, 32) // 4096 bytes, far over budget
        let result = cache.cached(forKey: key(99)) { big }
        #expect(result === big)
        #expect(cache.count == 2, "the resident set must survive an over-budget insert")

        var redecoded = false
        _ = cache.cached(forKey: key(0)) { redecoded = true; return small }
        _ = cache.cached(forKey: key(1)) { redecoded = true; return small }
        #expect(redecoded == false)
    }

    @Test("concurrent gets of one key decode exactly once (in-flight dedupe)")
    func concurrentSameKeyDecodesOnce() throws {
        let cache = SceneRenderer.ImageDecodeCache()
        let img = try image(8, 8)
        let decodeCount = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let result = cache.cached(forKey: self.key(0)) {
                decodeCount.increment()
                Thread.sleep(forTimeInterval: 0.01) // let the others pile up as waiters
                return img
            }
            #expect(result === img)
        }
        #expect(decodeCount.value == 1, "one key under concurrent demand must decode exactly once")
        #expect(cache.count == 1)
    }

    @Test("decode downsamples a large image to its budget, never upsampling")
    func decodeDownsamplesToBudget() throws {
        // A 400×300 inserted image shown at a 100×75 footprint decodes to ≤ the budget.
        let big = try image(400, 300)
        let scene = try makeImageScene(big)
        let element = try #require(scene.elements.first { $0.kind == .image })

        let small = try #require(SceneRenderer.ImageDecodeCache.decode(element, budget: (w: 100, h: 75)))
        #expect(small.width <= 100 && small.height <= 75, "decoded \(small.width)×\(small.height) exceeds the budget")
        #expect(small.width > 1 && small.height > 1)

        // A budget larger than native must not upsample.
        let native = try #require(SceneRenderer.ImageDecodeCache.decode(element, budget: (w: 4000, h: 3000)))
        #expect(native.width == 400 && native.height == 300, "a generous budget must keep native resolution")

        // No budget = native resolution.
        let none = try #require(SceneRenderer.ImageDecodeCache.decode(element, budget: nil))
        #expect(none.width == 400 && none.height == 300)
    }

    /// A one-element scene holding `cg` as an inserted (compressed-PNG) image, so
    /// `ImageDecodeCache.decode` has a real `Element.image` to decode.
    private func makeImageScene(_ cg: CGImage) throws -> Scene {
        let plus = try #require(SceneImageCoding.compressedPNGImage(fromCGImage: cg))
        let image = SceneImage(emfPlusImage: plus,
                               destRectDevice: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let element = Element(id: 0, kind: .image, geometryDevice: ScenePath(), transform: .identity,
                              style: SceneStyle(), image: image,
                              provenance: Provenance(sourceRecordIndices: [], edited: false))
        let src = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
        let part = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
        return Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                     layers: [Layer(id: 0, name: "L", elements: [element])], partition: part, source: src)
    }
}
