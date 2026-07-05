import Foundation

/// A tiny little-endian byte-buffer builder for hand-constructing EMF fixtures
/// in tests. Append helpers write in EMF's native little-endian order so the
/// fixtures read exactly like the on-disk format ([MS-EMF] §1.3.1).
struct FixtureBuilder {
    private(set) var bytes: [UInt8] = []

    /// Current length in bytes — useful for asserting record offsets.
    var count: Int { bytes.count }

    mutating func appendUInt32(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends raw bytes verbatim.
    mutating func appendBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    /// Appends a UTF-16LE encoding of `string` (no length prefix, no implicit
    /// terminator beyond what the string contains).
    mutating func appendUTF16LE(_ string: String) {
        for unit in string.utf16 {
            appendUInt16(unit)
        }
    }

    /// Appends `n` zero bytes.
    mutating func appendZeros(_ n: Int) {
        bytes.append(contentsOf: repeatElement(0, count: n))
    }

    var data: Data { Data(bytes) }
}

/// Convenience constructors for common fixtures.
extension FixtureBuilder {
    /// Builds a bare non-header record: `Type` then `Size` then `Size - 8`
    /// zero payload bytes. `size` must be >= 8 and a multiple of 4 for a
    /// well-formed record (tests deliberately violate this to exercise
    /// diagnostics).
    static func record(type: UInt32, size: UInt32) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendUInt32(type)
        b.appendUInt32(size)
        let payload = Int(size) - 8
        if payload > 0 {
            b.appendZeros(payload)
        }
        return b.bytes
    }

    /// Builds an EMR_HEADER record with the given fixed-part `size`
    /// (88 / 100 / 108 are the standard variants). `recordSize` is the value
    /// written into the record's `nSize` field (defaults to `fixedSize`);
    /// pass a larger value when appending a description or extra payload.
    /// Non-signature fields are set to recognisable values for assertions.
    static func header(
        fixedSize: Int,
        recordSize: UInt32? = nil,
        bounds: (Int32, Int32, Int32, Int32) = (0, 0, 100, 200),
        frame: (Int32, Int32, Int32, Int32) = (0, 0, 5000, 10000),
        version: UInt32 = 0x0001_0000,
        bytesField: UInt32 = 0,
        recordsField: UInt32 = 0,
        handles: UInt16 = 1,
        nDescription: UInt32 = 0,
        offDescription: UInt32 = 0,
        nPalEntries: UInt32 = 0,
        device: (Int32, Int32) = (1920, 1080),
        millimeters: (Int32, Int32) = (508, 285),
        cbPixelFormat: UInt32 = 0,
        offPixelFormat: UInt32 = 0,
        bOpenGL: UInt32 = 0,
        micrometers: (UInt32, UInt32) = (0, 0),
        signature: UInt32 = 0x464D_4520
    ) -> [UInt8] {
        var b = FixtureBuilder()
        b.appendUInt32(1)                              // 0  iType = EMR_HEADER
        b.appendUInt32(recordSize ?? UInt32(fixedSize)) // 4  nSize
        b.appendInt32(bounds.0)                        // 8  rclBounds.left
        b.appendInt32(bounds.1)                        // 12 .top
        b.appendInt32(bounds.2)                        // 16 .right
        b.appendInt32(bounds.3)                        // 20 .bottom
        b.appendInt32(frame.0)                         // 24 rclFrame.left
        b.appendInt32(frame.1)                         // 28 .top
        b.appendInt32(frame.2)                         // 32 .right
        b.appendInt32(frame.3)                         // 36 .bottom
        b.appendUInt32(signature)                      // 40 RecordSignature
        b.appendUInt32(version)                        // 44 Version
        b.appendUInt32(bytesField)                     // 48 Bytes
        b.appendUInt32(recordsField)                   // 52 Records
        b.appendUInt16(handles)                        // 56 Handles
        b.appendUInt16(0)                              // 58 Reserved
        b.appendUInt32(nDescription)                   // 60 nDescription
        b.appendUInt32(offDescription)                 // 64 offDescription
        b.appendUInt32(nPalEntries)                    // 68 nPalEntries
        b.appendInt32(device.0)                        // 72 Device.cx
        b.appendInt32(device.1)                        // 76 Device.cy
        b.appendInt32(millimeters.0)                   // 80 Millimeters.cx
        b.appendInt32(millimeters.1)                   // 84 Millimeters.cy
        // Extension1 (88..100) and Extension2 (100..108) as needed. For
        // pixel-format-capped fixtures the "micrometers" bytes at 100..108
        // are actually pixel-format payload; the builder just writes them.
        if fixedSize >= 100 {
            b.appendUInt32(cbPixelFormat)              // 88 cbPixelFormat
            b.appendUInt32(offPixelFormat)             // 92 offPixelFormat
            b.appendUInt32(bOpenGL)                    // 96 bOpenGL
        }
        if fixedSize >= 108 {
            b.appendUInt32(micrometers.0)              // 100 MicrometersX
            b.appendUInt32(micrometers.1)              // 104 MicrometersY
        }
        return b.bytes
    }

    /// EMR_EOF (type 14). The real record is 20 bytes (nPalEntries,
    /// offPalEntries, SizeLast) but any well-formed >= 8, 4-aligned size is
    /// accepted by the phase-1 walker; 20 keeps fixtures realistic.
    static func eof(size: UInt32 = 20) -> [UInt8] {
        record(type: 14, size: size)
    }
}
