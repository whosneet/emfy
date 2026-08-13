import Foundation

/// A color, [MS-EMFPLUS] §2.2.2.1 EmfPlusARGB. The four channels are stored in
/// their wire order — Blue, Green, Red, Alpha — so no swizzling is implied: a
/// single little-endian u32 read of the object is `0xAARRGGBB`.
public struct EMFPlusARGB: Sendable, Equatable {
    public let blue: UInt8
    public let green: UInt8
    public let red: UInt8
    public let alpha: UInt8

    public init(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        self.blue = blue
        self.green = green
        self.red = red
        self.alpha = alpha
    }
}

/// A floating-point rectangle, [MS-EMFPLUS] §2.2.2.39 EmfPlusRectF: origin plus
/// width/height (NOT left/top/right/bottom).
public struct EMFPlusRectF: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A floating-point point, [MS-EMFPLUS] §2.2.2.36 EmfPlusPointF.
public struct EMFPlusPointF: Sendable, Equatable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// A 2x3 affine transform, [MS-EMFPLUS] §2.2.2.47 EmfPlusTransformMatrix: the six
/// values are m11, m12, m21, m22, dx, dy in that order.
public struct EMFPlusTransformMatrix: Sendable, Equatable {
    public let m11: Float
    public let m12: Float
    public let m21: Float
    public let m22: Float
    public let dx: Float
    public let dy: Float

    public init(m11: Float, m12: Float, m21: Float, m22: Float, dx: Float, dy: Float) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.dx = dx
        self.dy = dy
    }
}

/// Why a typed object payload could not be fully decoded (primer §8: decoders
/// return typed failures, never force-unwrap or misalign). The whole object
/// becomes `EMFPlusObjectValue.malformed` rather than a partially-misread value.
public enum EMFPlusObjectDecodeFailure: Error, Sendable, Equatable {
    /// A fixed field or block ran past the end of the object payload.
    case truncated(field: String)
    /// A brush `Type` value not defined in [MS-EMFPLUS] §2.1.1.3 BrushType.
    case unknownBrushType(raw: UInt32)
    /// A self-described element count (a gradient or dash/compound array) claimed
    /// more elements than the remaining bytes can hold — a lying count.
    case arrayCountExceedsBuffer(field: String, count: UInt32, remainingBytes: Int)
    /// A length-prefixed custom line cap declared more bytes than remain.
    case customCapSizeExceedsBuffer(field: String, size: UInt32, remainingBytes: Int)
    /// An EmfPlusPath set the R (relative/RLE) flag ([MS-EMFPLUS] §2.2.1.6). No
    /// real file uses it, so EmfPlusPointR/RLE is not decoded speculatively.
    case relativePathEncodingUnsupported
    /// An EmfPlusRegionNode carried a Type not in [MS-EMFPLUS] §2.1.1.26.
    case unknownRegionNodeType(raw: UInt32)
    /// A region node tree exceeded the recursion-depth cap (hostile-input guard,
    /// primer §8) — decoding stops rather than risking a stack overflow.
    case regionTreeTooDeep
    /// A region node tree exceeded the total-node cap (hostile-input guard).
    case regionTooManyNodes
}

/// The decoded value of an `EMFPlusObjectDefinition`. Only Brush and Pen are
/// decoded in this increment; other object types are returned raw as `undecoded`
/// for a later increment, and any structural dead-end yields `malformed`.
public enum EMFPlusObjectValue: Sendable, Equatable {
    case brush(EMFPlusBrush)
    case pen(EMFPlusPen)
    case path(EMFPlusPath)
    case region(EMFPlusRegion)
    /// A type not decoded yet (Image, Font, StringFormat, ImageAttributes,
    /// standalone CustomLineCap, Invalid, unknown).
    case undecoded(type: EMFPlusObjectType, data: Data)
    /// A Brush or Pen whose structure could not be decoded (primer §8).
    case malformed(type: EMFPlusObjectType, reason: EMFPlusObjectDecodeFailure)
}

extension EMFPlusObjectDefinition {
    /// Decodes this object's payload into a typed value. Brush ([MS-EMFPLUS]
    /// §2.2.1.1), Pen (§2.2.1.7), Path (§2.2.1.6), and Region (§2.2.1.8) are
    /// decoded; every other type is returned as `.undecoded`. A malformed
    /// object returns `.malformed` and never traps.
    public func decodedValue() -> EMFPlusObjectValue {
        switch objectType {
        case .brush:
            var cursor = ByteCursor(data)
            switch decodeBrush(&cursor) {
            case .success(let brush): return .brush(brush)
            case .failure(let reason): return .malformed(type: objectType, reason: reason)
            }
        case .pen:
            var cursor = ByteCursor(data)
            switch decodePen(&cursor) {
            case .success(let pen): return .pen(pen)
            case .failure(let reason): return .malformed(type: objectType, reason: reason)
            }
        case .path:
            var cursor = ByteCursor(data)
            switch decodePath(&cursor) {
            case .success(let path): return .path(path)
            case .failure(let reason): return .malformed(type: objectType, reason: reason)
            }
        case .region:
            var cursor = ByteCursor(data)
            switch decodeRegion(&cursor) {
            case .success(let region): return .region(region)
            case .failure(let reason): return .malformed(type: objectType, reason: reason)
            }
        default:
            return .undecoded(type: objectType, data: data)
        }
    }
}

/// A bounds-checked, little-endian sequential reader over one object payload.
///
/// Wraps `ByteReader` (which normalises to a zero-based `[UInt8]`, so a slice's
/// `startIndex` cannot corrupt reads) and tracks a cursor. Every read is
/// bounds-checked and returns `nil` on overrun, advancing only on success —
/// nothing here can force-unwrap, overflow, or over-allocate. Floats are read
/// via their bit pattern ([MS-EMF] §2.2.28 / IEEE-754).
struct ByteCursor {
    private let reader: ByteReader
    private(set) var offset: Int

    init(_ data: Data) {
        self.reader = ByteReader(data)
        self.offset = 0
    }

    /// Bytes not yet consumed.
    var remaining: Int { reader.count - offset }

    mutating func readUInt32() -> UInt32? {
        guard let value = reader.readUInt32(at: offset) else { return nil }
        offset += 4
        return value
    }

    mutating func readInt32() -> Int32? {
        guard let value = reader.readInt32(at: offset) else { return nil }
        offset += 4
        return value
    }

    mutating func readFloat() -> Float? {
        guard let bits = reader.readUInt32(at: offset) else { return nil }
        offset += 4
        return Float(bitPattern: bits)
    }

    /// Reads an EmfPlusARGB (§2.2.2.1): the low byte of the u32 is Blue.
    mutating func readARGB() -> EMFPlusARGB? {
        guard let value = reader.readUInt32(at: offset) else { return nil }
        offset += 4
        return EMFPlusARGB(
            blue: UInt8(value & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            red: UInt8((value >> 16) & 0xFF),
            alpha: UInt8((value >> 24) & 0xFF))
    }

    /// Returns `length` bytes as a fresh zero-based `Data`, or `nil` if fewer
    /// remain. `length` 0 returns empty `Data`.
    mutating func readBytes(_ length: Int) -> Data? {
        guard length >= 0, let bytes = reader.data(at: offset, length: length) else { return nil }
        offset += length
        return bytes
    }

    /// Reads `count` little-endian floats, or `nil` if `count` is negative or the
    /// `count * 4` bytes are not all present (a lying count fails before any
    /// allocation).
    mutating func readFloats(count: Int) -> [Float]? {
        guard count >= 0, count <= remaining / 4 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let value = readFloat() else { return nil }
            values.append(value)
        }
        return values
    }

    /// Reads `count` EmfPlusARGB colors, or `nil` if `count` is negative or the
    /// `count * 4` bytes are not all present.
    mutating func readARGBArray(count: Int) -> [EMFPlusARGB]? {
        guard count >= 0, count <= remaining / 4 else { return nil }
        var values: [EMFPlusARGB] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let value = readARGB() else { return nil }
            values.append(value)
        }
        return values
    }

    /// Reads `count` EmfPlusPointF points, or `nil` if `count` is negative or the
    /// `count * 8` bytes are not all present.
    mutating func readPointFs(count: Int) -> [EMFPlusPointF]? {
        guard count >= 0, count <= remaining / 8 else { return nil }
        var values: [EMFPlusPointF] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            guard let x = readFloat(), let y = readFloat() else { return nil }
            values.append(EMFPlusPointF(x: x, y: y))
        }
        return values
    }

    /// Reads a 24-byte EmfPlusTransformMatrix (§2.2.2.47).
    mutating func readTransformMatrix() -> EMFPlusTransformMatrix? {
        guard let m11 = readFloat(), let m12 = readFloat(), let m21 = readFloat(),
              let m22 = readFloat(), let dx = readFloat(), let dy = readFloat() else { return nil }
        return EMFPlusTransformMatrix(m11: m11, m12: m12, m21: m21, m22: m22, dx: dx, dy: dy)
    }
}
