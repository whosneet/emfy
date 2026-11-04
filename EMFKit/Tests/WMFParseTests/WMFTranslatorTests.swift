import EMFParse
import Foundation
import Testing
@testable import WMFParse

/// Byte-fixture tests for the WMF → shared-model translation ([MS-WMF] §2.3).
/// Every record decoder is exercised from hand-built bytes — including the
/// reversed field orders, truncated bodies, and lying counts — plus the
/// lowest-free-slot object table and the page setup.
@Suite("WMF translation")
struct WMFTranslatorTests {

    /// Builds a standard (non-placeable) WMF from the given records and returns
    /// the translated payloads AFTER the 5-payload page-setup preamble.
    private static func payloads(_ records: [[UInt8]]) throws -> [EMFRecordPayload] {
        var all = records
        all.append(WMFFixtureBuilder.eof())
        let data = WMFFixtureBuilder.file(header: WMFFixtureBuilder.metaHeader(), records: all)
        let file = try WMFFile.parse(data)
        let program = WMFTranslator.translate(file)
        #expect(program.payloads.count >= 5)
        return Array(program.payloads.dropFirst(5))
    }

    private static func body(_ build: (inout WMFFixtureBuilder) -> Void) -> [UInt8] {
        var b = WMFFixtureBuilder()
        build(&b)
        return b.bytes
    }

    // MARK: - Reversed field orders ([MS-WMF] §2.3.3, §2.3.5)

    @Test("META_MOVETO / META_LINETO decode Y,X (reversed) into x,y")
    func moveLineReversed() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0214, payload: Self.body { $0.appendInt16(5); $0.appendInt16(10) }),   // Y=5, X=10
            WMFFixtureBuilder.record(function: 0x0213, payload: Self.body { $0.appendInt16(7); $0.appendInt16(20) }),   // Y=7, X=20
        ])
        #expect(result == [
            .moveToEx(point: PointL(x: 10, y: 5)),
            .lineTo(point: PointL(x: 20, y: 7)),
        ])
    }

    @Test("META_RECTANGLE decodes Bottom,Right,Top,Left (reversed)")
    func rectangleReversed() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x041B, payload: Self.body {
                $0.appendInt16(40); $0.appendInt16(30); $0.appendInt16(20); $0.appendInt16(10)   // B,R,T,L
            }),
        ])
        #expect(result == [.rectangle(box: RectL(left: 10, top: 20, right: 30, bottom: 40))])
    }

    @Test("META_ROUNDRECT decodes Height,Width,Bottom,Right,Top,Left")
    func roundRectReversed() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x061C, payload: Self.body {
                $0.appendInt16(8); $0.appendInt16(6)                           // Height, Width
                $0.appendInt16(40); $0.appendInt16(30); $0.appendInt16(20); $0.appendInt16(10)   // B,R,T,L
            }),
        ])
        #expect(result == [.roundRect(RoundRectPayload(
            box: RectL(left: 10, top: 20, right: 30, bottom: 40),
            corner: SizeL(cx: 6, cy: 8)
        ))])
    }

    @Test("META_ARC / META_PIE / META_CHORD decode box + both radials")
    func arcFamily() throws {
        // YEnd=1,XEnd=2,YStart=3,XStart=4,B=40,R=30,T=20,L=10
        func arcBody() -> [UInt8] {
            Self.body {
                $0.appendInt16(1); $0.appendInt16(2); $0.appendInt16(3); $0.appendInt16(4)
                $0.appendInt16(40); $0.appendInt16(30); $0.appendInt16(20); $0.appendInt16(10)
            }
        }
        let expected = ArcPayload(
            box: RectL(left: 10, top: 20, right: 30, bottom: 40),
            start: PointL(x: 4, y: 3),
            end: PointL(x: 2, y: 1)
        )
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0817, payload: arcBody()),
            WMFFixtureBuilder.record(function: 0x081A, payload: arcBody()),
            WMFFixtureBuilder.record(function: 0x0830, payload: arcBody()),
        ])
        #expect(result == [.arc(expected), .pie(expected), .chord(expected)])
    }

    @Test("META_SETPIXEL decodes ColorRef then Y,X")
    func setPixel() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x041F, payload: Self.body {
                $0.appendBytes([10, 20, 30, 0])           // ColorRef R,G,B,reserved
                $0.appendInt16(7); $0.appendInt16(9)      // Y=7, X=9
            }),
        ])
        #expect(result == [.setPixel(point: PointL(x: 9, y: 7), color: ColorRef(red: 10, green: 20, blue: 30))])
    }

    @Test("META_PATBLT decodes rop + Height,Width,YLeft,XLeft into a rect")
    func patBlt() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x061D, payload: Self.body {
                $0.appendUInt32(0x00F0_0021)              // PATCOPY
                $0.appendInt16(30); $0.appendInt16(40)    // Height=30, Width=40
                $0.appendInt16(5); $0.appendInt16(3)      // YLeft=5, XLeft=3
            }),
        ])
        #expect(result == [.patBlt(
            bounds: RectL(left: 3, top: 5, right: 43, bottom: 35),
            rasterOperation: 0x00F0_0021
        )])
    }

    @Test("META_EXCLUDECLIPRECT / META_INTERSECTCLIPRECT decode Bottom,Right,Top,Left")
    func clipRects() throws {
        func clipBody() -> [UInt8] {
            Self.body { $0.appendInt16(40); $0.appendInt16(30); $0.appendInt16(20); $0.appendInt16(10) }
        }
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0416, payload: clipBody()),
            WMFFixtureBuilder.record(function: 0x0415, payload: clipBody()),
        ])
        let rect = RectL(left: 10, top: 20, right: 30, bottom: 40)
        #expect(result == [.intersectClipRect(clip: rect), .excludeClipRect(clip: rect)])
    }

    // MARK: - Polygons and counts (§8 validation)

    @Test("META_POLYGON / META_POLYLINE decode PointS arrays")
    func polygons() throws {
        func polyBody(_ points: [(Int16, Int16)]) -> [UInt8] {
            Self.body {
                $0.appendInt16(Int16(points.count))
                for (x, y) in points { $0.appendInt16(x); $0.appendInt16(y) }
            }
        }
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0324, payload: polyBody([(0, 0), (10, 0), (5, 9)])),
            WMFFixtureBuilder.record(function: 0x0325, payload: polyBody([(1, 1), (2, 2)])),
        ])
        #expect(result == [
            .polygon16(Poly16PointsPayload(bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
                                           points: [PointS(x: 0, y: 0), PointS(x: 10, y: 0), PointS(x: 5, y: 9)])),
            .polyline16(Poly16PointsPayload(bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
                                            points: [PointS(x: 1, y: 1), PointS(x: 2, y: 2)])),
        ])
    }

    @Test("META_POLYPOLYGON decodes per-polygon counts and all points")
    func polyPolygon() throws {
        let body = Self.body {
            $0.appendUInt16(2)                    // NumberOfPolygons
            $0.appendUInt16(3); $0.appendUInt16(2) // counts
            for (x, y) in [(0, 0), (10, 0), (5, 9), (1, 1), (2, 2)] {
                $0.appendInt16(Int16(x)); $0.appendInt16(Int16(y))
            }
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0538, payload: body)])
        #expect(result == [.polyPolygon16(PolyPoly16Payload(
            bounds: RectL(left: 0, top: 0, right: 0, bottom: 0),
            pointCounts: [3, 2],
            points: [PointS(x: 0, y: 0), PointS(x: 10, y: 0), PointS(x: 5, y: 9), PointS(x: 1, y: 1), PointS(x: 2, y: 2)]
        ))])
    }

    @Test("a polygon whose NumberOfPoints lies past the record is skipped (§8)")
    func lyingPolygonCount() throws {
        // Claim 100 points but carry only 2.
        let body = Self.body {
            $0.appendInt16(100)
            $0.appendInt16(1); $0.appendInt16(1)
            $0.appendInt16(2); $0.appendInt16(2)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0324, payload: body)])
        #expect(result.isEmpty)
    }

    @Test("a polypolygon whose sub-counts overrun the record is skipped (§8)")
    func lyingPolyPolygonCount() throws {
        let body = Self.body {
            $0.appendUInt16(1)
            $0.appendUInt16(9999)                  // one polygon claiming 9999 points
            $0.appendInt16(1); $0.appendInt16(1)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0538, payload: body)])
        #expect(result.isEmpty)
    }

    @Test("a truncated MOVETO body is skipped, not crashed")
    func truncatedMoveTo() throws {
        // Only 2 bytes where 4 are needed (a lying RecordSize the walker still
        // admitted because it is >= 3 WORDs with padding).
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0214, payload: [0x05, 0x00]),
        ])
        #expect(result.isEmpty)
    }

    // MARK: - Object table ([MS-WMF] §3.1.4.1)

    private static func penBody(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        body {
            $0.appendUInt16(0)          // PenStyle PS_SOLID
            $0.appendInt16(0); $0.appendInt16(0)   // Width PointS (cosmetic)
            $0.appendBytes([r, g, b, 0])
        }
    }

    private static func brushBody(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        body {
            $0.appendUInt16(0)          // BS_SOLID
            $0.appendBytes([r, g, b, 0])
            $0.appendUInt16(0)          // BrushHatch
        }
    }

    @Test("objects take the lowest free slot; a freed slot is reused")
    func lowestFreeSlotReuse() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FA, payload: Self.penBody(r: 0, g: 0, b: 0)),      // pen → slot 0 (ih 1)
            WMFFixtureBuilder.record(function: 0x02FC, payload: Self.brushBody(r: 1, g: 1, b: 1)),    // brush → slot 1 (ih 2)
            WMFFixtureBuilder.record(function: 0x01F0, payload: Self.body { $0.appendUInt16(0) }),    // delete slot 0
            WMFFixtureBuilder.record(function: 0x02FC, payload: Self.brushBody(r: 2, g: 2, b: 2)),    // brush → slot 0 reused (ih 1)
            WMFFixtureBuilder.record(function: 0x012D, payload: Self.body { $0.appendUInt16(0) }),    // select slot 0
        ])
        #expect(result.count == 5)
        guard case .createPen(let pen) = result[0] else { Issue.record("expected createPen"); return }
        #expect(pen.ihPen == 1)
        guard case .createBrushIndirect(let brush1) = result[1] else { Issue.record("expected createBrush"); return }
        #expect(brush1.ihBrush == 2)
        // The delete of slot 0 (a renderable pen) emits a DC delete of ih 1.
        #expect(result[2] == .deleteObject(.table(index: 1)))
        guard case .createBrushIndirect(let brush2) = result[3] else { Issue.record("expected reused createBrush"); return }
        #expect(brush2.ihBrush == 1)      // slot 0 reused
        #expect(result[4] == .selectObject(.table(index: 1)))
    }

    @Test("an unrenderable creator (CREATEPALETTE) still consumes a slot")
    func unrenderableCreatorConsumesSlot() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FA, payload: Self.penBody(r: 0, g: 0, b: 0)),     // pen → slot 0
            WMFFixtureBuilder.record(function: 0x00F7, payload: Self.body { $0.appendUInt16(0x0300) }), // CREATEPALETTE → slot 1
            WMFFixtureBuilder.record(function: 0x02FC, payload: Self.brushBody(r: 1, g: 1, b: 1)),    // brush → slot 2 (ih 3)
        ])
        #expect(result.count == 3)
        guard case .createPen(let pen) = result[0] else { Issue.record("expected createPen"); return }
        #expect(pen.ihPen == 1)
        #expect(result[1] == .unimplemented(type: 0x00F7))
        guard case .createBrushIndirect(let brush) = result[2] else { Issue.record("expected createBrush"); return }
        #expect(brush.ihBrush == 3)       // slot 2 → ih 3, because the palette holds slot 1
    }

    @Test("SELECTOBJECT of an allocated slot emits a table select (idx + 1)")
    func selectEmitsTableIndex() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FA, payload: Self.penBody(r: 0, g: 0, b: 0)),   // slot 0
            WMFFixtureBuilder.record(function: 0x012D, payload: Self.body { $0.appendUInt16(0) }), // select slot 0
        ])
        #expect(result.last == .selectObject(.table(index: 1)))
    }

    @Test("SELECTOBJECT with the high bit set selects a stock object")
    func selectStockObject() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x012D, payload: Self.body { $0.appendUInt16(0x8000) }),
        ])
        #expect(result == [.selectObject(ObjectHandle(raw: 0x8000_0000))])
    }

    @Test("out-of-range SELECTOBJECT / DELETEOBJECT indices are skipped")
    func outOfRangeSelectDelete() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x012D, payload: Self.body { $0.appendUInt16(5000) }), // >= cap
            WMFFixtureBuilder.record(function: 0x01F0, payload: Self.body { $0.appendUInt16(5000) }),
        ])
        #expect(result.isEmpty)
    }

    @Test("deleting an unrenderable (never-rendered) slot emits no DC delete")
    func deleteUnrenderableSlot() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x00F7, payload: Self.body { $0.appendUInt16(0x0300) }), // palette → slot 0
            WMFFixtureBuilder.record(function: 0x01F0, payload: Self.body { $0.appendUInt16(0) }),      // delete slot 0
        ])
        // Only the palette's unimplemented note — no deleteObject.
        #expect(result == [.unimplemented(type: 0x00F7)])
    }

    // MARK: - Page setup ([MS-WMF] §2.3.2.3, §3.1.4.2)

    @Test("placeable page setup sizes the canvas from BoundingBox and Inch")
    func placeablePageSetup() throws {
        let placeable = WMFFixtureBuilder.placeable(boundingBox: (0, 0, 192, 144), inch: 96)
        let data = WMFFixtureBuilder.file(
            placeable: placeable,
            header: WMFFixtureBuilder.metaHeader(),
            records: [WMFFixtureBuilder.eof()]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        #expect(program.canvasWidth == 192)
        #expect(program.canvasHeight == 144)
        #expect(Array(program.payloads.prefix(5)) == [
            .setMapMode(.anisotropic),
            .setWindowOrgEx(origin: PointL(x: 0, y: 0)),
            .setWindowExtEx(extent: SizeL(cx: 192, cy: 144)),
            .setViewportOrgEx(origin: PointL(x: 0, y: 0)),
            .setViewportExtEx(extent: SizeL(cx: 192, cy: 144)),
        ])
    }

    @Test("standard page setup sizes the canvas from the first SETWINDOWEXT")
    func standardPageSetup() throws {
        // SETWINDOWEXT body is Y,X — X=200, Y=120.
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(),
            records: [
                WMFFixtureBuilder.record(function: 0x020C, payload: Self.body { $0.appendInt16(120); $0.appendInt16(200) }),
                WMFFixtureBuilder.eof(),
            ]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        #expect(program.canvasWidth == 200)
        #expect(program.canvasHeight == 120)
    }

    @Test("a standard WMF with no window extent falls back to 1024×768")
    func standardFallbackCanvas() throws {
        let data = WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(),
            records: [WMFFixtureBuilder.eof()]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        #expect(program.canvasWidth == 1024)
        #expect(program.canvasHeight == 768)
    }

    @Test("a hostile zero Inch falls back to a logical-unit canvas, clamped")
    func hostileZeroInch() throws {
        let placeable = WMFFixtureBuilder.placeable(boundingBox: (0, 0, 300, 200), inch: 0)
        let data = WMFFixtureBuilder.file(
            placeable: placeable,
            header: WMFFixtureBuilder.metaHeader(),
            records: [WMFFixtureBuilder.eof()]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        // Inch 0 → the logical span is used directly (300×200), still clamped.
        #expect(program.canvasWidth == 300)
        #expect(program.canvasHeight == 200)
    }

    @Test("a hostile huge BoundingBox is clamped to the per-side cap")
    func hostileHugeBoundingBox() throws {
        // bbox 32000 logical at inch 1 → would be 3.07 Mpx/side; clamped to 16384.
        let placeable = WMFFixtureBuilder.placeable(boundingBox: (0, 0, 32000, 100), inch: 1)
        let data = WMFFixtureBuilder.file(
            placeable: placeable,
            header: WMFFixtureBuilder.metaHeader(),
            records: [WMFFixtureBuilder.eof()]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        #expect(program.canvasWidth <= 16384)
        #expect(program.canvasWidth >= 1)
        #expect(program.canvasHeight >= 1)
    }

    @Test("a zero-extent BoundingBox keeps a finite window extent (no divide by zero)")
    func zeroExtentBoundingBox() throws {
        let placeable = WMFFixtureBuilder.placeable(boundingBox: (0, 0, 0, 0), inch: 96)
        let data = WMFFixtureBuilder.file(
            placeable: placeable,
            header: WMFFixtureBuilder.metaHeader(),
            records: [WMFFixtureBuilder.eof()]
        )
        let program = WMFTranslator.translate(try WMFFile.parse(data))
        #expect(program.canvasWidth == 1)
        #expect(program.canvasHeight == 1)
        // windowExt must be non-zero so the DC mapping stays finite.
        #expect(program.payloads[2] == .setWindowExtEx(extent: SizeL(cx: 1, cy: 1)))
    }
}
