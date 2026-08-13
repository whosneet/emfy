import Foundation

// MARK: - Region model

/// The Boolean operation of a non-terminal region node, [MS-EMFPLUS] §2.1.1.26
/// RegionNodeDataType (the combining values 0x1…0x5).
public enum EMFPlusRegionCombineMode: Sendable, Equatable {
    case and         // 0x01 RegionNodeDataTypeAnd
    case or          // 0x02 RegionNodeDataTypeOr
    case xor         // 0x03 RegionNodeDataTypeXor
    case exclude     // 0x04 RegionNodeDataTypeExclude
    case complement  // 0x05 RegionNodeDataTypeComplement

    public init?(rawValue: UInt32) {
        switch rawValue {
        case 0x01: self = .and
        case 0x02: self = .or
        case 0x03: self = .xor
        case 0x04: self = .exclude
        case 0x05: self = .complement
        default: return nil
        }
    }

    public var rawValue: UInt32 {
        switch self {
        case .and: return 0x01
        case .or: return 0x02
        case .xor: return 0x03
        case .exclude: return 0x04
        case .complement: return 0x05
        }
    }
}

/// One node of a graphics region's binary tree, [MS-EMFPLUS] §2.2.2.40
/// EmfPlusRegionNode. A terminal node is a rectangle, a path, or the
/// empty/infinite sentinel; a non-terminal node combines exactly two children.
public indirect enum EMFPlusRegionNode: Sendable, Equatable {
    /// §2.2.2.40 RegionNodeDataTypeRect: an EmfPlusRectF boundary.
    case rect(EMFPlusRectF)
    /// §2.2.2.42 RegionNodeDataTypePath: an embedded EmfPlusPath boundary.
    case path(EMFPlusPath)
    /// §2.2.2.40 RegionNodeDataTypeEmpty: no data.
    case empty
    /// §2.2.2.40 RegionNodeDataTypeInfinite: no data.
    case infinite
    /// §2.2.2.41 EmfPlusRegionNodeChildNodes: a combining node with two children.
    case combine(operation: EMFPlusRegionCombineMode, left: EMFPlusRegionNode, right: EMFPlusRegionNode)
}

/// A decoded graphics region, [MS-EMFPLUS] §2.2.1.8 EmfPlusRegion: Version,
/// RegionNodeCount, then a single root node whose subtree is the region.
public struct EMFPlusRegion: Sendable, Equatable {
    public let version: UInt32
    /// RegionNodeCount as declared. ADVISORY (primer §8): the tree walk is
    /// authoritative — a real region's declared count can disagree with the
    /// actual node total, and the decode follows the tree, not this field.
    public let declaredNodeCount: UInt32
    public let root: EMFPlusRegionNode

    public init(version: UInt32, declaredNodeCount: UInt32, root: EMFPlusRegionNode) {
        self.version = version
        self.declaredNodeCount = declaredNodeCount
        self.root = root
    }
}

// MARK: - Region decode

/// RegionNodeDataType values ([MS-EMFPLUS] §2.1.1.26).
private enum RegionNodeType {
    static let and: UInt32 = 0x0000_0001
    static let or: UInt32 = 0x0000_0002
    static let xor: UInt32 = 0x0000_0003
    static let exclude: UInt32 = 0x0000_0004
    static let complement: UInt32 = 0x0000_0005
    static let rect: UInt32 = 0x1000_0000
    static let path: UInt32 = 0x1000_0001
    static let empty: UInt32 = 0x1000_0002
    static let infinite: UInt32 = 0x1000_0003
}

/// Recursion-depth cap: a hostile deeply-nested region must fail typed rather
/// than overflow the stack (primer §8).
private let regionMaxDepth = 64
/// Total-node cap: a hostile wide/absurd tree must fail typed rather than hang.
private let regionMaxNodes = 4096

/// Decodes an EmfPlusRegion ([MS-EMFPLUS] §2.2.1.8): Version, RegionNodeCount
/// (advisory), then the root EmfPlusRegionNode subtree.
func decodeRegion(_ cursor: inout ByteCursor)
    -> Result<EMFPlusRegion, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusRegion.Version"))
    }
    guard let nodeCount = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusRegion.RegionNodeCount"))
    }
    var visited = 0
    switch decodeRegionNode(&cursor, depth: 0, visited: &visited) {
    case .success(let root):
        return .success(EMFPlusRegion(version: version, declaredNodeCount: nodeCount, root: root))
    case .failure(let reason):
        return .failure(reason)
    }
}

/// Decodes one EmfPlusRegionNode (§2.2.2.40), recursing into combining nodes.
/// `depth` and `visited` enforce the recursion-depth and total-node caps before
/// any further work, so a malicious tree fails typed instead of crashing.
private func decodeRegionNode(_ cursor: inout ByteCursor, depth: Int, visited: inout Int)
    -> Result<EMFPlusRegionNode, EMFPlusObjectDecodeFailure> {
    if depth >= regionMaxDepth { return .failure(.regionTreeTooDeep) }
    visited += 1
    if visited > regionMaxNodes { return .failure(.regionTooManyNodes) }

    guard let type = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusRegionNode.Type"))
    }

    switch type {
    case RegionNodeType.rect:
        guard let x = cursor.readFloat(), let y = cursor.readFloat(),
              let width = cursor.readFloat(), let height = cursor.readFloat() else {
            return .failure(.truncated(field: "EmfPlusRegionNode.Rect"))
        }
        return .success(.rect(EMFPlusRectF(x: x, y: y, width: width, height: height)))

    case RegionNodeType.path:
        // §2.2.2.42: RegionNodePathLength (i32), then that many bytes of
        // EmfPlusPath. Bounds-check the length before slicing.
        guard let length = cursor.readInt32() else {
            return .failure(.truncated(field: "EmfPlusRegionNodePath.RegionNodePathLength"))
        }
        guard length >= 0, cursor.remaining >= Int(length),
              let pathBytes = cursor.readBytes(Int(length)) else {
            return .failure(.arrayCountExceedsBuffer(
                field: "EmfPlusRegionNodePath.RegionNodePath",
                count: UInt32(bitPattern: length), remainingBytes: cursor.remaining))
        }
        var pathCursor = ByteCursor(pathBytes)
        switch decodePath(&pathCursor) {
        case .success(let path): return .success(.path(path))
        case .failure(let reason): return .failure(reason)
        }

    case RegionNodeType.empty:
        return .success(.empty)

    case RegionNodeType.infinite:
        return .success(.infinite)

    case RegionNodeType.and, RegionNodeType.or, RegionNodeType.xor,
         RegionNodeType.exclude, RegionNodeType.complement:
        guard let operation = EMFPlusRegionCombineMode(rawValue: type) else {
            return .failure(.unknownRegionNodeType(raw: type))
        }
        // §2.2.2.41: exactly two child nodes, decoded recursively.
        let left: EMFPlusRegionNode
        switch decodeRegionNode(&cursor, depth: depth + 1, visited: &visited) {
        case .success(let node): left = node
        case .failure(let reason): return .failure(reason)
        }
        let right: EMFPlusRegionNode
        switch decodeRegionNode(&cursor, depth: depth + 1, visited: &visited) {
        case .success(let node): right = node
        case .failure(let reason): return .failure(reason)
        }
        return .success(.combine(operation: operation, left: left, right: right))

    default:
        return .failure(.unknownRegionNodeType(raw: type))
    }
}
