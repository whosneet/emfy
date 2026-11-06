import CoreGraphics
import EMFParse
import Foundation
import Testing
@testable import EMFEdit

/// Hostile-input gate (§8): the importer returns typed errors or bounded
/// results and never traps. Quick Look-style adversarial inputs.
struct SceneHostileTests {

    @Test func emptyDataThrowsUnreadable() {
        #expect(throws: SceneImporter.ImportError.unreadable) {
            _ = try SceneImporter.import(data: Data())
        }
    }

    @Test func garbageThrowsUnreadable() {
        let garbage = Data((0 ..< 4096).map { UInt8(($0 * 37) & 0xFF) })
        #expect(throws: SceneImporter.ImportError.self) {
            _ = try SceneImporter.import(data: garbage)
        }
    }

    @Test func truncatedFileDoesNotTrap() throws {
        let full = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p2-star.emf"))
        // Cut at many points; every one either imports a bounded scene or throws
        // a typed error — never a trap.
        for fraction in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let cut = full.prefix(Int(Double(full.count) * fraction))
            let scene = try? SceneImporter.import(data: Data(cut))
            if let scene {
                #expect(scene.partition.isComplete, "truncated-\(fraction): partition still complete")
            }
        }
    }

    @Test func lyingPointCountBecomesPassthroughNotTrap() throws {
        // EMR_POLYGON16 claiming 1,000,000 points in a 32-byte record: the parser
        // flags it malformed, so the import keeps it as passthrough.
        let scene = try SceneImporter.import(data: Self.lyingPolygonEMF())
        #expect(scene.partition.isComplete)
        #expect(scene.elements.contains { $0.kind == .passthrough })
    }

    @Test func absurdWorldTransformIsBounded() throws {
        let scene = try SceneImporter.import(data: Self.absurdTransformEMF())
        #expect(scene.partition.isComplete)
        // Rendering an absurd-coordinate scene is bounded and never traps.
        #expect(SceneRenderer.makeImage(scene) != nil)
    }

    // MARK: - Fixtures

    private static func lyingPolygonEMF() -> Data {
        var records: [[UInt8]] = []
        records.append(baseHeader(nBytes: 88 + 32 + 20, nRecords: 3))
        // EMR_POLYGON16 (86): bounds(16) + count(u32) + PointS[count]. nSize=32
        // leaves room for 1 point but claims 1,000,000.
        var polygon: [UInt8] = []
        polygon += u32(86) + u32(32)                     // iType, nSize
        polygon += i32(0) + i32(0) + i32(50) + i32(50)   // rclBounds
        polygon += u32(1_000_000)                        // Count (lie)
        polygon += u16(1) + u16(1)                        // one PointS of slack
        records.append(polygon)
        records.append(eof())
        return Data(records.flatMap { $0 })
    }

    private static func absurdTransformEMF() -> Data {
        var records: [[UInt8]] = []
        records.append(baseHeader(nBytes: 88 + 32 + 24 + 20, nRecords: 4))
        // EMR_SETWORLDTRANSFORM (35): XForm m11,m12,m21,m22,dx,dy. nSize=32.
        var xform: [UInt8] = []
        xform += u32(35) + u32(32)
        xform += f32(1e20) + f32(0) + f32(0) + f32(1e20) + f32(1e18) + f32(1e18)
        records.append(xform)
        // EMR_RECTANGLE.
        records.append(u32(43) + u32(24) + i32(0) + i32(0) + i32(10) + i32(10))
        records.append(eof())
        return Data(records.flatMap { $0 })
    }

    private static func baseHeader(nBytes: UInt32, nRecords: UInt32) -> [UInt8] {
        var header: [UInt8] = []
        header += u32(1) + u32(88)
        header += i32(0) + i32(0) + i32(99) + i32(99)
        header += i32(0) + i32(0) + i32(2645) + i32(2645)
        header += u32(0x464D_4520) + u32(0x0001_0000)
        header += u32(nBytes) + u32(nRecords)
        header += u16(1) + u16(0)
        header += u32(0) + u32(0) + u32(0)
        header += i32(1920) + i32(1080)
        header += i32(320) + i32(240)
        return header
    }

    private static func eof() -> [UInt8] { u32(14) + u32(20) + u32(0) + u32(0) + u32(20) }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
    private static func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    private static func f32(_ value: Float) -> [UInt8] { u32(value.bitPattern) }
}
