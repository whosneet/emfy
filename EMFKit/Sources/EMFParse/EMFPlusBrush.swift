import Foundation

// MARK: - Brush model

/// The kind of brush, [MS-EMFPLUS] §2.1.1.3 BrushType. `unknown` preserves any
/// undefined value.
public enum EMFPlusBrushType: Sendable, Equatable {
    case solid           // 0x00 BrushTypeSolidColor
    case hatch           // 0x01 BrushTypeHatchFill
    case texture         // 0x02 BrushTypeTextureFill
    case pathGradient    // 0x03 BrushTypePathGradient
    case linearGradient  // 0x04 BrushTypeLinearGradient
    case unknown(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0x00: self = .solid
        case 0x01: self = .hatch
        case 0x02: self = .texture
        case 0x03: self = .pathGradient
        case 0x04: self = .linearGradient
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt32 {
        switch self {
        case .solid: return 0x00
        case .hatch: return 0x01
        case .texture: return 0x02
        case .pathGradient: return 0x03
        case .linearGradient: return 0x04
        case .unknown(let value): return value
        }
    }
}

/// A hatch pattern, [MS-EMFPLUS] §2.1.1.13 HatchStyle. Named cases cover the six
/// basic patterns (0x00…0x05); every other of the 50+ styles is preserved raw.
public enum EMFPlusHatchStyle: Sendable, Equatable {
    case horizontal        // 0x00
    case vertical          // 0x01
    case forwardDiagonal   // 0x02
    case backwardDiagonal  // 0x03
    case largeGrid         // 0x04
    case diagonalCross     // 0x05
    case other(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0x00: self = .horizontal
        case 0x01: self = .vertical
        case 0x02: self = .forwardDiagonal
        case 0x03: self = .backwardDiagonal
        case 0x04: self = .largeGrid
        case 0x05: self = .diagonalCross
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt32 {
        switch self {
        case .horizontal: return 0x00
        case .vertical: return 0x01
        case .forwardDiagonal: return 0x02
        case .backwardDiagonal: return 0x03
        case .largeGrid: return 0x04
        case .diagonalCross: return 0x05
        case .other(let value): return value
        }
    }
}

/// Position/color blend of a gradient, [MS-EMFPLUS] §2.2.2.4 EmfPlusBlendColors.
public struct EMFPlusBlendColors: Sendable, Equatable {
    public let positions: [Float]
    public let colors: [EMFPlusARGB]

    public init(positions: [Float], colors: [EMFPlusARGB]) {
        self.positions = positions
        self.colors = colors
    }
}

/// Position/factor blend of a gradient, [MS-EMFPLUS] §2.2.2.5 EmfPlusBlendFactors.
public struct EMFPlusBlendFactors: Sendable, Equatable {
    public let positions: [Float]
    public let factors: [Float]

    public init(positions: [Float], factors: [Float]) {
        self.positions = positions
        self.factors = factors
    }
}

/// The optional blend pattern of a gradient brush ([MS-EMFPLUS] §2.2.2.25 /
/// §2.2.2.30): either preset colors, or one-or-two blend-factor arrays. For a
/// linear gradient with both the horizontal and vertical flags set, the two
/// arrays are in stream order (vertical then horizontal per the §2.2.2.25 table).
public enum EMFPlusGradientBlend: Sendable, Equatable {
    case presetColors(EMFPlusBlendColors)
    case blendFactors([EMFPlusBlendFactors])
}

/// Focus scales for a path gradient, [MS-EMFPLUS] §2.2.2.18 EmfPlusFocusScaleData.
public struct EMFPlusFocusScale: Sendable, Equatable {
    public let count: UInt32
    public let x: Float
    public let y: Float

    public init(count: UInt32, x: Float, y: Float) {
        self.count = count
        self.x = x
        self.y = y
    }
}

/// A linear gradient brush, [MS-EMFPLUS] §2.2.2.24 (+ §2.2.2.25 optional data).
public struct EMFPlusLinearGradientBrush: Sendable, Equatable {
    public let brushDataFlags: UInt32
    public let wrapMode: Int32
    public let rect: EMFPlusRectF
    public let startColor: EMFPlusARGB
    public let endColor: EMFPlusARGB
    public let reserved1: UInt32
    public let reserved2: UInt32
    /// Present iff the BrushDataTransform flag is set.
    public let transform: EMFPlusTransformMatrix?
    /// Present per the preset/blend-factor flags; absent for a plain two-color
    /// gradient.
    public let blend: EMFPlusGradientBlend?

    public init(
        brushDataFlags: UInt32, wrapMode: Int32, rect: EMFPlusRectF,
        startColor: EMFPlusARGB, endColor: EMFPlusARGB, reserved1: UInt32, reserved2: UInt32,
        transform: EMFPlusTransformMatrix?, blend: EMFPlusGradientBlend?
    ) {
        self.brushDataFlags = brushDataFlags
        self.wrapMode = wrapMode
        self.rect = rect
        self.startColor = startColor
        self.endColor = endColor
        self.reserved1 = reserved1
        self.reserved2 = reserved2
        self.transform = transform
        self.blend = blend
    }
}

/// The boundary of a path gradient brush ([MS-EMFPLUS] §2.2.2.29 BoundaryData).
public enum EMFPlusPathGradientBoundary: Sendable, Equatable {
    /// An EmfPlusBoundaryPathData path (§2.2.2.6). The EmfPlusPath bytes are kept
    /// raw; path decode belongs to a later increment.
    case path(raw: Data)
    /// An EmfPlusBoundaryPointData closed cardinal spline (§2.2.2.7).
    case points([EMFPlusPointF])
}

/// A path gradient brush, [MS-EMFPLUS] §2.2.2.29 (+ §2.2.2.30 optional data).
///
/// The fixed prelude, surrounding colors, and boundary are decoded structurally.
/// If a sub-structure from the boundary onward resists a confident decode, the
/// bytes that could not be interpreted are captured in `undecodedTail` and the
/// partial brush is returned rather than guessing (primer §8).
public struct EMFPlusPathGradientBrush: Sendable, Equatable {
    public let brushDataFlags: UInt32
    public let wrapMode: Int32
    public let centerColor: EMFPlusARGB
    public let centerPoint: EMFPlusPointF
    public let surroundingColors: [EMFPlusARGB]
    public let boundary: EMFPlusPathGradientBoundary?
    public let transform: EMFPlusTransformMatrix?
    public let blend: EMFPlusGradientBlend?
    public let focusScale: EMFPlusFocusScale?
    /// Non-nil when decoding stopped early: the remaining, uninterpreted bytes.
    public let undecodedTail: Data?

    public init(
        brushDataFlags: UInt32, wrapMode: Int32, centerColor: EMFPlusARGB,
        centerPoint: EMFPlusPointF, surroundingColors: [EMFPlusARGB],
        boundary: EMFPlusPathGradientBoundary?, transform: EMFPlusTransformMatrix?,
        blend: EMFPlusGradientBlend?, focusScale: EMFPlusFocusScale?, undecodedTail: Data?
    ) {
        self.brushDataFlags = brushDataFlags
        self.wrapMode = wrapMode
        self.centerColor = centerColor
        self.centerPoint = centerPoint
        self.surroundingColors = surroundingColors
        self.boundary = boundary
        self.transform = transform
        self.blend = blend
        self.focusScale = focusScale
        self.undecodedTail = undecodedTail
    }
}

/// The type-specific data of a brush ([MS-EMFPLUS] §2.2.1.1 BrushData).
public enum EMFPlusBrushData: Sendable, Equatable {
    case solid(EMFPlusARGB)                                                    // §2.2.2.43
    case hatch(style: EMFPlusHatchStyle, foreColor: EMFPlusARGB, backColor: EMFPlusARGB)  // §2.2.2.20
    case linearGradient(EMFPlusLinearGradientBrush)                           // §2.2.2.24
    case pathGradient(EMFPlusPathGradientBrush)                               // §2.2.2.29
    /// A texture brush (§2.2.2.45): the bitmap is not decoded in this increment
    /// (images are a later increment). BrushData is the brush's final field, so
    /// capturing the remaining bytes is structurally safe.
    case texture(raw: Data)
}

/// A decoded brush, [MS-EMFPLUS] §2.2.1.1 EmfPlusBrush.
public struct EMFPlusBrush: Sendable, Equatable {
    public let version: UInt32
    public let brushType: EMFPlusBrushType
    public let data: EMFPlusBrushData

    public init(version: UInt32, brushType: EMFPlusBrushType, data: EMFPlusBrushData) {
        self.version = version
        self.brushType = brushType
        self.data = data
    }
}

// MARK: - Brush decode

/// BrushData flag masks, [MS-EMFPLUS] §2.1.2.1 (verified against the spec prose).
private enum BrushDataFlag {
    static let path: UInt32 = 0x0000_0001
    static let transform: UInt32 = 0x0000_0002
    static let presetColors: UInt32 = 0x0000_0004
    static let blendFactorsH: UInt32 = 0x0000_0008
    static let blendFactorsV: UInt32 = 0x0000_0010
    static let focusScales: UInt32 = 0x0000_0040
}

/// Decodes an EmfPlusBrush ([MS-EMFPLUS] §2.2.1.1): Version, Type, then BrushData
/// by type. Used both for a standalone brush object and for the BrushObject
/// embedded at the end of a pen.
func decodeBrush(_ cursor: inout ByteCursor)
    -> Result<EMFPlusBrush, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusBrush.Version"))
    }
    guard let typeRaw = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusBrush.Type"))
    }
    let brushType = EMFPlusBrushType(rawValue: typeRaw)

    let data: EMFPlusBrushData
    switch brushType {
    case .solid:
        // §2.2.2.43 EmfPlusSolidBrushData: SolidColor (ARGB).
        guard let color = cursor.readARGB() else {
            return .failure(.truncated(field: "EmfPlusSolidBrushData.SolidColor"))
        }
        data = .solid(color)

    case .hatch:
        // §2.2.2.20 EmfPlusHatchBrushData: HatchStyle, ForeColor, BackColor.
        guard let style = cursor.readUInt32() else {
            return .failure(.truncated(field: "EmfPlusHatchBrushData.HatchStyle"))
        }
        guard let foreColor = cursor.readARGB() else {
            return .failure(.truncated(field: "EmfPlusHatchBrushData.ForeColor"))
        }
        guard let backColor = cursor.readARGB() else {
            return .failure(.truncated(field: "EmfPlusHatchBrushData.BackColor"))
        }
        data = .hatch(style: EMFPlusHatchStyle(rawValue: style), foreColor: foreColor, backColor: backColor)

    case .linearGradient:
        switch decodeLinearGradient(&cursor) {
        case .success(let brush): data = .linearGradient(brush)
        case .failure(let reason): return .failure(reason)
        }

    case .pathGradient:
        switch decodePathGradient(&cursor) {
        case .success(let brush): data = .pathGradient(brush)
        case .failure(let reason): return .failure(reason)
        }

    case .texture:
        data = .texture(raw: cursor.readBytes(cursor.remaining) ?? Data())

    case .unknown(let raw):
        return .failure(.unknownBrushType(raw: raw))
    }

    return .success(EMFPlusBrush(version: version, brushType: brushType, data: data))
}

/// Decodes EmfPlusLinearGradientBrushData ([MS-EMFPLUS] §2.2.2.24) and its
/// optional data (§2.2.2.25). Field order: BrushDataFlags, WrapMode, RectF,
/// StartColor, EndColor, Reserved1, Reserved2, then optional TransformMatrix and
/// a blend pattern gated by the BrushData flags.
private func decodeLinearGradient(_ cursor: inout ByteCursor)
    -> Result<EMFPlusLinearGradientBrush, EMFPlusObjectDecodeFailure> {
    guard let flags = cursor.readUInt32() else {
        return .failure(.truncated(field: "LinearGradient.BrushDataFlags"))
    }
    guard let wrapMode = cursor.readInt32() else {
        return .failure(.truncated(field: "LinearGradient.WrapMode"))
    }
    guard let x = cursor.readFloat(), let y = cursor.readFloat(),
          let width = cursor.readFloat(), let height = cursor.readFloat() else {
        return .failure(.truncated(field: "LinearGradient.RectF"))
    }
    guard let startColor = cursor.readARGB() else {
        return .failure(.truncated(field: "LinearGradient.StartColor"))
    }
    guard let endColor = cursor.readARGB() else {
        return .failure(.truncated(field: "LinearGradient.EndColor"))
    }
    guard let reserved1 = cursor.readUInt32() else {
        return .failure(.truncated(field: "LinearGradient.Reserved1"))
    }
    guard let reserved2 = cursor.readUInt32() else {
        return .failure(.truncated(field: "LinearGradient.Reserved2"))
    }

    var transform: EMFPlusTransformMatrix?
    if flags & BrushDataFlag.transform != 0 {
        guard let matrix = cursor.readTransformMatrix() else {
            return .failure(.truncated(field: "LinearGradient.TransformMatrix"))
        }
        transform = matrix
    }

    var blend: EMFPlusGradientBlend?
    if flags & BrushDataFlag.presetColors != 0 {
        switch decodeBlendColors(&cursor, field: "LinearGradient") {
        case .success(let colors): blend = .presetColors(colors)
        case .failure(let reason): return .failure(reason)
        }
    } else if (flags & BrushDataFlag.blendFactorsH != 0) || (flags & BrushDataFlag.blendFactorsV != 0) {
        // §2.2.2.25 table: vertical array precedes horizontal when both are set.
        var arrays: [EMFPlusBlendFactors] = []
        if flags & BrushDataFlag.blendFactorsV != 0 {
            switch decodeBlendFactors(&cursor, field: "LinearGradient.Vertical") {
            case .success(let factors): arrays.append(factors)
            case .failure(let reason): return .failure(reason)
            }
        }
        if flags & BrushDataFlag.blendFactorsH != 0 {
            switch decodeBlendFactors(&cursor, field: "LinearGradient.Horizontal") {
            case .success(let factors): arrays.append(factors)
            case .failure(let reason): return .failure(reason)
            }
        }
        blend = .blendFactors(arrays)
    }

    return .success(EMFPlusLinearGradientBrush(
        brushDataFlags: flags, wrapMode: wrapMode,
        rect: EMFPlusRectF(x: x, y: y, width: width, height: height),
        startColor: startColor, endColor: endColor,
        reserved1: reserved1, reserved2: reserved2,
        transform: transform, blend: blend))
}

/// Decodes EmfPlusPathGradientBrushData ([MS-EMFPLUS] §2.2.2.29) and its optional
/// data (§2.2.2.30). The prelude and surrounding colors are mandatory; from the
/// boundary onward, decode is best-effort with an `undecodedTail` fallback.
private func decodePathGradient(_ cursor: inout ByteCursor)
    -> Result<EMFPlusPathGradientBrush, EMFPlusObjectDecodeFailure> {
    guard let flags = cursor.readUInt32() else {
        return .failure(.truncated(field: "PathGradient.BrushDataFlags"))
    }
    guard let wrapMode = cursor.readInt32() else {
        return .failure(.truncated(field: "PathGradient.WrapMode"))
    }
    guard let centerColor = cursor.readARGB() else {
        return .failure(.truncated(field: "PathGradient.CenterColor"))
    }
    guard let centerX = cursor.readFloat(), let centerY = cursor.readFloat() else {
        return .failure(.truncated(field: "PathGradient.CenterPointF"))
    }
    guard let surroundingCount = cursor.readUInt32() else {
        return .failure(.truncated(field: "PathGradient.SurroundingColorCount"))
    }
    guard let surroundingColors = cursor.readARGBArray(count: Int(surroundingCount)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: "PathGradient.SurroundingColor", count: surroundingCount,
            remainingBytes: cursor.remaining))
    }

    var boundary: EMFPlusPathGradientBoundary?
    var transform: EMFPlusTransformMatrix?
    var blend: EMFPlusGradientBlend?
    var focusScale: EMFPlusFocusScale?

    // Returns the partial brush, capturing whatever bytes remain uninterpreted.
    func partial() -> Result<EMFPlusPathGradientBrush, EMFPlusObjectDecodeFailure> {
        let tail = cursor.readBytes(cursor.remaining) ?? Data()
        return .success(EMFPlusPathGradientBrush(
            brushDataFlags: flags, wrapMode: wrapMode, centerColor: centerColor,
            centerPoint: EMFPlusPointF(x: centerX, y: centerY),
            surroundingColors: surroundingColors, boundary: boundary,
            transform: transform, blend: blend, focusScale: focusScale,
            undecodedTail: tail.isEmpty ? nil : tail))
    }

    // Boundary (§2.2.2.6 path or §2.2.2.7 points, per the BrushDataPath flag).
    if flags & BrushDataFlag.path != 0 {
        guard let size = cursor.readInt32(), size >= 0,
              let pathBytes = cursor.readBytes(Int(size)) else {
            return partial()
        }
        boundary = .path(raw: pathBytes)
    } else {
        guard let count = cursor.readInt32(), count >= 0,
              let points = cursor.readPointFs(count: Int(count)) else {
            return partial()
        }
        boundary = .points(points)
    }

    if flags & BrushDataFlag.transform != 0 {
        guard let matrix = cursor.readTransformMatrix() else { return partial() }
        transform = matrix
    }

    if flags & BrushDataFlag.presetColors != 0 {
        switch decodeBlendColors(&cursor, field: "PathGradient") {
        case .success(let colors): blend = .presetColors(colors)
        case .failure: return partial()
        }
    } else if flags & BrushDataFlag.blendFactorsH != 0 {
        switch decodeBlendFactors(&cursor, field: "PathGradient") {
        case .success(let factors): blend = .blendFactors([factors])
        case .failure: return partial()
        }
    }

    if flags & BrushDataFlag.focusScales != 0 {
        guard let count = cursor.readUInt32(), let fx = cursor.readFloat(),
              let fy = cursor.readFloat() else { return partial() }
        focusScale = EMFPlusFocusScale(count: count, x: fx, y: fy)
    }

    return .success(EMFPlusPathGradientBrush(
        brushDataFlags: flags, wrapMode: wrapMode, centerColor: centerColor,
        centerPoint: EMFPlusPointF(x: centerX, y: centerY),
        surroundingColors: surroundingColors, boundary: boundary,
        transform: transform, blend: blend, focusScale: focusScale, undecodedTail: nil))
}

/// Decodes an EmfPlusBlendColors ([MS-EMFPLUS] §2.2.2.4): PositionCount, then
/// PositionCount floats and PositionCount ARGB colors.
private func decodeBlendColors(_ cursor: inout ByteCursor, field: String)
    -> Result<EMFPlusBlendColors, EMFPlusObjectDecodeFailure> {
    guard let count = cursor.readUInt32() else {
        return .failure(.truncated(field: field + ".BlendColors.PositionCount"))
    }
    guard let positions = cursor.readFloats(count: Int(count)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: field + ".BlendColors.BlendPositions", count: count, remainingBytes: cursor.remaining))
    }
    guard let colors = cursor.readARGBArray(count: Int(count)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: field + ".BlendColors.BlendColors", count: count, remainingBytes: cursor.remaining))
    }
    return .success(EMFPlusBlendColors(positions: positions, colors: colors))
}

/// Decodes an EmfPlusBlendFactors ([MS-EMFPLUS] §2.2.2.5): PositionCount, then
/// PositionCount position floats and PositionCount factor floats.
private func decodeBlendFactors(_ cursor: inout ByteCursor, field: String)
    -> Result<EMFPlusBlendFactors, EMFPlusObjectDecodeFailure> {
    guard let count = cursor.readUInt32() else {
        return .failure(.truncated(field: field + ".BlendFactors.PositionCount"))
    }
    guard let positions = cursor.readFloats(count: Int(count)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: field + ".BlendFactors.BlendPositions", count: count, remainingBytes: cursor.remaining))
    }
    guard let factors = cursor.readFloats(count: Int(count)) else {
        return .failure(.arrayCountExceedsBuffer(
            field: field + ".BlendFactors.BlendFactors", count: count, remainingBytes: cursor.remaining))
    }
    return .success(EMFPlusBlendFactors(positions: positions, factors: factors))
}
