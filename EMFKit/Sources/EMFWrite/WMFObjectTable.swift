import Foundation

/// The WMF object-table model for the writer side ([MS-WMF] §3.1.4.1): WMF
/// object-creation records (CREATEPENINDIRECT, CREATEBRUSHINDIRECT,
/// CREATEFONTINDIRECT, CREATEPALETTE, CREATEPATTERNBRUSH, DIBCREATEPATTERNBRUSH,
/// CREATEREGION) carry no index — a created object takes the LOWEST free 0-based
/// slot, and META_DELETEOBJECT frees the slot it names. This mirrors WMFParse's
/// reader-side allocator exactly, so a file this writer produces resolves the
/// same slots when read back.
///
/// `numberOfObjects` is the header's `NumberOfObjects` field: the peak number of
/// objects alive at once, which equals the largest slot index ever used plus one
/// (lowest-free allocation keeps those two quantities equal). Allocation is
/// capped at the UInt16 the header can hold; past it, a typed overflow (primer §8).
///
/// Occupancy is a fixed bit set (one bit per slot) rather than a `Set`, so
/// `allocate` is O(words-scanned-to-the-first-free-bit) and a hostile
/// create/free stream during a re-emit cannot drive it quadratic (§8: bounded
/// time) — the same reason WMFParse uses a bit set.
struct WMFObjectTable {
    /// One past the highest slot the UInt16 `NumberOfObjects` field can describe:
    /// valid slots are 0…65534.
    static let cap = Int(UInt16.max)   // 65535

    /// 1024 UInt64 words = 65536 bits, covering every representable slot.
    private var words = [UInt64](repeating: 0, count: (cap + 64) / 64)
    /// Live object count; peak of it is `NumberOfObjects`.
    private var occupiedCount = 0
    private var peak = 0

    /// Allocates and returns the lowest free slot. Throws when the table would
    /// exceed the header's UInt16 `NumberOfObjects` field.
    mutating func allocate() throws(WMFWriteError) -> Int {
        var w = 0
        while w < words.count, words[w] == .max { w += 1 }
        guard w < words.count else { throw .objectTableOverflow(slot: WMFObjectTable.cap) }
        let bit = (~words[w]).trailingZeroBitCount
        let slot = w * 64 + bit
        guard slot < WMFObjectTable.cap else { throw .objectTableOverflow(slot: slot) }
        words[w] |= UInt64(1) << bit
        occupiedCount += 1
        if occupiedCount > peak { peak = occupiedCount }
        return slot
    }

    /// Frees `slot` if it is occupied (a free of an empty or out-of-range slot is
    /// a no-op, matching the reader's lenient behaviour).
    mutating func free(_ slot: Int) {
        guard slot >= 0, slot < WMFObjectTable.cap else { return }
        let w = slot / 64
        let mask = UInt64(1) << (slot % 64)
        if words[w] & mask != 0 {
            words[w] &= ~mask
            occupiedCount -= 1
        }
    }

    /// The header `NumberOfObjects` value: peak concurrent occupancy. Never
    /// exceeds the UInt16 cap, because `allocate` fails before it could.
    var numberOfObjects: UInt16 { UInt16(peak) }
}
