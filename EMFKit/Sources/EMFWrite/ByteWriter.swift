import Foundation
import EMFParse

/// A little-endian byte-buffer builder — the write-side mirror of EMFParse's
/// `ByteReader`. Every append writes in EMF's native little-endian order so the
/// bytes produced read back exactly as the on-disk format ([MS-EMF] §1.3.1).
///
/// Nothing here can trap: every value is written byte by byte from a shift/mask,
/// never from an unchecked conversion. Count validation (does a declared array
/// fit a UInt32 size field?) is the record encoders' job, before they call in.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    init(capacity: Int) {
        bytes.reserveCapacity(max(capacity, 0))
    }

    /// Current length in bytes.
    var count: Int { bytes.count }

    mutating func appendUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendInt16(_ value: Int16) {
        appendUInt16(UInt16(bitPattern: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    /// A little-endian FLOAT via its bit pattern ([MS-EMF] §2.2.28). The
    /// decoder reads floats the same way, so finite and non-finite values both
    /// round-trip bit-exactly.
    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }

    /// A RectL in file order: left, top, right, bottom (each i32, [MS-WMF]
    /// §2.2.2.19).
    mutating func appendRectL(_ rect: RectL) {
        appendInt32(rect.left)
        appendInt32(rect.top)
        appendInt32(rect.right)
        appendInt32(rect.bottom)
    }

    /// A PointL: x then y (each i32, [MS-WMF] §2.2.2.15).
    mutating func appendPointL(_ point: PointL) {
        appendInt32(point.x)
        appendInt32(point.y)
    }

    /// A PointS: x then y (each i16, [MS-WMF] §2.2.2.16).
    mutating func appendPointS(_ point: PointS) {
        appendInt16(point.x)
        appendInt16(point.y)
    }

    /// A SizeL: cx then cy (each i32, [MS-EMF] §2.2.21).
    mutating func appendSizeL(_ size: SizeL) {
        appendInt32(size.cx)
        appendInt32(size.cy)
    }

    /// A ColorRef in on-disk order Red, Green, Blue, Reserved ([MS-WMF]
    /// §2.2.2.8).
    mutating func appendColorRef(_ color: ColorRef) {
        bytes.append(color.red)
        bytes.append(color.green)
        bytes.append(color.blue)
        bytes.append(color.reserved)
    }

    /// An XForm: six FLOATs in file order M11, M12, M21, M22, Dx, Dy
    /// ([MS-EMF] §2.2.28).
    mutating func appendXForm(_ xform: XForm) {
        appendFloat(xform.m11)
        appendFloat(xform.m12)
        appendFloat(xform.m21)
        appendFloat(xform.m22)
        appendFloat(xform.dx)
        appendFloat(xform.dy)
    }

    /// `string` as UTF-16LE code units, exactly as the string carries them (no
    /// length prefix, no terminator).
    mutating func appendUTF16LE(_ string: String) {
        for unit in string.utf16 {
            appendUInt16(unit)
        }
    }

    mutating func appendBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func appendData(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    mutating func appendZeros(_ n: Int) {
        guard n > 0 else { return }
        bytes.append(contentsOf: repeatElement(0, count: n))
    }

    /// Pads with zeros until the length is a multiple of 4 ([MS-EMF] §2.3: a
    /// record's `nSize` is always a multiple of 4).
    mutating func padTo4() {
        appendZeros((4 - (bytes.count % 4)) % 4)
    }

    var data: Data { Data(bytes) }
}

/// Overwrites four little-endian bytes of `buffer` at `offset` with `value`.
/// Used to patch the header's recomputed Bytes/Records fields after the rest of
/// the file is laid out. Bounds-checked: a short buffer is a no-op (the caller
/// has already sized the header, so this never fires in practice).
func patchUInt32(_ buffer: inout [UInt8], at offset: Int, _ value: UInt32) {
    guard offset >= 0, offset <= buffer.count - 4 else { return }
    buffer[offset] = UInt8(value & 0xFF)
    buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
    buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
}

/// Overwrites two little-endian bytes of `buffer` at `offset` with `value`
/// (the header's recomputed Handles field, a UInt16).
func patchUInt16(_ buffer: inout [UInt8], at offset: Int, _ value: UInt16) {
    guard offset >= 0, offset <= buffer.count - 2 else { return }
    buffer[offset] = UInt8(value & 0xFF)
    buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
}
