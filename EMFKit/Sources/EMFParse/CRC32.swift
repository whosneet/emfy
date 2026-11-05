import Foundation

/// CRC-32/IEEE — the checksum gzip stores in its member trailer (RFC 1952
/// §2.3.1, computed over the uncompressed data). Hand-rolled: the clean-room
/// rule bars third-party code, and Apple's `Compression` framework exposes no
/// CRC API, so the one checksum gzip needs is implemented here from the public
/// algorithm.
///
/// Standard table-driven reflected CRC-32: generator polynomial 0xEDB88320 (the
/// bit-reversed form of 0x04C11DB7), input and output reflected, initial and
/// final XOR with 0xFFFFFFFF. Every operation is a shift or XOR, so nothing
/// here can overflow or force-unwrap — safe on the hostile parse path (§8).
///
/// Public so the gzip writer in EMFWrite can compute the RFC 1952 member-trailer
/// checksum from the same implementation the inflater verifies against, rather
/// than duplicating the algorithm (v3 plan §11.2, E0a).
public enum CRC32 {
    /// 256-entry lookup table, built once from the reflected polynomial.
    private static let table: [UInt32] = {
        let polynomial: UInt32 = 0xEDB8_8320
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var crc = UInt32(index)
            for _ in 0 ..< 8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
            table[index] = crc
        }
        return table
    }()

    /// The CRC-32 of a byte sequence. `index` is always masked to 0...255, so
    /// the table subscript can never go out of range.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
