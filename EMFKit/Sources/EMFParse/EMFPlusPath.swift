import Foundation

// MARK: - Path model

/// The base kind of a path point, [MS-EMFPLUS] §2.1.1.22 PathPointType — the low
/// nibble of an EmfPlusPathPointType byte (§2.2.2.31).
public enum EMFPlusPathPointKind: Sendable, Equatable {
    case start    // 0x00 PathPointTypeStart
    case line     // 0x01 PathPointTypeLine
    case bezier   // 0x03 PathPointTypeBezier
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x00: self = .start
        case 0x01: self = .line
        case 0x03: self = .bezier
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .start: return 0x00
        case .line: return 0x01
        case .bezier: return 0x03
        case .unknown(let value): return value
        }
    }
}

/// A decoded EmfPlusPathPointType byte ([MS-EMFPLUS] §2.2.2.31): the low nibble
/// is the point kind (§2.1.1.22) and the high nibble carries PathPointType flags
/// (§2.1.2.6). The nibble split is corpus/GDI+ arbitrated, not read off the bit
/// diagram (which does not follow one consistent cell-numbering convention).
public struct EMFPlusPathPointType: Sendable, Equatable {
    /// The raw byte, kept verbatim (undocumented flag bits are tolerated).
    public let raw: UInt8

    public init(raw: UInt8) { self.raw = raw }

    /// Low nibble → [MS-EMFPLUS] §2.1.1.22 point kind.
    public var kind: EMFPlusPathPointKind { EMFPlusPathPointKind(rawValue: raw & 0x0F) }
    /// High nibble → [MS-EMFPLUS] §2.1.2.6 flags nibble.
    public var flags: UInt8 { (raw >> 4) & 0x0F }
    /// §2.1.2.6 PathPointTypeDashMode (0x01).
    public var isDashMode: Bool { flags & 0x01 != 0 }
    /// §2.1.2.6 PathPointTypePathMarker (0x02).
    public var isPathMarker: Bool { flags & 0x02 != 0 }
    /// §2.1.2.6 PathPointTypeCloseSubpath (0x08).
    public var isCloseSubpath: Bool { flags & 0x08 != 0 }
}

/// A decoded graphics path, [MS-EMFPLUS] §2.2.1.6 EmfPlusPath.
///
/// Points are unified to `[EMFPlusPointF]` regardless of on-wire encoding: an
/// absolute i16 EmfPlusPoint (§2.2.2.35) is widened to `Float` losslessly (the
/// ±32767 range fits exactly in a 24-bit significand), while an absolute
/// EmfPlusPointF (§2.2.2.36) is copied as-is. The raw `flags` word is kept so a
/// consumer can recover the original encoding — bit 0x4000 (C) means the points
/// were i16. Relative/RLE (R, bit 0x0800) paths are not decoded (no real file
/// uses them); such an object surfaces as `.malformed`.
public struct EMFPlusPath: Sendable, Equatable {
    public let version: UInt32
    /// PathPointCount as declared; equals `points.count` after a clean decode.
    public let pointCount: UInt32
    /// The raw PathPointFlags word (§2.2.1.6); mask-test it — GDI+ writes an
    /// undocumented 0x2000 bit with both encodings.
    public let flags: UInt32
    public let points: [EMFPlusPointF]
    /// The raw EmfPlusPathPointType bytes (§2.2.2.31), one per point. Use
    /// `decodedPointTypes` for the kind/flags view.
    public let pointTypes: [UInt8]

    public init(version: UInt32, pointCount: UInt32, flags: UInt32, points: [EMFPlusPointF], pointTypes: [UInt8]) {
        self.version = version
        self.pointCount = pointCount
        self.flags = flags
        self.points = points
        self.pointTypes = pointTypes
    }

    /// The point types decoded into kind + flags (§2.2.2.31).
    public var decodedPointTypes: [EMFPlusPathPointType] { pointTypes.map { EMFPlusPathPointType(raw: $0) } }

    /// True when the C flag is set with R clear: the points were absolute i16
    /// EmfPlusPoint objects (§2.2.2.35), widened to `Float` on decode.
    public var usesAbsoluteInt16Points: Bool {
        (flags & PathPointFlag.relative) == 0 && (flags & PathPointFlag.compressed) != 0
    }
}

// MARK: - Path decode

/// PathPointFlags masks ([MS-EMFPLUS] §2.2.1.6). Corpus-arbitrated, NOT
/// diagram-derived: C = 0x4000 (absolute i16 points when set, R clear),
/// R = 0x0800 (relative points + RLE point types).
enum PathPointFlag {
    static let compressed: UInt32 = 0x0000_4000   // C
    static let relative: UInt32 = 0x0000_0800     // R
}

/// Decodes an EmfPlusPath ([MS-EMFPLUS] §2.2.1.6): Version, PathPointCount,
/// PathPointFlags, then PathPoints and one PathPointType byte per point, with up
/// to 3 trailing AlignmentPadding bytes ignored. Shared by the standalone Path
/// object and by a region node's embedded boundary path.
func decodePath(_ cursor: inout ByteCursor)
    -> Result<EMFPlusPath, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPath.Version"))
    }
    guard let pointCount = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPath.PathPointCount"))
    }
    guard let flags = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPath.PathPointFlags"))
    }

    // Relative/RLE encoding is not decoded (§2.2.1.6 R flag; no real file uses it).
    if flags & PathPointFlag.relative != 0 {
        return .failure(.relativePathEncodingUnsupported)
    }

    let count = Int(pointCount)
    // R clear: C set → i16 EmfPlusPoint (4 bytes); C clear → EmfPlusPointF (8 bytes).
    let usesInt16 = (flags & PathPointFlag.compressed) != 0
    let pointSize = usesInt16 ? 4 : 8

    // Validate BOTH arrays (points: count*pointSize, types: count*1) against the
    // remaining bytes before allocating anything. `count <= remaining/(pointSize+1)`
    // implies `count*(pointSize+1) <= remaining` without overflow.
    let remaining = cursor.remaining
    guard count >= 0, count <= remaining / (pointSize + 1) else {
        return .failure(.arrayCountExceedsBuffer(
            field: "EmfPlusPath.PathPoints", count: pointCount, remainingBytes: remaining))
    }

    var points: [EMFPlusPointF] = []
    points.reserveCapacity(count)
    if usesInt16 {
        for _ in 0 ..< count {
            // EmfPlusPoint (§2.2.2.35): X (i16), Y (i16) — one little-endian u32.
            guard let packed = cursor.readUInt32() else {
                return .failure(.truncated(field: "EmfPlusPath.PathPoints"))
            }
            let x = Int16(bitPattern: UInt16(packed & 0xFFFF))
            let y = Int16(bitPattern: UInt16((packed >> 16) & 0xFFFF))
            points.append(EMFPlusPointF(x: Float(x), y: Float(y)))
        }
    } else {
        guard let decoded = cursor.readPointFs(count: count) else {
            return .failure(.truncated(field: "EmfPlusPath.PathPoints"))
        }
        points = decoded
    }

    // PathPointTypes (§2.2.2.31): one byte per point. Bounds already validated.
    guard let typeBytes = cursor.readBytes(count) else {
        return .failure(.truncated(field: "EmfPlusPath.PathPointTypes"))
    }

    return .success(EMFPlusPath(
        version: version, pointCount: pointCount, flags: flags,
        points: points, pointTypes: Array(typeBytes)))
}
