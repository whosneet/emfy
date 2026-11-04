import Foundation

/// A bounds-checked, little-endian reader over a flat byte buffer, local to
/// WMFParse.
///
/// EMFParse has an equivalent `ByteReader`, but it is `internal`: reaching it
/// from this module would mean making it — and its public `bytes` storage —
/// part of EMFParse's API. WMFParse depends on EMFParse only for the shared
/// record/DC model, not for low-level byte access, so a small self-contained
/// reader keeps this module's hostile-input parse path (§8) auditable in one
/// place and avoids widening EMFParse's surface for a 40-line helper. The two
/// readers are deliberately identical in behaviour.
///
/// WMF is little-endian throughout ([MS-WMF] §1.3.1 / [MS-DTYP] §2.2). The
/// input is copied into a zero-based `[UInt8]` up front so a `Data` with a
/// non-zero `startIndex` cannot cause an off-by-start read. Every read is
/// bounds-checked and returns `nil` on overrun rather than trapping — nothing
/// here force-unwraps or overflows.
struct WMFByteReader: Equatable {
    /// Normalised backing storage. `bytes[0]` is always the first input byte
    /// regardless of the source `Data`'s `startIndex`.
    let bytes: [UInt8]

    init(_ data: Data) {
        // `Array(data)` copies element-by-element from `startIndex`, so the
        // result is always zero-based and startIndex-safe.
        self.bytes = Array(data)
    }

    /// Total number of bytes available.
    var count: Int { bytes.count }

    /// Reads a little-endian `UInt32` at `offset`, or `nil` if the 4-byte
    /// window would run past the end of the buffer.
    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Reads a little-endian `UInt16` at `offset`, or `nil` if out of range.
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        let b0 = UInt16(bytes[offset])
        let b1 = UInt16(bytes[offset + 1])
        return b0 | (b1 << 8)
    }

    /// Reads a little-endian `Int16` at `offset`, or `nil` if out of range. The
    /// `UInt16` bit pattern is reinterpreted as signed (the placeable header's
    /// BoundingBox is a Rect of four 16-bit signed coordinates, [MS-WMF]
    /// §2.2.2.18).
    func readInt16(at offset: Int) -> Int16? {
        guard let u = readUInt16(at: offset) else { return nil }
        return Int16(bitPattern: u)
    }

    /// Reads a single byte at `offset`, or `nil` if out of range. Used for the
    /// 8-bit fields of the Font and Bitmap16 objects ([MS-WMF] §2.2.1.2/.2.2.1).
    func readUInt8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    /// Returns the raw bytes in `[offset, offset + length)` as `Data`, or `nil`
    /// if the range is not fully inside the buffer. `length` must be >= 0.
    func data(at offset: Int, length: Int) -> Data? {
        guard length >= 0, offset >= 0, offset <= bytes.count - length else {
            return nil
        }
        return Data(bytes[offset ..< offset + length])
    }
}
