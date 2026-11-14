import CoreGraphics
import Foundation

/// A bounded, thread-safe cache of decoded GDI DIB `CGImage`s, keyed by the
/// source record and the decode budget (P2 performance).
///
/// Why it exists: a tiled viewer (`CATiledLayer`) replays the whole record
/// stream once PER TILE, on several background threads concurrently. Without a
/// cache every tile re-decodes each `EMR_STRETCHDIBITS` / `EMR_BITBLT` /
/// `EMR_STRETCHBLT` / `EMR_SETDIBITSTODEVICE` DIB from scratch — a 1 MB DIB was
/// seen pinning ~98% CPU during a scroll. One cache per document, passed into
/// every tile's render, turns that into a single decode per (record, budget).
///
/// Correctness and safety:
/// - Pixels are unchanged. The cache stores exactly the `CGImage`
///   `BitmapDecoder.decode` would have produced, so a cached render is
///   byte-identical to an uncached one. A render with NO cache (every snapshot
///   test, Quick Look, export) takes the unchanged decode path.
/// - Thread-safe, decode OUTSIDE the lock. An `NSCondition` guards all state,
///   but the decode runs with the lock RELEASED (M3 release fix): the first
///   caller for a key marks it in-flight, decodes, then re-takes the lock to
///   publish; concurrent callers for the SAME key wait on the condition and
///   reuse the result, so each key still decodes exactly once under the tiled
///   layer's concurrent threads while decodes for DIFFERENT keys run in
///   parallel. Not holding the lock across the decode keeps a pathological
///   decode from stalling every other tile thread.
/// - Memory is bounded. Entries are evicted least-recently-used once the total
///   decoded-byte cost would exceed `memoryBudget`. A single entry larger than
///   the whole budget is returned UNCACHED (M3): caching it would evict the
///   entire resident set for one pathological bitmap, so it is handed back
///   without being stored and without disturbing the other entries.
///
/// `@unchecked Sendable`: every access to the mutable dictionary, LRU order,
/// running cost and in-flight set goes through `condition`.
public final class DIBImageCache: @unchecked Sendable {

    /// Identifies a decoded DIB within ONE document: the source record index
    /// plus the source sub-rectangle and the decode budget that together
    /// determine the output pixels, plus the DIB's own dimensions as a guard so
    /// two different DIBs can never alias on a shared index (defence in depth —
    /// the record index alone is unique within a document).
    public struct Key: Hashable, Sendable {
        let recordIndex: Int
        let srcX, srcY, srcW, srcH: Int
        let budgetW, budgetH: Int
        let dibWidth, dibHeight: Int32
        let bitCount: UInt16
        let byteCount: Int

        init(
            recordIndex: Int,
            srcX: Int, srcY: Int, srcW: Int, srcH: Int,
            budgetW: Int, budgetH: Int,
            dibWidth: Int32, dibHeight: Int32, bitCount: UInt16, byteCount: Int
        ) {
            self.recordIndex = recordIndex
            self.srcX = srcX; self.srcY = srcY; self.srcW = srcW; self.srcH = srcH
            self.budgetW = budgetW; self.budgetH = budgetH
            self.dibWidth = dibWidth; self.dibHeight = dibHeight
            self.bitCount = bitCount; self.byteCount = byteCount
        }
    }

    /// A decoded result: the image plus the native/decoded pixel counts the
    /// caller needs to re-emit the coalesced downsample log on a cache hit, so a
    /// cached render's log matches an uncached render's log.
    public struct Decoded {
        public let image: CGImage
        /// Whether the decode fell below the source crop's native resolution
        /// (the decoder's own flag, so a cache hit re-emits the exact same
        /// coalesced downsample log an uncached render would).
        public let downsampled: Bool
        public let nativePixels: Int
        public let decodedPixels: Int

        public init(image: CGImage, downsampled: Bool, nativePixels: Int, decodedPixels: Int) {
            self.image = image
            self.downsampled = downsampled
            self.nativePixels = nativePixels
            self.decodedPixels = decodedPixels
        }
    }

    private struct Entry {
        let decoded: Decoded
        /// The decoded image's real byte footprint (`bytesPerRow × height`).
        let cost: Int
    }

    /// The default per-document memory budget: 64 MiB of decoded pixels. Large
    /// enough that the handful of DIBs in a real document, across the few zoom
    /// levels a viewer walks, all stay resident; small enough to stay bounded.
    public static let defaultMemoryBudget = 64 * 1024 * 1024

    /// Guards every mutable field below AND signals in-flight decodes: a waiter
    /// blocks on it until the decoding thread publishes its result and broadcasts.
    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    /// LRU order, oldest first. A key appears exactly once.
    private var order: [Key] = []
    private var currentCost = 0
    /// Keys a thread is currently decoding with the lock released; a second caller
    /// for the same key waits rather than decoding it again (single decode per key).
    private var inFlight: Set<Key> = []
    private let memoryBudget: Int

    public init(memoryBudget: Int = DIBImageCache.defaultMemoryBudget) {
        self.memoryBudget = max(1, memoryBudget)
    }

    /// Returns the cached decode for `key`, or runs `decode` (once) and caches
    /// it. `decode` returns `nil` when the DIB is unsupported/undecodable; a
    /// `nil` result is NOT cached (it is cheap to re-establish and carries its
    /// own log). The decode runs with the lock RELEASED; concurrent callers for
    /// the same key wait and share the single decode (M3). An over-budget result
    /// is returned uncached, leaving the resident set untouched.
    func decodedImage(forKey key: Key, decode: () -> Decoded?) -> Decoded? {
        condition.lock()
        while true {
            if let entry = entries[key] {
                touch(key)
                condition.unlock()
                return entry.decoded
            }
            // Another thread is already decoding this key: wait for it to publish,
            // then re-check (it may have produced an entry, or an uncached/nil
            // result, in which case this thread takes over the decode).
            if inFlight.contains(key) {
                condition.wait()
                continue
            }
            inFlight.insert(key)
            break
        }
        condition.unlock()

        // Decode with the lock released so a slow decode cannot stall other tile
        // threads, and so decodes for different keys proceed in parallel.
        let decoded = decode()

        condition.lock()
        inFlight.remove(key)
        if let decoded {
            let cost = max(1, decoded.image.bytesPerRow * decoded.image.height)
            // An entry larger than the whole budget is returned UNCACHED, without
            // evicting the resident set: caching it would force every other entry
            // out for a single pathological bitmap (M3).
            if cost <= memoryBudget {
                insert(key, Entry(decoded: decoded, cost: cost))
            }
        }
        // Wake every waiter for this (or any) key so they re-check the cache.
        condition.broadcast()
        condition.unlock()
        return decoded
    }

    // MARK: - LRU bookkeeping (all callers hold `condition`)

    private func touch(_ key: Key) {
        guard let position = order.firstIndex(of: key) else { return }
        order.remove(at: position)
        order.append(key)
    }

    private func insert(_ key: Key, _ entry: Entry) {
        entries[key] = entry
        order.append(key)
        currentCost += entry.cost
        evictToBudget()
    }

    /// Drops least-recently-used entries until the total cost is within budget.
    /// Only ever called with an about-to-insert entry whose own cost is already
    /// ≤ `memoryBudget` (an over-budget entry is returned uncached and never
    /// inserted), so the just-inserted key — appended last in `order` — is never
    /// the one evicted: the loop stops once the older entries are gone.
    private func evictToBudget() {
        while currentCost > memoryBudget, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                currentCost -= removed.cost
            }
        }
    }

    /// Drops every resident entry, freeing the decoded pixels (M4). An iOS viewer
    /// calls this on a memory-warning so the tiled layer's DIB decodes are released
    /// before the extension/app is jetsam-killed; the next tile simply re-decodes.
    /// An in-flight decode is unaffected — it publishes into the now-empty cache.
    public func purge() {
        condition.lock()
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        currentCost = 0
        condition.unlock()
    }

    // MARK: - Introspection (tests)

    /// The number of resident entries.
    public var count: Int {
        condition.lock(); defer { condition.unlock() }
        return entries.count
    }

    /// The total resident decoded-byte cost (≤ `memoryBudget`).
    public var residentCost: Int {
        condition.lock(); defer { condition.unlock() }
        return currentCost
    }
}
