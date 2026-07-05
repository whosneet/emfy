import Foundation
import Testing
@testable import EMFParse

@Suite("State record payload decode")
struct PayloadStateTests {

    @Test("window/viewport extents and origins")
    func extentsAndOrigins() throws {
        var extent = FixtureBuilder()
        extent.appendInt32(800)
        extent.appendInt32(600)
        #expect(try decodeSingle(FixtureBuilder.record(type: 9, payload: extent.bytes))
            == .setWindowExtEx(extent: SizeL(cx: 800, cy: 600)))
        #expect(try decodeSingle(FixtureBuilder.record(type: 11, payload: extent.bytes))
            == .setViewportExtEx(extent: SizeL(cx: 800, cy: 600)))

        var origin = FixtureBuilder()
        origin.appendInt32(-10)
        origin.appendInt32(20)
        #expect(try decodeSingle(FixtureBuilder.record(type: 10, payload: origin.bytes))
            == .setWindowOrgEx(origin: PointL(x: -10, y: 20)))
        #expect(try decodeSingle(FixtureBuilder.record(type: 12, payload: origin.bytes))
            == .setViewportOrgEx(origin: PointL(x: -10, y: 20)))
    }

    @Test("mode records: map, background, polyfill, ROP2, incl. unknown raws")
    func modeRecords() throws {
        func modePayload(_ raw: UInt32) -> [UInt8] {
            var b = FixtureBuilder()
            b.appendUInt32(raw)
            return b.bytes
        }

        // MapMode ([MS-EMF] §2.1.21): known and unknown values.
        #expect(try decodeSingle(FixtureBuilder.record(type: 17, payload: modePayload(1)))
            == .setMapMode(.text))
        #expect(try decodeSingle(FixtureBuilder.record(type: 17, payload: modePayload(8)))
            == .setMapMode(.anisotropic))
        #expect(try decodeSingle(FixtureBuilder.record(type: 17, payload: modePayload(99)))
            == .setMapMode(.unknown(99)))

        // BackgroundMode ([MS-EMF] §2.1.4): TRANSPARENT=1, OPAQUE=2.
        #expect(try decodeSingle(FixtureBuilder.record(type: 18, payload: modePayload(1)))
            == .setBkMode(.transparent))
        #expect(try decodeSingle(FixtureBuilder.record(type: 18, payload: modePayload(2)))
            == .setBkMode(.opaque))
        #expect(try decodeSingle(FixtureBuilder.record(type: 18, payload: modePayload(7)))
            == .setBkMode(.unknown(7)))

        // PolygonFillMode ([MS-EMF] §2.1.27): ALTERNATE=1, WINDING=2.
        #expect(try decodeSingle(FixtureBuilder.record(type: 19, payload: modePayload(1)))
            == .setPolyFillMode(.alternate))
        #expect(try decodeSingle(FixtureBuilder.record(type: 19, payload: modePayload(2)))
            == .setPolyFillMode(.winding))
        #expect(try decodeSingle(FixtureBuilder.record(type: 19, payload: modePayload(9)))
            == .setPolyFillMode(.unknown(9)))

        // SETROP2 exposes the raw mode (R2_COPYPEN = 0x0D).
        #expect(try decodeSingle(FixtureBuilder.record(type: 20, payload: modePayload(0x0D)))
            == .setROP2(rawMode: 0x0D))
    }

    @Test("saveDC and restoreDC")
    func saveAndRestore() throws {
        // EMR_SAVEDC has no parameters ([MS-EMF] §2.3.11): 8-byte record.
        #expect(try decodeSingle(FixtureBuilder.record(type: 33, payload: [])) == .saveDC)

        // EMR_RESTOREDC §2.3.11.6: signed SavedDC, -1 = most recent.
        var b = FixtureBuilder()
        b.appendInt32(-1)
        #expect(try decodeSingle(FixtureBuilder.record(type: 34, payload: b.bytes))
            == .restoreDC(savedDC: -1))
    }

    @Test("setMiterLimit decodes the spec's unsigned integer")
    func miterLimit() throws {
        // [MS-EMF] §2.3.11.21 defines MiterLimit as an unsigned integer
        // (unlike the GDI API's float).
        var b = FixtureBuilder()
        b.appendUInt32(10)
        #expect(try decodeSingle(FixtureBuilder.record(type: 58, payload: b.bytes))
            == .setMiterLimit(miterLimit: 10))
    }

    @Test("setWorldTransform golden: six little-endian floats in spec order")
    func setWorldTransformGolden() throws {
        var b = FixtureBuilder()
        b.appendFloat(2.0)      // M11
        b.appendFloat(0.5)      // M12
        b.appendFloat(-0.5)     // M21
        b.appendFloat(2.0)      // M22
        b.appendFloat(10.0)     // Dx
        b.appendFloat(-20.0)    // Dy
        let expected = XForm(m11: 2.0, m12: 0.5, m21: -0.5, m22: 2.0, dx: 10.0, dy: -20.0)
        #expect(try decodeSingle(FixtureBuilder.record(type: 35, payload: b.bytes))
            == .setWorldTransform(expected))
    }

    @Test("modifyWorldTransform golden incl. unknown mode")
    func modifyWorldTransformGolden() throws {
        var b = FixtureBuilder()
        b.appendFloat(1.0)
        b.appendFloat(0.0)
        b.appendFloat(0.0)
        b.appendFloat(1.0)
        b.appendFloat(5.0)
        b.appendFloat(6.0)
        b.appendUInt32(2)       // MWT_LEFTMULTIPLY
        let xform = XForm(m11: 1, m12: 0, m21: 0, m22: 1, dx: 5, dy: 6)
        #expect(try decodeSingle(FixtureBuilder.record(type: 36, payload: b.bytes))
            == .modifyWorldTransform(ModifyWorldTransformPayload(transform: xform, mode: .leftMultiply)))

        var unknownMode = FixtureBuilder()
        unknownMode.appendBytes(Array(b.bytes[0 ..< 24]))
        unknownMode.appendUInt32(9)
        #expect(try decodeSingle(FixtureBuilder.record(type: 36, payload: unknownMode.bytes))
            == .modifyWorldTransform(ModifyWorldTransformPayload(transform: xform, mode: .unknown(9))))
    }

    @Test("XForm rejects NaN and infinity as nonFiniteTransform")
    func xformNonFinite() throws {
        // SETWORLDTRANSFORM with M11 = NaN.
        var nan = FixtureBuilder()
        nan.appendFloat(Float.nan)
        for _ in 0 ..< 5 { nan.appendFloat(0) }
        #expect(try decodeSingle(FixtureBuilder.record(type: 35, payload: nan.bytes))
            == .malformed(type: 35, reason: .nonFiniteTransform))

        // MODIFYWORLDTRANSFORM with Dx = +infinity.
        var inf = FixtureBuilder()
        for _ in 0 ..< 4 { inf.appendFloat(1) }
        inf.appendFloat(Float.infinity)
        inf.appendFloat(0)
        inf.appendUInt32(4)     // MWT_SET
        #expect(try decodeSingle(FixtureBuilder.record(type: 36, payload: inf.bytes))
            == .malformed(type: 36, reason: .nonFiniteTransform))
    }

    @Test("intersectClipRect golden")
    func intersectClipRect() throws {
        var b = FixtureBuilder()
        b.appendInt32(0)
        b.appendInt32(0)
        b.appendInt32(21000)
        b.appendInt32(29700)
        #expect(try decodeSingle(FixtureBuilder.record(type: 30, payload: b.bytes))
            == .intersectClipRect(clip: RectL(left: 0, top: 0, right: 21000, bottom: 29700)))
    }

    @Test("payload too small: walk-valid record, malformed payload verdict")
    func payloadTooSmall() throws {
        // An 8-byte EMR_SETMAPMODE is a valid record at walk level but has
        // no room for its mode field.
        let (file, record) = try parseWithSingleRecord(
            FixtureBuilder.record(type: 17, payload: [])
        )
        #expect(file.diagnostics.isEmpty)
        #expect(file.payload(of: record)
            == .malformed(type: 17, reason: .tooSmall(minimumSize: 12, actualSize: 8)))
    }
}
