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
/// - Thread-safe. A single `NSLock` guards all state. The decode runs while the
///   lock is held, so each distinct key decodes EXACTLY ONCE even under the
///   tiled layer's concurrent threads; the decode is pure pixel work
///   (`BitmapDecoder`, no CoreText), so holding the lock across it cannot
///   deadlock the font-lookup pool (MEMORY: macos-27-2 font-provider hang).
/// - Memory is bounded. Entries are evicted least-recently-used once the total
///   decoded-byte cost would exceed `memoryBudget`, so a document with many
///   large DIBs (or many zoom levels) never grows without limit.
///
/// `@unchecked Sendable`: every access to the mutable dictionary, LRU order and
/// running cost goes through `lock`.
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

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// LRU order, oldest first. A key appears exactly once.
    private var order: [Key] = []
    private var currentCost = 0
    private let memoryBudget: Int

    public init(memoryBudget: Int = DIBImageCache.defaultMemoryBudget) {
        self.memoryBudget = max(1, memoryBudget)
    }

    /// Returns the cached decode for `key`, or runs `decode` (once) and caches
    /// it. `decode` returns `nil` when the DIB is unsupported/undecodable; a
    /// `nil` result is NOT cached (it is cheap to re-establish and carries its
    /// own log). The decode runs under the lock, so concurrent callers for the
    /// same key share a single decode.
    func decodedImage(forKey key: Key, decode: () -> Decoded?) -> Decoded? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] {
            touch(key)
            return entry.decoded
        }
        guard let decoded = decode() else { return nil }
        let cost = max(1, decoded.image.bytesPerRow * decoded.image.height)
        insert(key, Entry(decoded: decoded, cost: cost))
        return decoded
    }

    // MARK: - LRU bookkeeping (all callers hold `lock`)

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
    /// A single entry larger than the whole budget is evicted too, so the cache
    /// never holds more than `memoryBudget` bytes (it then re-decodes that DIB
    /// each time — acceptable for a pathological, over-budget bitmap).
    private func evictToBudget() {
        while currentCost > memoryBudget, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                currentCost -= removed.cost
            }
        }
    }

    // MARK: - Introspection (tests)

    /// The number of resident entries.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// The total resident decoded-byte cost (≤ `memoryBudget`).
    public var residentCost: Int {
        lock.lock(); defer { lock.unlock() }
        return currentCost
    }
}
