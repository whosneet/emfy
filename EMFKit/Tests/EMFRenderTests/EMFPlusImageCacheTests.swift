import CoreGraphics
import Foundation
import Testing
@testable import EMFRender

/// The per-object decoded-image cache seam (audit H1 / A1): one decode per bound
/// image object, invalidated on rebind. Tested directly so the "decode once, not
/// once per draw" contract is proven at the unit level; the playback-level
/// behaviour (correct pixels after many draws, one skip note PER draw) is proven
/// in `EMFPlusImagePlaybackTests`.
@Suite("EMF+ decoded-image cache")
struct DecodedImageCacheTests {

    private func tinyRedImage() throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var px: [UInt8] = [255, 0, 0, 255]
        let image: CGImage? = px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        return try #require(image)
    }

    @Test("a slot is stored once and served without re-storing; the CGImage instance is stable")
    func storeOnceServeMany() throws {
        var cache = DecodedImageCache()
        #expect(cache.cached(0) == nil, "an undecoded slot reports no entry")

        let image = try tinyRedImage()
        cache.store(0, CachedImage(image: image, skip: nil))
        #expect(cache.storeCount == 1)

        // Every subsequent read is a cache HIT: no new store, same CGImage
        // instance (identity stability lets CoreGraphics reuse its decode).
        for _ in 0 ..< 200 {
            let hit = try #require(cache.cached(0))
            #expect(hit.image === image, "cache must return the same CGImage instance")
        }
        #expect(cache.storeCount == 1, "cache hits must not decode/store again")
    }

    @Test("rebinding a slot invalidates its entry so it re-decodes")
    func invalidateReDecodes() throws {
        var cache = DecodedImageCache()
        let image = try tinyRedImage()
        cache.store(3, CachedImage(image: image, skip: nil))
        #expect(cache.cached(3) != nil)

        cache.invalidate(3)
        #expect(cache.cached(3) == nil, "an invalidated slot reports no entry")

        cache.store(3, CachedImage(image: image, skip: nil))
        #expect(cache.storeCount == 2, "the re-decode stores a fresh entry")
    }

    @Test("a remembered failure is served without retrying the decode")
    func failureIsCachedNotRetried() throws {
        var cache = DecodedImageCache()
        cache.store(5, CachedImage(image: nil, skip: .invalid))
        let hit = try #require(cache.cached(5))
        #expect(hit.image == nil && hit.skip == .invalid)
        #expect(cache.storeCount == 1)
    }

    @Test("out-of-range slot ids are ignored, never trapping")
    func outOfRangeIgnored() {
        var cache = DecodedImageCache(capacity: 64)
        #expect(cache.cached(64) == nil)
        #expect(cache.cached(-1) == nil)
        cache.store(64, CachedImage(image: nil, skip: .invalid))
        cache.store(-1, CachedImage(image: nil, skip: .invalid))
        #expect(cache.storeCount == 0, "an out-of-range store is a no-op")
        cache.invalidate(64)   // must not trap
        cache.invalidate(-1)
    }
}
