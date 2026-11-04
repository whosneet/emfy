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

    // MARK: - W4b fixtures: text ([MS-WMF] §2.2.1.2, §2.3.3.20, §2.3.3.5)

    /// A 16-bit Font Object body ([MS-WMF] §2.2.1.2): 18 fixed bytes then a
    /// 32-byte NUL-padded Latin-1 Facename.
    private static func fontBody(
        height: Int16 = -20, weight: Int16 = 400,
        italic: UInt8 = 0, underline: UInt8 = 0, strikeOut: UInt8 = 0,
        charSet: UInt8 = 0, faceName: String = "Arial"
    ) -> [UInt8] {
        Self.body {
            $0.appendInt16(height); $0.appendInt16(0); $0.appendInt16(0); $0.appendInt16(0)
            $0.appendInt16(weight)
            $0.appendBytes([italic, underline, strikeOut, charSet, 0, 0, 0, 0])
            var name = Array(faceName.utf8).prefix(31).map { $0 }
            name.append(0)
            while name.count < 32 { name.append(0) }
            $0.appendBytes(name)
        }
    }

    @Test("META_CREATEFONTINDIRECT translates the 16-bit Font into the shared LOGFONT")
    func createFontIndirect() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FB, payload: Self.fontBody(
                height: -28, weight: 700, italic: 1, charSet: 0, faceName: "Arial"
            )),
        ])
        guard case .extCreateFontIndirectW(let payload) = result.first else {
            Issue.record("expected extCreateFontIndirectW, got \(String(describing: result.first))")
            return
        }
        #expect(payload.ihFonts == 1)                 // first creator → slot 0 → index 1
        #expect(payload.hasExtendedData == false)
        #expect(payload.logFont.height == -28)
        #expect(payload.logFont.weight == 700)
        #expect(payload.logFont.italic == 1)
        #expect(payload.logFont.charSet == 0)
        #expect(payload.logFont.faceName == "Arial")
    }

    @Test("META_TEXTOUT decodes StringLength + even-padded string + reversed Y,X")
    func textOut() throws {
        // StringLength 5 "Hello" (+1 pad), then YStart=30, XStart=10.
        let payload = Self.body {
            $0.appendInt16(5)
            $0.appendBytes(Array("Hello".utf8))
            $0.appendBytes([0])                       // odd-length pad
            $0.appendInt16(30); $0.appendInt16(10)    // YStart, XStart
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0521, payload: payload)])
        #expect(result == [.extTextOutW(ExtTextPayload(
            graphicsMode: 1, exScale: 1, eyScale: 1,
            reference: PointL(x: 10, y: 30),
            rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0),
            string: "Hello", options: ExtTextOutOptions(rawValue: 0), dx: nil
        ))])
    }

    @Test("META_EXTTEXTOUT with ETO_CLIPPED carries the rect, string, and a validated Dx array")
    func extTextOutWithRectAndDx() throws {
        let payload = Self.body {
            $0.appendInt16(30); $0.appendInt16(10)    // Y, X
            $0.appendInt16(3)                         // StringLength
            $0.appendUInt16(0x0004)                   // fwOpts = ETO_CLIPPED
            $0.appendInt16(1); $0.appendInt16(2); $0.appendInt16(3); $0.appendInt16(4)   // Rect L,T,R,B
            $0.appendBytes(Array("abc".utf8)); $0.appendBytes([0])   // string + pad
            $0.appendInt16(5); $0.appendInt16(6); $0.appendInt16(7)  // Dx (StringLength entries)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0A32, payload: payload)])
        #expect(result == [.extTextOutW(ExtTextPayload(
            graphicsMode: 1, exScale: 1, eyScale: 1,
            reference: PointL(x: 10, y: 30),
            rectangle: RectL(left: 1, top: 2, right: 3, bottom: 4),
            string: "abc", options: ExtTextOutOptions(rawValue: 0x0004), dx: [5, 6, 7]
        ))])
    }

    @Test("SETTEXTALIGN variants pass through ahead of the text run")
    func textAlignVariants() throws {
        for mask in [UInt16(0), 0x0006, 0x0018, 0x0001] {   // LEFT/TOP, CENTER, BASELINE, UPDATECP
            let result = try Self.payloads([
                WMFFixtureBuilder.record(function: 0x012E, payload: Self.body { $0.appendUInt16(mask) }),
                WMFFixtureBuilder.record(function: 0x0521, payload: Self.body {
                    $0.appendInt16(1); $0.appendBytes(Array("X".utf8)); $0.appendBytes([0])
                    $0.appendInt16(0); $0.appendInt16(0)
                }),
            ])
            #expect(result.first == .setTextAlign(TextAlign(rawValue: UInt32(mask))))
            if case .extTextOutW(let text) = result.last {
                #expect(text.string == "X")
            } else {
                Issue.record("expected a text run after SETTEXTALIGN \(mask)")
            }
        }
    }

    @Test("a non-1252 charset string decodes through the selected font's codepage")
    func nonLatinCharsetString() throws {
        // GB2312_CHARSET (134 → codepage 936): bytes D6 D0 decode to 中.
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FB, payload: Self.fontBody(charSet: 134, faceName: "SimSun")),
            WMFFixtureBuilder.record(function: 0x012D, payload: Self.body { $0.appendUInt16(0) }),   // SELECTOBJECT 0
            WMFFixtureBuilder.record(function: 0x0521, payload: Self.body {
                $0.appendInt16(2); $0.appendBytes([0xD6, 0xD0]); $0.appendInt16(0); $0.appendInt16(0)
            }),
        ])
        guard case .extTextOutW(let text) = result.last else {
            Issue.record("expected a text run, got \(String(describing: result.last))")
            return
        }
        #expect(text.string == "中")
    }

    // MARK: - W4b fixtures: bitmaps ([MS-WMF] §2.3.1, §2.2.2.9, §2.2.2.1)

    /// A 40-byte BitmapInfoHeader ([MS-WMF] §2.2.2.3).
    private static func bitmapInfoHeader(width: Int32, height: Int32, bitCount: UInt16) -> [UInt8] {
        Self.body {
            $0.appendUInt32(40)
            $0.appendUInt32(UInt32(bitPattern: width))
            $0.appendUInt32(UInt32(bitPattern: height))
            $0.appendUInt16(1)                        // Planes
            $0.appendUInt16(bitCount)
            $0.appendUInt32(0)                        // BI_RGB
            $0.appendUInt32(0); $0.appendUInt32(0); $0.appendUInt32(0)   // SizeImage, X/Y ppm
            $0.appendUInt32(0); $0.appendUInt32(0)    // ClrUsed, ClrImportant
        }
    }

    @Test("META_STRETCHDIB decodes a packed 24-bit DIB into a stretchDIBits payload")
    func stretchDIB24() throws {
        // 1×1 red (B,G,R) DIB, padded to a 4-byte row.
        let dib = Self.bitmapInfoHeader(width: 1, height: 1, bitCount: 24) + [0, 0, 255, 0]
        let payload = Self.body {
            $0.appendUInt32(0x00CC_0020)              // SRCCOPY
            $0.appendUInt16(0)                        // ColorUsage = DIB_RGB_COLORS
            $0.appendInt16(1); $0.appendInt16(1)      // SrcHeight, SrcWidth
            $0.appendInt16(0); $0.appendInt16(0)      // YSrc, XSrc
            $0.appendInt16(10); $0.appendInt16(10)    // DestHeight, DestWidth
            $0.appendInt16(5); $0.appendInt16(3)      // yDst, xDst
            $0.appendBytes(dib)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0F43, payload: payload)])
        guard case .stretchDIBits(let p) = result.first else {
            Issue.record("expected stretchDIBits, got \(String(describing: result.first))")
            return
        }
        #expect(p.dest == PointL(x: 3, y: 5))
        #expect(p.destSize == SizeL(cx: 10, cy: 10))
        #expect(p.rasterOperation == 0x00CC_0020)
        #expect(p.dib?.bitCount == 24)
        if case .pixels = p.dib?.content {} else { Issue.record("expected decoded DIB pixels") }
    }

    @Test("a 1 bpp DIB is carried as an unsupported DIB, not a crash")
    func dib1bppUnsupported() throws {
        // 8×1 1-bpp DIB (stride 4), BI_RGB. The shared decoder does not expand
        // 1-bpp DIBs, so the content is a valid .unsupported verdict.
        let palette: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 0]   // two RGBQuads
        let dib = Self.bitmapInfoHeader(width: 8, height: 1, bitCount: 1) + palette + [0xAA, 0, 0, 0]
        let payload = Self.body {
            $0.appendUInt32(0x00CC_0020); $0.appendUInt16(0)
            $0.appendInt16(1); $0.appendInt16(8)
            $0.appendInt16(0); $0.appendInt16(0)
            $0.appendInt16(1); $0.appendInt16(8)
            $0.appendInt16(0); $0.appendInt16(0)
            $0.appendBytes(dib)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0F43, payload: payload)])
        guard case .stretchDIBits(let p) = result.first, let decoded = p.dib else {
            Issue.record("expected a stretchDIBits carrying a DIB")
            return
        }
        #expect(decoded.bitCount == 1)
        if case .unsupported(.bitCount(1)) = decoded.content {} else {
            Issue.record("expected an unsupported 1-bpp DIB, got \(decoded.content)")
        }
    }

    @Test("META_BITBLT expands a 1 bpp mono Bitmap16 (DDB) into a 24-bit DIB")
    func ddbMonoBitBlt() throws {
        // Bitmap16: 8×1, WidthBytes 2, Planes 1, BitsPixel 1, bits 0b10101010.
        let bitmap16 = Self.body {
            $0.appendInt16(0)                         // Type
            $0.appendInt16(8); $0.appendInt16(1)      // Width, Height
            $0.appendInt16(2)                         // WidthBytes
            $0.appendBytes([1, 1])                    // Planes, BitsPixel
            $0.appendBytes([0b1010_1010, 0])          // Bits (word-aligned)
        }
        let payload = Self.body {
            $0.appendUInt32(0x00CC_0020)              // SRCCOPY
            $0.appendInt16(0); $0.appendInt16(0)      // YSrc, XSrc
            $0.appendInt16(1); $0.appendInt16(8)      // Height, Width
            $0.appendInt16(0); $0.appendInt16(0)      // YDest, XDest
            $0.appendBytes(bitmap16)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0922, payload: payload)])
        guard case .bitBlt(let p) = result.first, let decoded = p.dib else {
            Issue.record("expected a bitBlt carrying a converted DIB")
            return
        }
        #expect(decoded.bitCount == 24)
        #expect(decoded.width == 8)
        #expect(decoded.height == -1)                 // top-down
        guard case .pixels(let bytes, _, _) = decoded.content else {
            Issue.record("expected expanded mono pixels"); return
        }
        // First bit set → white, second clear → black.
        #expect(bytes[0] == 255 && bytes[3] == 0)
    }

    @Test("a without-bitmap META_DIBBITBLT is a sourceless rop fill")
    func dibBltSourceless() throws {
        // RecordSize == (0x0940 >> 8) + 3 == 12 → no source DIB. Fields:
        // rop, Reserved, YSrc, XSrc, Height, Width, YDest, XDest (no DIB).
        let payload = Self.body {
            $0.appendUInt32(0x00FF_0062)              // WHITENESS
            $0.appendInt16(0)                         // Reserved
            $0.appendInt16(0); $0.appendInt16(0)      // YSrc, XSrc
            $0.appendInt16(4); $0.appendInt16(5)      // Height, Width
            $0.appendInt16(1); $0.appendInt16(2)      // YDest, XDest
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0940, payload: payload)])
        guard case .bitBlt(let p) = result.first else {
            Issue.record("expected a sourceless bitBlt"); return
        }
        #expect(p.dib == nil)
        #expect(p.hasSource == false)
        #expect(p.rasterOperation == 0x00FF_0062)
        #expect(p.dest == PointL(x: 2, y: 1))
        #expect(p.destSize == SizeL(cx: 5, cy: 4))
    }

    // MARK: - W4b fixtures: regions ([MS-WMF] §2.2.1.5, §2.3.4.9)

    /// A Region Object body ([MS-WMF] §2.2.1.5) with the given bounds and one
    /// scan band of (left, right) spans.
    private static func regionBody(
        bounds: (Int16, Int16, Int16, Int16),
        scanTop: UInt16, scanBottom: UInt16, spans: [(UInt16, UInt16)]
    ) -> [UInt8] {
        Self.body {
            $0.appendInt16(0)                         // nextInChain
            $0.appendInt16(6)                         // ObjectType = 0x0006
            $0.appendUInt32(0)                        // ObjectCount
            $0.appendInt16(0)                         // RegionSize (advisory)
            $0.appendInt16(1)                         // ScanCount
            $0.appendInt16(Int16(spans.count * 2))    // maxScan
            $0.appendInt16(bounds.0); $0.appendInt16(bounds.1)
            $0.appendInt16(bounds.2); $0.appendInt16(bounds.3)
            let count = UInt16(spans.count * 2)
            $0.appendUInt16(count); $0.appendUInt16(scanTop); $0.appendUInt16(scanBottom)
            for (l, r) in spans { $0.appendUInt16(l); $0.appendUInt16(r) }
            $0.appendUInt16(count)                    // Count2
        }
    }

    @Test("META_CREATEREGION + META_SELECTCLIPREGION become a copy-mode clip of the region rects")
    func regionClip() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x06FF, payload: Self.regionBody(
                bounds: (0, 0, 50, 50), scanTop: 10, scanBottom: 20, spans: [(5, 45)]
            )),
            WMFFixtureBuilder.record(function: 0x012C, payload: Self.body { $0.appendUInt16(0) }),
        ])
        #expect(result == [.extSelectClipRgn(ExtSelectClipRgnPayload(
            mode: .copy,
            bounds: RectL(left: 0, top: 0, right: 50, bottom: 50),
            rects: [RectL(left: 5, top: 10, right: 45, bottom: 20)]
        ))])
    }

    @Test("META_FILLREGION paints the region rects under a balanced save/restore")
    func fillRegion() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FC, payload: Self.body {   // CREATEBRUSHINDIRECT (slot 0)
                $0.appendUInt16(0); $0.appendBytes([0, 128, 0, 0]); $0.appendUInt16(0)   // solid green
            }),
            WMFFixtureBuilder.record(function: 0x06FF, payload: Self.regionBody(   // region → slot 1
                bounds: (0, 0, 50, 50), scanTop: 0, scanBottom: 30, spans: [(0, 40)]
            )),
            WMFFixtureBuilder.record(function: 0x0228, payload: Self.body {   // FILLREGION region=1 brush=0
                $0.appendUInt16(1); $0.appendUInt16(0)
            }),
        ])
        // After the brush creation, the region fill is: save, NULL_PEN, brush 0,
        // the rect, restore.
        #expect(result == [
            .createBrushIndirect(CreateBrushPayload(ihBrush: 1, style: 0, color: ColorRef(red: 0, green: 128, blue: 0), hatch: 0)),
            .saveDC,
            .selectObject(ObjectHandle(raw: 0x8000_0008)),   // NULL_PEN
            .selectObject(.table(index: 1)),                 // brush slot 0 → index 1
            .rectangle(box: RectL(left: 0, top: 0, right: 40, bottom: 30)),
            .restoreDC(savedDC: -1),
        ])
    }

    @Test("META_DIBCREATEPATTERNBRUSH falls back to a solid brush in its slot")
    func patternBrushFallback() throws {
        // Style(2), ColorUsage(2), then a tiny DIB tail (ignored for the fallback).
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0142, payload: Self.body {
                $0.appendUInt16(5); $0.appendUInt16(0)
                $0.appendBytes(Self.bitmapInfoHeader(width: 1, height: 1, bitCount: 24) + [0, 0, 0, 0])
            }),
        ])
        #expect(result == [.createBrushIndirect(CreateBrushPayload(
            ihBrush: 1, style: 5, color: ColorRef(red: 0x80, green: 0x80, blue: 0x80), hatch: 0
        ))])
    }

    // MARK: - W4b abuse cases (§8: no crash, bounded, graceful skip)

    @Test("a lying TEXTOUT StringLength is rejected, not over-read")
    func abuseLyingTextLength() throws {
        // StringLength 1000 but only a few payload bytes: the record is skipped.
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0521, payload: Self.body {
                $0.appendInt16(1000); $0.appendBytes(Array("hi".utf8)); $0.appendInt16(0); $0.appendInt16(0)
            }),
        ])
        #expect(result.isEmpty)
    }

    @Test("a lying EXTTEXTOUT Dx array is dropped; the run still decodes")
    func abuseLyingDx() throws {
        // StringLength 3, no room for a 3-entry Dx: dx is nil, string survives.
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x0A32, payload: Self.body {
                $0.appendInt16(0); $0.appendInt16(0)   // Y, X
                $0.appendInt16(3); $0.appendUInt16(0)  // StringLength, fwOpts (no rect)
                $0.appendBytes(Array("abc".utf8)); $0.appendBytes([0])   // string + pad, no Dx
            }),
        ])
        guard case .extTextOutW(let text) = result.first else {
            Issue.record("expected a text run"); return
        }
        #expect(text.string == "abc")
        #expect(text.dx == nil)
    }

    @Test("a hostile Bitmap16 dimension is skipped, not allocated")
    func abuseHugeBitmap16() throws {
        // Width/Height/WidthBytes all 0x7FFF: width*height far over the area cap.
        let bitmap16 = Self.body {
            $0.appendInt16(0)
            $0.appendInt16(0x7FFF); $0.appendInt16(0x7FFF)
            $0.appendInt16(0x7FFF)
            $0.appendBytes([1, 24])
            $0.appendBytes([0, 0, 0, 0])
        }
        let payload = Self.body {
            $0.appendUInt32(0x00CC_0020)
            $0.appendInt16(0); $0.appendInt16(0)
            $0.appendInt16(1); $0.appendInt16(1)
            $0.appendInt16(0); $0.appendInt16(0)
            $0.appendBytes(bitmap16)
        }
        let result = try Self.payloads([WMFFixtureBuilder.record(function: 0x0922, payload: payload)])
        // The DDB cannot be mapped, so the record is logged and skipped.
        #expect(result == [.unimplemented(type: 0x0922)])
    }

    @Test("a hostile region ScanCount yields a bounded, partial rect union")
    func abuseHugeRegionScanCount() throws {
        // ScanCount 10000 but only one real scan present: the walk stops at the
        // record boundary with the one valid rect, never over-reading.
        let body = Self.body {
            $0.appendInt16(0); $0.appendInt16(6); $0.appendUInt32(0)
            $0.appendInt16(0)                         // RegionSize
            $0.appendInt16(10000)                     // ScanCount (lying)
            $0.appendInt16(2)                         // maxScan
            $0.appendInt16(0); $0.appendInt16(0); $0.appendInt16(50); $0.appendInt16(50)
            $0.appendUInt16(2); $0.appendUInt16(0); $0.appendUInt16(30)   // one scan
            $0.appendUInt16(0); $0.appendUInt16(40)
            $0.appendUInt16(2)
        }
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x06FF, payload: body),
            WMFFixtureBuilder.record(function: 0x012C, payload: Self.body { $0.appendUInt16(0) }),
        ])
        guard case .extSelectClipRgn(let p) = result.first else {
            Issue.record("expected a clip region"); return
        }
        #expect(p.rects == [RectL(left: 0, top: 0, right: 40, bottom: 30)])
    }

    @Test("an extreme font height passes through without trapping")
    func abuseHugeFontHeight() throws {
        let result = try Self.payloads([
            WMFFixtureBuilder.record(function: 0x02FB, payload: Self.fontBody(height: Int16.min)),
        ])
        guard case .extCreateFontIndirectW(let payload) = result.first else {
            Issue.record("expected a font payload"); return
        }
        #expect(payload.logFont.height == Int32(Int16.min))
    }

    @Test("a hostile fill-then-churn object stream allocates in bounded time, lowest-free")
    func abuseObjectTableChurn() throws {
        // CREATEBRUSHINDIRECT emits ihBrush = slot + 1, so slot assignment is
        // observable. DELETEOBJECT frees a slot by table index.
        let brush = WMFFixtureBuilder.record(function: 0x02FC, payload: Self.body {
            $0.appendUInt16(0); $0.appendBytes([0, 0, 0, 0]); $0.appendUInt16(0)
        })
        func del(_ slot: UInt16) -> [UInt8] {
            WMFFixtureBuilder.record(function: 0x01F0, payload: Self.body { $0.appendUInt16(slot) })
        }

        var records: [[UInt8]] = []
        records.reserveCapacity(205_000)
        // Fill all 4096 slots (lowest-free → slots 0…4095, indices 1…4096).
        for _ in 0 ..< 4096 { records.append(brush) }
        // Churn: free a low slot + create (fast lowest-free), free a high slot +
        // create (word scan to the top), then create while FULL (O(1) fail-fast).
        // 40000 × 5 = 200k records of the worst-case create/free pattern.
        for _ in 0 ..< 40_000 {
            records.append(del(20)); records.append(brush)
            records.append(del(4090)); records.append(brush)
            records.append(brush)
        }
        // Final deterministic probe: free slots 7 and 9, create twice → 7 then 9.
        records.append(del(7)); records.append(del(9))
        records.append(brush); records.append(brush)
        records.append(WMFFixtureBuilder.eof())

        let data = WMFFixtureBuilder.file(header: WMFFixtureBuilder.metaHeader(), records: records)
        let file = try WMFFile.parse(data)

        let start = ContinuousClock.now
        let program = WMFTranslator.translate(file)
        let elapsed = ContinuousClock.now - start
        // Bounded time on hostile input (§8): the old linear scan was ~4e9 Set
        // lookups here; the bitset makes this trivial. Generous debug bound.
        #expect(elapsed < .seconds(2), "object-table churn took \(elapsed)")

        let brushes = program.payloads.compactMap { payload -> UInt32? in
            if case .createBrushIndirect(let p) = payload { return p.ihBrush }
            return nil
        }
        // Lowest-free during the fill: slots 0…4095 → indices 1…4096 in order.
        #expect(Array(brushes.prefix(4096)) == (1 ... 4096).map(UInt32.init))
        // First churn reuse: freed low slot 20 (index 21), then high slot 4090.
        #expect(brushes[4096] == 21)
        #expect(brushes[4097] == 4091)
        // Final probe: lowest-free picks slot 7 (index 8) then slot 9 (index 10).
        #expect(Array(brushes.suffix(2)) == [8, 10])
    }
}
