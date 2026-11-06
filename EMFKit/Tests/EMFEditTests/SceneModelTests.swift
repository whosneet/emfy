import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// Precise unit tests for the value-type model and the lift, over a hand-built
/// EMF fixture and the committed text/image files.
struct SceneModelTests {

    // MARK: - Value-type round trips

    @Test func scenePathRoundTripsThroughCGPath() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 2))
        path.addLine(to: CGPoint(x: 3, y: 4))
        path.addCurve(to: CGPoint(x: 9, y: 9), control1: CGPoint(x: 5, y: 6), control2: CGPoint(x: 7, y: 8))
        path.addQuadCurve(to: CGPoint(x: 12, y: 12), control: CGPoint(x: 10, y: 11))
        path.closeSubpath()

        let scenePath = ScenePath(path)
        #expect(scenePath.segments.count == 5)
        // Rebuilt CGPath encloses the same points.
        #expect(scenePath.cgPath.boundingBoxOfPath.equalTo(path.boundingBoxOfPath))
        // Re-flattening is stable.
        #expect(ScenePath(scenePath.cgPath).segments == scenePath.segments)
    }

    @Test func sceneColorRoundTripsWithColorRef() {
        let colorRef = ColorRef(red: 10, green: 128, blue: 240)
        let color = SceneColor(colorRef)
        #expect(abs(color.red - 10.0 / 255) < 1e-9)
        #expect(color.alpha == 1)
        #expect(color.colorRef == colorRef)
    }

    // MARK: - Hand-built EMF fixture: a red-filled rectangle

    @Test func liftsRedFilledRectangle() throws {
        let data = Self.redRectangleEMF()
        let scene = try SceneImporter.import(data: data)

        // Partition: header/eof structural, createbrush+selectobject state,
        // rectangle drawing — complete and disjoint.
        #expect(scene.partition.isComplete)
        #expect(scene.partition.structural == [0, 4])
        #expect(scene.partition.state == [1, 2])
        #expect(scene.partition.drawing == [3])
        #expect(scene.partition.passthrough.isEmpty)

        let rects = scene.elements.filter { $0.kind == .rect }
        try #require(rects.count == 1)
        let rect = rects[0]

        #expect(rect.provenance.sourceRecordIndices == [3])
        #expect(!rect.provenance.edited)

        // Fill: solid red, ALTERNATE (even-odd).
        let fill = try #require(rect.style.fill)
        #expect(fill.color.colorRef == ColorRef(red: 255, green: 0, blue: 0))
        #expect(fill.evenOdd)

        // Stroke: the stock BLACK_PEN — cosmetic, black.
        let stroke = try #require(rect.style.stroke)
        #expect(stroke.isCosmetic)
        #expect(stroke.color.colorRef == ColorRef(red: 0, green: 0, blue: 0))

        // Geometry: device-space rect (10,10)-(50,50) under MM_TEXT identity.
        let box = rect.geometryDevice.boundingBox
        #expect(abs(box.minX - 10) < 0.5)
        #expect(abs(box.minY - 10) < 0.5)
        #expect(abs(box.width - 40) < 0.5)
        #expect(abs(box.height - 40) < 0.5)
    }

    // MARK: - Text content lift

    @Test func liftsTextRunsFromCommittedFile() throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-text.emf"))
        let scene = try SceneImporter.import(data: data)
        let texts = scene.elements.compactMap { $0.kind == .text ? $0.text : nil }
        try #require(!texts.isEmpty)
        for text in texts {
            #expect(!text.string.isEmpty, "text run has an empty string")
            #expect(!text.fontFamily.isEmpty, "text run has no resolved font family")
        }
    }

    // MARK: - Image content lift

    @Test func liftsImageFromCommittedFile() throws {
        let data = try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent("gate-p4-image.emf"))
        let scene = try SceneImporter.import(data: data)
        let images = scene.elements.compactMap { $0.kind == .image ? $0.image : nil }
        try #require(!images.isEmpty)
        for image in images {
            #expect(image.sourceDIB != nil, "image element carries no source DIB")
            #expect(image.destRectDevice.width > 0 && image.destRectDevice.height > 0,
                    "image element has a degenerate destination")
        }
    }

    // MARK: - Fixture builder

    private static func redRectangleEMF() -> Data {
        var records: [[UInt8]] = []

        // EMR_HEADER (base, 88 bytes). nBytes/nRecords filled after.
        var header: [UInt8] = []
        header += u32(1) + u32(88)                       // iType, nSize
        header += i32(0) + i32(0) + i32(99) + i32(99)    // rclBounds
        header += i32(0) + i32(0) + i32(2645) + i32(2645) // rclFrame
        header += u32(0x464D_4520) + u32(0x0001_0000)    // dSignature, nVersion
        header += u32(168) + u32(5)                       // nBytes, nRecords
        header += u16(1) + u16(0)                         // nHandles, sReserved
        header += u32(0) + u32(0) + u32(0)                // nDescription, offDescription, nPalEntries
        header += i32(1920) + i32(1080)                   // szlDevice
        header += i32(320) + i32(240)                     // szlMillimeters
        records.append(header)

        // EMR_CREATEBRUSHINDIRECT (ihBrush=1, BS_SOLID red).
        var brush: [UInt8] = []
        brush += u32(39) + u32(24) + u32(1)               // iType, nSize, ihBrush
        brush += u32(0)                                   // BrushStyle BS_SOLID
        brush += [255, 0, 0, 0]                           // ColorRef R,G,B,reserved
        brush += u32(0)                                   // BrushHatch
        records.append(brush)

        // EMR_SELECTOBJECT (ihObject=1).
        records.append(u32(37) + u32(12) + u32(1))

        // EMR_RECTANGLE (10,10)-(50,50).
        records.append(u32(43) + u32(24) + i32(10) + i32(10) + i32(50) + i32(50))

        // EMR_EOF.
        records.append(u32(14) + u32(20) + u32(0) + u32(0) + u32(20))

        return Data(records.flatMap { $0 })
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
    private static func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
}
