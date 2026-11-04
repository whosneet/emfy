import Foundation
@testable import WMFParse

/// A little-endian byte-buffer builder for hand-constructing WMF fixtures in
/// tests. Append helpers write in WMF's native little-endian order so fixtures
/// read like the on-disk format ([MS-WMF] §1.3.1).
struct WMFFixtureBuilder {
    private(set) var bytes: [UInt8] = []

    /// Current length in bytes — useful for asserting record offsets.
    var count: Int { bytes.count }

    mutating func appendUInt32(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendInt16(_ value: Int16) {
        appendUInt16(UInt16(bitPattern: value))
    }

    mutating func appendBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func appendZeros(_ n: Int) {
        bytes.append(contentsOf: repeatElement(0, count: n))
    }

    var data: Data { Data(bytes) }
}

/// Convenience constructors for the WMF control and generic records.
extension WMFFixtureBuilder {
    /// A META_HEADER ([MS-WMF] §2.3.2.2), 18 bytes. Defaults form a plausible
    /// header (Type MEMORYMETAFILE, HeaderSize 9, Version METAVERSION300);
    /// override fields to exercise plausibility and advisory-mismatch paths.
    static func metaHeader(
        type: UInt16 = 0x0001,
        headerSize: UInt16 = 0x0009,
        version: UInt16 = 0x0300,
        sizeLow: UInt16 = 0,
        sizeHigh: UInt16 = 0,
        numberOfObjects: UInt16 = 0,
        maxRecord: UInt32 = 0,
        numberOfMembers: UInt16 = 0
    ) -> [UInt8] {
        var b = WMFFixtureBuilder()
        b.appendUInt16(type)              // 0  Type
        b.appendUInt16(headerSize)        // 2  HeaderSize (WORDs)
        b.appendUInt16(version)           // 4  Version
        b.appendUInt16(sizeLow)           // 6  SizeLow
        b.appendUInt16(sizeHigh)          // 8  SizeHigh
        b.appendUInt16(numberOfObjects)   // 10 NumberOfObjects
        b.appendUInt32(maxRecord)         // 12 MaxRecord
        b.appendUInt16(numberOfMembers)   // 16 NumberOfMembers
        return b.bytes
    }

    /// A META_PLACEABLE header ([MS-WMF] §2.3.2.3), 22 bytes. The checksum is
    /// computed as the XOR of the first ten header WORDs unless overridden
    /// (pass `checksumOverride` to force a mismatch).
    static func placeable(
        boundingBox: (Int16, Int16, Int16, Int16) = (0, 0, 1000, 1000),
        inch: UInt16 = 1440,
        hwmf: UInt16 = 0,
        reserved: UInt32 = 0,
        checksumOverride: UInt16? = nil
    ) -> [UInt8] {
        var b = WMFFixtureBuilder()
        b.appendUInt32(0x9AC6_CDD7)     // 0  Key
        b.appendUInt16(hwmf)            // 4  HWmf
        b.appendInt16(boundingBox.0)    // 6  BoundingBox.Left
        b.appendInt16(boundingBox.1)    // 8  .Top
        b.appendInt16(boundingBox.2)    // 10 .Right
        b.appendInt16(boundingBox.3)    // 12 .Bottom
        b.appendUInt16(inch)            // 14 Inch
        b.appendUInt32(reserved)        // 16 Reserved
        let checksum: UInt16
        if let checksumOverride {
            checksum = checksumOverride
        } else {
            var computed: UInt16 = 0
            for i in 0 ..< 10 {
                let lo = UInt16(b.bytes[i * 2])
                let hi = UInt16(b.bytes[i * 2 + 1])
                computed ^= lo | (hi << 8)
            }
            checksum = computed
        }
        b.appendUInt16(checksum)        // 20 Checksum
        return b.bytes
    }

    /// A generic record ([MS-WMF] §2.3): `RecordSize` (WORDs, header included)
    /// then `RecordFunction`, then `sizeWords*2 - 6` zero payload bytes. For
    /// abuse fixtures with `sizeWords < 3` only the 6-byte header is written
    /// (no padding).
    static func record(function: UInt16, sizeWords: UInt32) -> [UInt8] {
        var b = WMFFixtureBuilder()
        b.appendUInt32(sizeWords)
        b.appendUInt16(function)
        let payloadBytes = Int(sizeWords) * 2 - 6
        if payloadBytes > 0 { b.appendZeros(payloadBytes) }
        return b.bytes
    }

    /// A generic record around explicit `rdParam` payload bytes. `RecordSize` is
    /// `(6 + payload.count) / 2` WORDs unless `sizeWordsOverride` lies. Keep
    /// payloads even-length for well-formed records.
    static func record(
        function: UInt16,
        payload: [UInt8],
        sizeWordsOverride: UInt32? = nil
    ) -> [UInt8] {
        var b = WMFFixtureBuilder()
        b.appendUInt32(sizeWordsOverride ?? UInt32((6 + payload.count) / 2))
        b.appendUInt16(function)
        b.appendBytes(payload)
        return b.bytes
    }

    /// The META_EOF record (RecordFunction 0x0000, 3 WORDs = 6 bytes).
    static func eof() -> [UInt8] {
        record(function: 0x0000, sizeWords: 3)
    }

    /// Assembles a complete file: optional placeable header, then META_HEADER,
    /// then the records in order.
    static func file(
        placeable placeableBytes: [UInt8]? = nil,
        header headerBytes: [UInt8],
        records recordBytes: [[UInt8]]
    ) -> Data {
        var b = WMFFixtureBuilder()
        if let placeableBytes { b.appendBytes(placeableBytes) }
        b.appendBytes(headerBytes)
        for record in recordBytes { b.appendBytes(record) }
        return b.data
    }
}
