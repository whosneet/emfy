import Foundation

/// Saturating floating-point → fixed-width conversions for the exporter and
/// renderer. `Int32(Double)` / `UInt32(Double)` TRAP on a non-finite or
/// out-of-range value (§8: the parse/export path must never trap on
/// file-derived or edit-derived numbers — a RectL that spans the whole Int32
/// range has a width greater than `Int32.max`, and a hostile edit can push a
/// coordinate to infinity). These clamp instead: non-finite → 0, out of range →
/// the nearest bound.
enum SceneNumeric {

    /// `v` rounded to `Int32`, saturating: non-finite → 0, below `Int32.min` →
    /// `Int32.min`, above `Int32.max` → `Int32.max`.
    static func int32(_ v: some BinaryFloatingPoint) -> Int32 {
        let d = Double(v)
        guard d.isFinite else { return 0 }
        let r = d.rounded()
        if r >= Double(Int32.max) { return Int32.max }
        if r <= Double(Int32.min) { return Int32.min }
        return Int32(r)
    }

    /// `v` rounded to `Int16`, saturating: non-finite → 0, below `Int16.min` →
    /// `Int16.min`, above `Int16.max` → `Int16.max`. For WMF 16-bit fields (a Dx
    /// advance array, [MS-WMF] §2.3.3.5).
    static func int16(_ v: some BinaryFloatingPoint) -> Int16 {
        let d = Double(v)
        guard d.isFinite else { return 0 }
        let r = d.rounded()
        if r >= Double(Int16.max) { return Int16.max }
        if r <= Double(Int16.min) { return Int16.min }
        return Int16(r)
    }

    /// `v` rounded to `UInt32`, saturating: non-finite or negative → 0, above
    /// `UInt32.max` → `UInt32.max`.
    static func uint32(_ v: some BinaryFloatingPoint) -> UInt32 {
        let d = Double(v)
        guard d.isFinite else { return 0 }
        let r = d.rounded()
        if r <= 0 { return 0 }
        if r >= Double(UInt32.max) { return UInt32.max }
        return UInt32(r)
    }
}
