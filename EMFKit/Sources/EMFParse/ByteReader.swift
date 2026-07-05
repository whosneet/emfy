import Foundation

/// A bounds-checked, little-endian reader over a flat byte buffer.
///
/// EMF is little-endian throughout ([MS-EMF] §1.3.1). This reader exists to
/// make the classic Swift binary-parsing bug impossible: a Foundation `Data`
/// can have a non-zero `startIndex`, so absolute subscripting on a `Data`
/// slice reads the wrong bytes. We copy the input into a `[UInt8]` up front
/// (indices always start at 0) and expose only relative-offset reads. Every
/// read is bounds-checked and returns `nil` on overrun rather than trapping —
/// nothing here can force-unwrap or overflow.
struct ByteReader: Equatable {
    /// Normalised backing storage. `bytes[0]` is always the first byte of the
    /// input regardless of the source `Data`'s `startIndex`.
    let bytes: [UInt8]

    init(_ data: Data) {
        // `Array(data)` copies element-by-element from `startIndex`, so the
        // resulting array is always zero-based and startIndex-safe.
        self.bytes = Array(data)
    }

    /// Total number of bytes available.
    var count: Int { bytes.count }

    /// Reads a little-endian `UInt32` at the given zero-based offset, or `nil`
    /// if the 4-byte window would run past the end of the buffer.
    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Reads a little-endian `Int32` at the given zero-based offset, or `nil`
    /// if out of range. The `UInt32` bit pattern is reinterpreted as signed.
    func readInt32(at offset: Int) -> Int32? {
        guard let u = readUInt32(at: offset) else { return nil }
        return Int32(bitPattern: u)
    }

    /// Reads a little-endian `UInt16` at the given zero-based offset, or `nil`
    /// if out of range.
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        let b0 = UInt16(bytes[offset])
        let b1 = UInt16(bytes[offset + 1])
        return b0 | (b1 << 8)
    }

    /// Reads a little-endian `Int16` at the given zero-based offset, or `nil`
    /// if out of range. The `UInt16` bit pattern is reinterpreted as signed
    /// (PointS coordinates, [MS-WMF] §2.2.2.16).
    func readInt16(at offset: Int) -> Int16? {
        guard let u = readUInt16(at: offset) else { return nil }
        return Int16(bitPattern: u)
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
