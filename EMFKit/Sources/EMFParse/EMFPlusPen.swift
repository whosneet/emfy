import Foundation

// MARK: - Pen model

/// Properties of a graphics pen, [MS-EMFPLUS] §2.2.2.33 EmfPlusPenData plus its
/// optional data (§2.2.2.34). Every optional field is present iff the matching
/// [MS-EMFPLUS] §2.1.2.7 flag is set in `flags`.
public struct EMFPlusPenData: Sendable, Equatable {
    public let flags: UInt32
    /// PenUnit, a §2.1.1.32 UnitType. Every real pen uses UnitTypeWorld (0).
    public let unit: UInt32
    public let width: Float
    public let transform: EMFPlusTransformMatrix?       // PenDataTransform 0x1
    public let startCap: Int32?                         // PenDataStartCap 0x2
    public let endCap: Int32?                           // PenDataEndCap 0x4
    public let join: Int32?                             // PenDataJoin 0x8
    public let miterLimit: Float?                       // PenDataMiterLimit 0x10
    public let lineStyle: Int32?                        // PenDataLineStyle 0x20
    public let dashedLineCap: Int32?                    // PenDataDashedLineCap 0x40
    public let dashOffset: Float?                       // PenDataDashedLineOffset 0x80
    public let dashedLine: [Float]?                     // PenDataDashedLine 0x100
    public let penAlignment: Int32?                     // PenDataNonCenter 0x200
    public let compoundLine: [Float]?                   // PenDataCompoundLine 0x400
    /// The custom start/end line caps, [MS-EMFPLUS] §2.2.2.15 / §2.2.2.11: each a
    /// length-prefixed EmfPlusCustomLineCap kept as opaque bytes (the prefix
    /// stripped). Cap fidelity is out of scope this increment; the goal is
    /// correct sizing so the trailing BrushObject is reached exactly.
    public let customStartCap: Data?                    // PenDataCustomStartCap 0x800
    public let customEndCap: Data?                      // PenDataCustomEndCap 0x1000

    public init(
        flags: UInt32, unit: UInt32, width: Float,
        transform: EMFPlusTransformMatrix?, startCap: Int32?, endCap: Int32?, join: Int32?,
        miterLimit: Float?, lineStyle: Int32?, dashedLineCap: Int32?, dashOffset: Float?,
        dashedLine: [Float]?, penAlignment: Int32?, compoundLine: [Float]?,
        customStartCap: Data?, customEndCap: Data?
    ) {
        self.flags = flags
        self.unit = unit
        self.width = width
        self.transform = transform
        self.startCap = startCap
        self.endCap = endCap
        self.join = join
        self.miterLimit = miterLimit
        self.lineStyle = lineStyle
        self.dashedLineCap = dashedLineCap
        self.dashOffset = dashOffset
        self.dashedLine = dashedLine
        self.penAlignment = penAlignment
        self.compoundLine = compoundLine
        self.customStartCap = customStartCap
        self.customEndCap = customEndCap
    }
}

/// A decoded pen, [MS-EMFPLUS] §2.2.1.7 EmfPlusPen: Version, Type, PenData, and
/// a trailing BrushObject.
public struct EMFPlusPen: Sendable, Equatable {
    public let version: UInt32
    /// §2.2.1.7 Type MUST be 0. A non-zero value is kept verbatim (observe it to
    /// detect the violation) and decoding continues.
    public let type: UInt32
    public let penData: EMFPlusPenData
    /// The BrushObject associated with the pen (§2.2.1.7), decoded with the same
    /// brush decoder.
    public let brush: EMFPlusBrush

    public init(version: UInt32, type: UInt32, penData: EMFPlusPenData, brush: EMFPlusBrush) {
        self.version = version
        self.type = type
        self.penData = penData
        self.brush = brush
    }
}

// MARK: - Pen decode

/// PenData flag masks, [MS-EMFPLUS] §2.1.2.7 (verified against the spec prose).
private enum PenDataFlag {
    static let transform: UInt32 = 0x0000_0001
    static let startCap: UInt32 = 0x0000_0002
    static let endCap: UInt32 = 0x0000_0004
    static let join: UInt32 = 0x0000_0008
    static let miterLimit: UInt32 = 0x0000_0010
    static let lineStyle: UInt32 = 0x0000_0020
    static let dashedLineCap: UInt32 = 0x0000_0040
    static let dashedLineOffset: UInt32 = 0x0000_0080
    static let dashedLine: UInt32 = 0x0000_0100
    static let nonCenter: UInt32 = 0x0000_0200
    static let compoundLine: UInt32 = 0x0000_0400
    static let customStartCap: UInt32 = 0x0000_0800
    static let customEndCap: UInt32 = 0x0000_1000
}

/// Decodes an EmfPlusPen ([MS-EMFPLUS] §2.2.1.7): Version, Type, an
/// EmfPlusPenData (§2.2.2.33) whose optional blocks are read strictly in the
/// §2.2.2.34 order gated by the §2.1.2.7 flags, then the trailing BrushObject.
/// Any structural dead-end fails the whole pen with a block-named typed failure
/// rather than misaligning the cursor and mis-reading the brush.
func decodePen(_ cursor: inout ByteCursor)
    -> Result<EMFPlusPen, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPen.Version"))
    }
    guard let type = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPen.Type"))
    }

    guard let flags = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPenData.PenDataFlags"))
    }
    guard let unit = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusPenData.PenUnit"))
    }
    guard let width = cursor.readFloat() else {
        return .failure(.truncated(field: "EmfPlusPenData.PenWidth"))
    }

    var transform: EMFPlusTransformMatrix?
    if flags & PenDataFlag.transform != 0 {
        guard let matrix = cursor.readTransformMatrix() else {
            return .failure(.truncated(field: "PenData.TransformMatrix"))
        }
        transform = matrix
    }

    var startCap: Int32?
    if flags & PenDataFlag.startCap != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.StartCap")) }
        startCap = value
    }
    var endCap: Int32?
    if flags & PenDataFlag.endCap != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.EndCap")) }
        endCap = value
    }
    var join: Int32?
    if flags & PenDataFlag.join != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.Join")) }
        join = value
    }
    var miterLimit: Float?
    if flags & PenDataFlag.miterLimit != 0 {
        guard let value = cursor.readFloat() else { return .failure(.truncated(field: "PenData.MiterLimit")) }
        miterLimit = value
    }
    var lineStyle: Int32?
    if flags & PenDataFlag.lineStyle != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.LineStyle")) }
        lineStyle = value
    }
    var dashedLineCap: Int32?
    if flags & PenDataFlag.dashedLineCap != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.DashedLineCap")) }
        dashedLineCap = value
    }
    var dashOffset: Float?
    if flags & PenDataFlag.dashedLineOffset != 0 {
        guard let value = cursor.readFloat() else { return .failure(.truncated(field: "PenData.DashOffset")) }
        dashOffset = value
    }
    var dashedLine: [Float]?
    if flags & PenDataFlag.dashedLine != 0 {
        // §2.2.2.16: DashedLineDataSize (count), then that many floats. The count
        // is bounds-checked against the remaining bytes before any allocation.
        guard let count = cursor.readUInt32() else {
            return .failure(.truncated(field: "PenData.DashedLineDataSize"))
        }
        guard let values = cursor.readFloats(count: Int(count)) else {
            return .failure(.arrayCountExceedsBuffer(
                field: "PenData.DashedLineData", count: count, remainingBytes: cursor.remaining))
        }
        dashedLine = values
    }
    var penAlignment: Int32?
    if flags & PenDataFlag.nonCenter != 0 {
        guard let value = cursor.readInt32() else { return .failure(.truncated(field: "PenData.PenAlignment")) }
        penAlignment = value
    }
    var compoundLine: [Float]?
    if flags & PenDataFlag.compoundLine != 0 {
        // §2.2.2.9: CompoundLineDataSize (count), then that many floats.
        guard let count = cursor.readUInt32() else {
            return .failure(.truncated(field: "PenData.CompoundLineDataSize"))
        }
        guard let values = cursor.readFloats(count: Int(count)) else {
            return .failure(.arrayCountExceedsBuffer(
                field: "PenData.CompoundLineData", count: count, remainingBytes: cursor.remaining))
        }
        compoundLine = values
    }
    var customStartCap: Data?
    if flags & PenDataFlag.customStartCap != 0 {
        switch readCustomCap(&cursor, field: "PenData.CustomStartCapData") {
        case .success(let bytes): customStartCap = bytes
        case .failure(let reason): return .failure(reason)
        }
    }
    var customEndCap: Data?
    if flags & PenDataFlag.customEndCap != 0 {
        switch readCustomCap(&cursor, field: "PenData.CustomEndCapData") {
        case .success(let bytes): customEndCap = bytes
        case .failure(let reason): return .failure(reason)
        }
    }

    let penData = EMFPlusPenData(
        flags: flags, unit: unit, width: width, transform: transform,
        startCap: startCap, endCap: endCap, join: join, miterLimit: miterLimit,
        lineStyle: lineStyle, dashedLineCap: dashedLineCap, dashOffset: dashOffset,
        dashedLine: dashedLine, penAlignment: penAlignment, compoundLine: compoundLine,
        customStartCap: customStartCap, customEndCap: customEndCap)

    // BrushObject: the pen's final field (§2.2.1.7).
    switch decodeBrush(&cursor) {
    case .success(let brush):
        return .success(EMFPlusPen(version: version, type: type, penData: penData, brush: brush))
    case .failure(let reason):
        return .failure(reason)
    }
}

/// Reads a length-prefixed custom line cap ([MS-EMFPLUS] §2.2.2.15 /  §2.2.2.11):
/// a u32 byte-size, then that many opaque EmfPlusCustomLineCap bytes. The size is
/// bounds-checked against the remaining bytes before the read — a lying size
/// fails the pen (primer §8) instead of over-reading.
private func readCustomCap(_ cursor: inout ByteCursor, field: String)
    -> Result<Data, EMFPlusObjectDecodeFailure> {
    guard let size = cursor.readUInt32() else {
        return .failure(.truncated(field: field + ".Size"))
    }
    guard cursor.remaining >= Int(size), let bytes = cursor.readBytes(Int(size)) else {
        return .failure(.customCapSizeExceedsBuffer(
            field: field, size: size, remainingBytes: cursor.remaining))
    }
    return .success(bytes)
}
