import Foundation
import Testing
@testable import EMFParse

// MARK: - Local fixture builders (mirror the file-private helpers in the sibling
// EMF+ object tests; duplicated per the codebase's per-file fixture convention).

private func plusRecord(type: UInt16, flags: UInt16 = 0, data: [UInt8] = []) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt16(type)
    b.appendUInt16(flags)
    b.appendUInt32(UInt32(12 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

private func plusComment(stream: [UInt8]) -> [UInt8] {
    var payload = FixtureBuilder()
    payload.appendUInt32(0x2B46_4D45)   // "EMF+"
    payload.appendBytes(stream)
    let data = payload.bytes
    var b = FixtureBuilder()
    b.appendUInt32(70)
    b.appendUInt32(UInt32(8 + 4 + data.count))
    b.appendUInt32(UInt32(data.count))
    b.appendBytes(data)
    return b.bytes
}

private func objectFlags(objectType: UInt8, objectID: UInt8) -> UInt16 {
    (UInt16(objectType) & 0x7F) << 8 | UInt16(objectID)
}

private func objectRecord(objectType: UInt8, objectBytes: [UInt8]) -> [UInt8] {
    plusRecord(type: 0x4008, flags: objectFlags(objectType: objectType, objectID: 0), data: objectBytes)
}

/// Wraps one object payload in a walk-valid file and decodes it.
private func decodeObject(objectType: UInt8, objectBytes: [UInt8]) throws -> EMFPlusObjectValue {
    var fixture = FixtureBuilder()
    fixture.appendBytes(FixtureBuilder.header(fixedSize: 108))
    fixture.appendBytes(plusComment(stream: objectRecord(objectType: objectType, objectBytes: objectBytes)))
    fixture.appendBytes(FixtureBuilder.eof())
    let (defs, _) = try EMFFile.parse(fixture.data).emfPlusStream().objectDefinitions()
    return try #require(defs.first).decodedValue()
}

// Path payload builder.
private func pathBytes(version: UInt32 = 0xDBC0_1002, count: UInt32, flags: UInt32,
                       points: [UInt8], pointTypes: [UInt8], pad: Int = 0) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(version)
    b.appendUInt32(count)
    b.appendUInt32(flags)
    b.appendBytes(points)
    b.appendBytes(pointTypes)
    b.appendZeros(pad)
    return b.bytes
}

// Region node byte builders ([MS-EMFPLUS] §2.1.1.26 / §2.2.2.40–42).
private func rectNode(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(0x1000_0000)
    b.appendFloat(x); b.appendFloat(y); b.appendFloat(w); b.appendFloat(h)
    return b.bytes
}
private func emptyNode() -> [UInt8] { var b = FixtureBuilder(); b.appendUInt32(0x1000_0002); return b.bytes }
private func infiniteNode() -> [UInt8] { var b = FixtureBuilder(); b.appendUInt32(0x1000_0003); return b.bytes }
private func pathNode(pathPayload: [UInt8]) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(0x1000_0001)
    b.appendInt32(Int32(pathPayload.count))
    b.appendBytes(pathPayload)
    return b.bytes
}
private func combineNode(op: UInt32, left: [UInt8], right: [UInt8]) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(op)
    b.appendBytes(left)
    b.appendBytes(right)
    return b.bytes
}
private func regionBytes(version: UInt32 = 0xDBC0_1002, nodeCount: UInt32, tree: [UInt8]) -> [UInt8] {
    var b = FixtureBuilder()
    b.appendUInt32(version)
    b.appendUInt32(nodeCount)
    b.appendBytes(tree)
    return b.bytes
}
private func pf(_ x: Float, _ y: Float) -> EMFPlusPointF { EMFPlusPointF(x: x, y: y) }

// MARK: - Path decode

@Suite("EMF+ path decode")
struct EMFPlusPathDecodeTests {

    @Test("f32 absolute path → points, point-type kinds, close-subpath flag")
    func floatPath() throws {
        var pts = FixtureBuilder()
        pts.appendFloat(1); pts.appendFloat(2)
        pts.appendFloat(3); pts.appendFloat(4)
        pts.appendFloat(5); pts.appendFloat(6)
        // types: Start, Line, Line+CloseSubpath (0x08 flag in the high nibble → 0x81).
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 3, flags: 0, points: pts.bytes, pointTypes: [0x00, 0x01, 0x81], pad: 1))
        guard case .path(let path) = value else { Issue.record("expected .path, got \(value)"); return }
        #expect(path.version == 0xDBC0_1002)
        #expect(path.pointCount == 3)
        #expect(path.flags == 0)
        #expect(path.points == [pf(1, 2), pf(3, 4), pf(5, 6)])
        #expect(path.pointTypes == [0x00, 0x01, 0x81])
        #expect(path.usesAbsoluteInt16Points == false)
        let types = path.decodedPointTypes
        #expect(types.map(\.kind) == [.start, .line, .line])
        #expect(types[2].isCloseSubpath == true)
        #expect(types[0].isCloseSubpath == false)
    }

    @Test("i16 absolute path (C=0x4000) → lossless widening to Float")
    func int16Path() throws {
        var pts = FixtureBuilder()
        pts.appendInt16(10); pts.appendInt16(-20)     // point 0
        pts.appendInt16(30); pts.appendInt16(40)      // point 1
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 2, flags: 0x4000, points: pts.bytes, pointTypes: [0x00, 0x01], pad: 2))
        guard case .path(let path) = value else { Issue.record("expected .path, got \(value)"); return }
        #expect(path.pointCount == 2)
        #expect(path.flags == 0x4000)
        #expect(path.points == [pf(10, -20), pf(30, 40)])
        #expect(path.usesAbsoluteInt16Points == true)
    }

    @Test("undocumented 0x2000 flag bit tolerated with both encodings")
    func reservedFlagBitTolerated() throws {
        // f32 encoding with the stray 0x2000 bit.
        var f = FixtureBuilder(); f.appendFloat(7); f.appendFloat(8)
        let floatValue = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 1, flags: 0x2000, points: f.bytes, pointTypes: [0x00], pad: 3))
        guard case .path(let floatPath) = floatValue else { Issue.record("expected .path"); return }
        #expect(floatPath.flags == 0x2000)
        #expect(floatPath.points == [pf(7, 8)])

        // i16 encoding (C set) with the stray 0x2000 bit → 0x6000.
        var i = FixtureBuilder(); i.appendInt16(1); i.appendInt16(2)
        let intValue = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 1, flags: 0x6000, points: i.bytes, pointTypes: [0x00], pad: 3))
        guard case .path(let intPath) = intValue else { Issue.record("expected .path"); return }
        #expect(intPath.flags == 0x6000)
        #expect(intPath.usesAbsoluteInt16Points == true)
        #expect(intPath.points == [pf(1, 2)])
    }

    @Test("relative/RLE path (R=0x0800) → typed malformed failure, not decoded")
    func relativePathUnsupported() throws {
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 0, flags: 0x0800, points: [], pointTypes: []))
        #expect(value == .malformed(type: .path, reason: .relativePathEncodingUnsupported))
    }

    @Test("lying PathPointCount → typed failure before allocation")
    func lyingPointCount() throws {
        // Claims 1000 f32 points but supplies only 8 bytes.
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 1000, flags: 0, points: [1, 2, 3, 4, 5, 6, 7, 8], pointTypes: []))
        guard case .malformed(.path, .arrayCountExceedsBuffer(let field, let count, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusPath.PathPoints")
        #expect(count == 1000)
    }

    @Test("trailing AlignmentPadding tolerated (up to 3 bytes)")
    func paddingTolerated() throws {
        var pts = FixtureBuilder(); pts.appendFloat(9); pts.appendFloat(9)
        // 12 + 8 + 1 = 21 → 3 pad bytes to reach 24.
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 1, flags: 0, points: pts.bytes, pointTypes: [0x01], pad: 3))
        guard case .path(let path) = value else { Issue.record("expected .path, got \(value)"); return }
        #expect(path.points == [pf(9, 9)])
        #expect(path.pointTypes == [0x01])
    }

    @Test("empty path (count 0) → valid empty path")
    func emptyPath() throws {
        let value = try decodeObject(objectType: 3, objectBytes: pathBytes(
            count: 0, flags: 0, points: [], pointTypes: []))
        guard case .path(let path) = value else { Issue.record("expected .path, got \(value)"); return }
        #expect(path.pointCount == 0)
        #expect(path.points.isEmpty)
        #expect(path.pointTypes.isEmpty)
    }
}

// MARK: - Region decode

@Suite("EMF+ region decode")
struct EMFPlusRegionDecodeTests {

    @Test("rect leaf")
    func rectLeaf() throws {
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(
            nodeCount: 1, tree: rectNode(1, 2, 3, 4)))
        guard case .region(let region) = value else { Issue.record("expected .region, got \(value)"); return }
        #expect(region.version == 0xDBC0_1002)
        #expect(region.declaredNodeCount == 1)
        #expect(region.root == .rect(EMFPlusRectF(x: 1, y: 2, width: 3, height: 4)))
    }

    @Test("empty and infinite leaf nodes carry no data")
    func emptyAndInfiniteLeaves() throws {
        let emptyValue = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 1, tree: emptyNode()))
        guard case .region(let emptyRegion) = emptyValue else { Issue.record("expected .region"); return }
        #expect(emptyRegion.root == .empty)

        let infiniteValue = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 1, tree: infiniteNode()))
        guard case .region(let infiniteRegion) = infiniteValue else { Issue.record("expected .region"); return }
        #expect(infiniteRegion.root == .infinite)
    }

    @Test("path leaf embedding a real 2-point path")
    func pathLeaf() throws {
        var pts = FixtureBuilder()
        pts.appendFloat(1); pts.appendFloat(1)
        pts.appendFloat(2); pts.appendFloat(2)
        let embedded = pathBytes(count: 2, flags: 0, points: pts.bytes, pointTypes: [0x00, 0x01], pad: 2)
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(
            nodeCount: 1, tree: pathNode(pathPayload: embedded)))
        guard case .region(let region) = value, case .path(let path) = region.root else {
            Issue.record("expected region path leaf, got \(value)"); return
        }
        #expect(path.points == [pf(1, 1), pf(2, 2)])
        #expect(path.pointTypes == [0x00, 0x01])
    }

    @Test("combining tree AND(rect, OR(rect, rect)) → structure preserved")
    func combiningTree() throws {
        let inner = combineNode(op: 2, left: rectNode(1, 1, 1, 1), right: rectNode(2, 2, 2, 2))   // OR
        let root = combineNode(op: 1, left: rectNode(10, 10, 10, 10), right: inner)               // AND
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 5, tree: root))
        guard case .region(let region) = value else { Issue.record("expected .region, got \(value)"); return }
        #expect(region.root == .combine(
            operation: .and,
            left: .rect(EMFPlusRectF(x: 10, y: 10, width: 10, height: 10)),
            right: .combine(
                operation: .or,
                left: .rect(EMFPlusRectF(x: 1, y: 1, width: 1, height: 1)),
                right: .rect(EMFPlusRectF(x: 2, y: 2, width: 2, height: 2)))))
    }

    @Test("depth bomb: a chain of combining nodes past the cap → typed failure, bounded recursion")
    func depthBomb() throws {
        // A left-leaning chain 100 combining nodes deep must fail typed at the
        // depth cap without overflowing the stack. Completing this test at all
        // is the proof that recursion is bounded.
        func chain(_ n: Int) -> [UInt8] {
            n == 0 ? emptyNode() : combineNode(op: 1, left: chain(n - 1), right: emptyNode())
        }
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 0, tree: chain(100)))
        #expect(value == .malformed(type: .region, reason: .regionTreeTooDeep))
    }

    @Test("node bomb: a wide balanced tree past the node cap → typed failure")
    func nodeBomb() throws {
        // A balanced tree of depth 12 has 8191 nodes (max depth 12 < 64), so it
        // trips the total-node cap, not the depth cap.
        func balanced(_ d: Int) -> [UInt8] {
            d == 0 ? emptyNode() : combineNode(op: 1, left: balanced(d - 1), right: balanced(d - 1))
        }
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 0, tree: balanced(12)))
        #expect(value == .malformed(type: .region, reason: .regionTooManyNodes))
    }

    @Test("lying RegionNodePathLength → typed failure")
    func lyingPathLength() throws {
        var b = FixtureBuilder()
        b.appendUInt32(0x1000_0001)     // Path node
        b.appendInt32(9999)             // RegionNodePathLength far past the bytes
        b.appendBytes([0x01, 0x02, 0x03, 0x04])
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 1, tree: b.bytes))
        guard case .malformed(.region, .arrayCountExceedsBuffer(let field, let count, _)) = value else {
            Issue.record("expected malformed arrayCountExceedsBuffer, got \(value)"); return
        }
        #expect(field == "EmfPlusRegionNodePath.RegionNodePath")
        #expect(count == 9999)
    }

    @Test("unknown region node type → typed failure, no size guessing")
    func unknownNodeType() throws {
        var b = FixtureBuilder(); b.appendUInt32(0x9999_9999)
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(nodeCount: 1, tree: b.bytes))
        #expect(value == .malformed(type: .region, reason: .unknownRegionNodeType(raw: 0x9999_9999)))
    }

    @Test("RegionNodeCount disagreement tolerated (advisory) — the tree walk wins")
    func advisoryNodeCount() throws {
        // One rect leaf, but the header lies that there are 999 nodes.
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(
            nodeCount: 999, tree: rectNode(5, 6, 7, 8)))
        guard case .region(let region) = value else { Issue.record("expected .region, got \(value)"); return }
        #expect(region.declaredNodeCount == 999)
        #expect(region.root == .rect(EMFPlusRectF(x: 5, y: 6, width: 7, height: 8)))
    }

    @Test("malformed embedded path in a path leaf → region fails typed")
    func malformedEmbeddedPath() throws {
        // The embedded path sets the unsupported R flag; its failure surfaces as
        // the region's failure.
        let embedded = pathBytes(count: 0, flags: 0x0800, points: [], pointTypes: [])
        let value = try decodeObject(objectType: 4, objectBytes: regionBytes(
            nodeCount: 1, tree: pathNode(pathPayload: embedded)))
        #expect(value == .malformed(type: .region, reason: .relativePathEncodingUnsupported))
    }
}
