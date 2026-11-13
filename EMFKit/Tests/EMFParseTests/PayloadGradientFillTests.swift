import Foundation
import Testing
@testable import EMFParse

/// Decode coverage for EMR_GRADIENTFILL (118) ([MS-EMF] §2.3.5.12): the vertex
/// array plus a rectangle or triangle mesh. Golden decodes of both mesh shapes,
/// an out-of-range mesh index (→ malformed), a count that overruns nSize, and a
/// truncated variant (primer §8).
@Suite("GRADIENTFILL record decode")
struct PayloadGradientFillTests {

    /// A 16-byte TriVertex: x, y (i32), then R,G,B,A (u16, colour in high byte).
    private static func vertex(x: Int32, y: Int32, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var w = FixtureBuilder()
        w.appendInt32(x); w.appendInt32(y)
        w.appendUInt16(UInt16(r) << 8); w.appendUInt16(UInt16(g) << 8)
        w.appendUInt16(UInt16(b) << 8); w.appendUInt16(0)
        return w.bytes
    }

    private static func record(mode: UInt32, vertices: [[UInt8]], mesh: [UInt32]) -> [UInt8] {
        let perPrim = mode == 2 ? 3 : 2
        var p = FixtureBuilder()
        p.appendInt32(0); p.appendInt32(0); p.appendInt32(100); p.appendInt32(50)   // Bounds@8
        p.appendUInt32(UInt32(vertices.count))        // nVer@24
        p.appendUInt32(UInt32(mesh.count / perPrim))  // nTri@28
        p.appendUInt32(mode)                          // ulMode@32
        for v in vertices { p.appendBytes(v) }
        for i in mesh { p.appendUInt32(i) }
        return FixtureBuilder.record(type: 118, payload: p.bytes)
    }

    @Test("RECT_H golden: two vertices, one rectangle")
    func rectGolden() throws {
        let verts = [
            Self.vertex(x: 0, y: 0, r: 255, g: 0, b: 0),
            Self.vertex(x: 100, y: 50, r: 0, g: 0, b: 255),
        ]
        let payload = try decodeSingle(Self.record(mode: 0, vertices: verts, mesh: [0, 1]))
        guard case .gradientFill(let g) = payload else { Issue.record("got \(payload)"); return }
        #expect(g.mode == .rectHorizontal)
        #expect(g.vertices.count == 2)
        #expect(g.vertices[0].red == 0xFF00)
        if case .rectangles(let rects) = g.mesh {
            #expect(rects == [GradientRectangle(upperLeft: 0, lowerRight: 1)])
        } else { Issue.record("expected rectangles mesh") }
    }

    @Test("TRIANGLE golden: three vertices, one triangle")
    func triangleGolden() throws {
        let verts = [
            Self.vertex(x: 0, y: 0, r: 255, g: 0, b: 0),
            Self.vertex(x: 100, y: 0, r: 0, g: 255, b: 0),
            Self.vertex(x: 50, y: 50, r: 0, g: 0, b: 255),
        ]
        let payload = try decodeSingle(Self.record(mode: 2, vertices: verts, mesh: [0, 1, 2]))
        guard case .gradientFill(let g) = payload else { Issue.record("got \(payload)"); return }
        #expect(g.mode == .triangle)
        if case .triangles(let tris) = g.mesh {
            #expect(tris == [GradientTriangle(vertex1: 0, vertex2: 1, vertex3: 2)])
        } else { Issue.record("expected triangles mesh") }
    }

    @Test("a mesh index outside the vertex array is malformed")
    func badIndex() throws {
        let verts = [Self.vertex(x: 0, y: 0, r: 1, g: 2, b: 3), Self.vertex(x: 1, y: 1, r: 4, g: 5, b: 6)]
        // index 5 is out of range (only 2 vertices).
        let payload = try decodeSingle(Self.record(mode: 0, vertices: verts, mesh: [0, 5]))
        #expect(payload.malformedReason != nil)
    }

    @Test("an nVer that cannot fit in nSize is rejected before allocating")
    func vertexCountOverrun() throws {
        var p = FixtureBuilder()
        p.appendInt32(0); p.appendInt32(0); p.appendInt32(10); p.appendInt32(10)
        p.appendUInt32(100_000)      // nVer — absurd
        p.appendUInt32(0)            // nTri
        p.appendUInt32(0)            // ulMode
        let payload = try decodeSingle(FixtureBuilder.record(type: 118, payload: p.bytes))
        #expect(payload.malformedReason != nil)
    }

    @Test("truncated record (below the 36-byte fixed part) is malformed")
    func truncated() throws {
        let (file, record) = try parseWithSingleRecord(FixtureBuilder.record(type: 118, size: 20))
        #expect(file.payload(of: record)
            == .malformed(type: 118, reason: .tooSmall(minimumSize: 36, actualSize: 20)))
    }
}
