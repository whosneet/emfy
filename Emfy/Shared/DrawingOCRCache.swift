import CoreGraphics
import Foundation

// MARK: - OCR result caching (F3c)
//
// Vision text recognition is expensive, so a picture's recognised lines are cached by
// CONTENT (the SHA-256 of its raw bytes, plus the OCR settings version) rather than by
// position: the same bitmap drawn many times — or reopened across launches — is recognised
// once. The cached value is placement-INDEPENDENT (Vision's normalised 0…1 boxes), so a
// cache hit is re-mapped to device space for whichever destination rectangle the current
// file draws the picture at.
//
// Two tiers: an in-memory LRU for the session, and a JSON on-disk cache under
// `Caches/Emfy/OCR/` that survives launches. Both are driven only from the
// `DrawingOCRService` actor, so neither needs its own locking.

/// One recognised text line within a picture, in Vision's normalised bottom-left space
/// (0…1 on each axis). Stored as four scalars so it round-trips through JSON without relying
/// on `CGRect`'s archive format.
struct OCRLine: Codable, Sendable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// The normalised bounding box (bottom-left origin), ready for `OCRGeometry.deviceBox`.
    var normalizedBox: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(text: String, box: CGRect) {
        self.text = text
        self.x = Double(box.minX)
        self.y = Double(box.minY)
        self.width = Double(box.width)
        self.height = Double(box.height)
    }

    init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A fixed-capacity LRU of recognised-line arrays, keyed by the content+version cache key.
/// Used only from the `DrawingOCRService` actor (so no synchronisation is needed); kept a
/// plain class so the actor can hold one by reference.
final class OCRMemoryCache {
    private let limit: Int
    private var store: [String: [OCRLine]] = [:]
    /// Keys in least-to-most-recently-used order; the last entry is the newest.
    private var order: [String] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// The cached lines for `key`, marking it most-recently-used, or nil on a miss.
    func get(_ key: String) -> [OCRLine]? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    /// Stores `lines` for `key` and evicts the oldest entries past the capacity.
    func set(_ key: String, _ lines: [OCRLine]) {
        store[key] = lines
        touch(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }

    /// Empties the cache (the Settings toggle turning OCR off clears it).
    func clear() {
        store.removeAll()
        order.removeAll()
    }

    /// Current entry count, for tests.
    var count: Int { store.count }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// The on-disk OCR cache: one JSON file per content+version key under `Caches/Emfy/OCR/`,
/// held under a 50 MB cap with oldest-first eviction. Corrupt or truncated files are
/// deleted and recomputed rather than trusted (§8 — a hostile file could seed this cache
/// through Quick Look). Driven only from the service actor.
struct OCRDiskCache: Sendable {
    let directory: URL
    /// The whole-directory byte budget; the oldest entries are evicted past it.
    static let maxBytes = 50 * 1024 * 1024

    /// The shared cache under the user caches directory, or nil when it can't be created.
    static let shared: OCRDiskCache? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("Emfy/OCR", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        return OCRDiskCache(directory: directory)
    }()

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    /// The cached lines for `key`, or nil on a miss. A file that fails to decode is treated
    /// as corrupt: it is deleted and the caller recomputes.
    func load(_ key: String) -> [OCRLine]? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let lines = try? JSONDecoder().decode([OCRLine].self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Touch the file so eviction keeps recently-used entries (disk-level LRU).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return lines
    }

    /// Writes `lines` for `key`, then enforces the directory cap.
    func store(_ key: String, _ lines: [OCRLine]) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        enforceCap()
    }

    /// Deletes the oldest entries until the directory is within `maxBytes`.
    func enforceCap() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            entries.append((url, size, date))
            total += size
        }
        guard total > Self.maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > Self.maxBytes else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
