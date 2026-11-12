import CoreGraphics
import Foundation
import Testing
import EMFParse
import EMFRender
import EMFWrite
import WMFParse

/// From-scratch WMF builder: object-slot allocation and NumberOfObjects, the
/// typed overflow guards, a render pass over a rectangle / ellipse / polygon /
/// text / DIB through `MetafileRenderer`, the optional embedded EMF, and WMZ.
@Suite("WMF document builder")
struct WMFBuilderTests {

    static let bbox = WMFRect16(left: 0, top: 0, right: 96, bottom: 96)

    static func newBuilder(embeddedEMF: Data? = nil) -> WMFDocumentBuilder {
        WMFDocumentBuilder(boundingBox: bbox, unitsPerInch: 96, embeddedEMF: embeddedEMF)
    }

    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ColorRef { ColorRef(red: r, green: g, blue: b) }

    /// Appends SETWINDOWORG (0,0) / SETWINDOWEXT (96,96) so the window maps 1:1 to
    /// the placeable 96×96 device canvas.
    static func setWindow(_ b: WMFDocumentBuilder) throws {
        try b.append(.setWindowOrg(PointL(x: 0, y: 0)))
        try b.append(.setWindowExt(SizeL(cx: 96, cy: 96)))
    }

    // MARK: - Object slots

    @Test func slotAllocationReusesLowestFree() throws {
        let b = Self.newBuilder()
        let s0 = try b.append(.createBrushIndirect(style: 0, color: Self.color(1, 2, 3), hatch: 0))
        let s1 = try b.append(.createPenIndirect(style: 0, width: 1, color: Self.color(0, 0, 0)))
        try b.append(.deleteObject(index: 0))   // free slot 0
        let s0b = try b.append(.createFontIndirect(LogFont(
            height: -12, width: 0, escapement: 0, orientation: 0, weight: 400,
            italic: 0, underline: 0, strikeOut: 0, charSet: 0, outPrecision: 0,
            clipPrecision: 0, quality: 0, pitchAndFamily: 0, faceName: "Arial")))
        #expect(s0 == 0, "first create should take slot 0, got \(String(describing: s0))")
        #expect(s1 == 1, "second create should take slot 1, got \(String(describing: s1))")
        #expect(s0b == 0, "after freeing slot 0, the next create should reuse it, got \(String(describing: s0b))")

        // NumberOfObjects is the peak table size: slots 0 and 1 were alive at once.
        let file = try WMFFile.parse(try b.finish())
        #expect(file.header.numberOfObjects == 2, "NumberOfObjects \(file.header.numberOfObjects), expected 2")
    }

    @Test func numberOfObjectsIsPeak() throws {
        let b = Self.newBuilder()
        _ = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 0, 0), hatch: 0))
        _ = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 0, 0), hatch: 0))
        _ = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 0, 0), hatch: 0))
        let file = try WMFFile.parse(try b.finish())
        #expect(file.header.numberOfObjects == 3)
    }

    @Test func objectTableOverflowThrows() throws {
        let b = Self.newBuilder()
        var created = 0
        do {
            while created < 70000 {
                _ = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 0, 0), hatch: 0))
                created += 1
            }
            Issue.record("expected an object-table overflow")
        } catch {
            #expect(error == .objectTableOverflow(slot: 65535))
            #expect(created == 65535, "filled \(created) slots before overflow")
        }
    }

    // MARK: - Smoke

    @Test func outputIsPlaceableAndParses() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let data = try b.finish()
        let opened = try OpenedMetafile.open(data)
        #expect(opened.format == .placeableWMF)
        let file = try WMFFile.parse(data)
        #expect(file.placeable != nil)
        #expect(file.placeable?.checksumOK == true, "placeable checksum should verify")
        #expect(file.placeable?.boundingBox == Self.bbox)
        // The records list ends with exactly one META_EOF.
        #expect(file.records.last?.function == 0x0000)
        #expect(file.records.filter { $0.function == 0x0000 }.count == 1)
    }

    // MARK: - Render each primitive

    @Test func rectangleRendersRed() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let slot = try b.append(.createBrushIndirect(style: 0, color: Self.color(255, 0, 0), hatch: 0))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.rectangle(RectL(left: 0, top: 0, right: 96, bottom: 96)))
        let r = try renderMetafile(try b.finish())
        #expect(r.width == 96 && r.height == 96)
        #expect(near(r.pixel(48, 48), 255, 0, 0), "centre not red: \(r.pixel(48, 48))")
    }

    @Test func ellipseRendersBlue() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let slot = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 0, 255), hatch: 0))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.ellipse(RectL(left: 0, top: 0, right: 96, bottom: 96)))
        let r = try renderMetafile(try b.finish())
        #expect(near(r.pixel(48, 48), 0, 0, 255), "centre not blue: \(r.pixel(48, 48))")
        #expect(near(r.pixel(3, 3), 255, 255, 255), "corner not white page: \(r.pixel(3, 3))")
    }

    @Test func polygonRendersGreen() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let slot = try b.append(.createBrushIndirect(style: 0, color: Self.color(0, 180, 0), hatch: 0))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.polygon([PointL(x: 48, y: 8), PointL(x: 8, y: 88), PointL(x: 88, y: 88)]))
        let r = try renderMetafile(try b.finish())
        #expect(r.countPixels { red, grn, blu in red < 120 && grn > 120 && blu < 120 } > 100,
                "expected a green polygon fill")
        #expect(r.anyPixel { red, grn, blu in red > 240 && grn > 240 && blu > 240 }, "expected white page around the polygon")
    }

    @Test func textRendersDark() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        try b.append(.setBkMode(1))                 // TRANSPARENT
        try b.append(.setTextColor(Self.color(0, 0, 0)))
        let slot = try b.append(.createFontIndirect(LogFont(
            height: -40, width: 0, escapement: 0, orientation: 0, weight: 400,
            italic: 0, underline: 0, strikeOut: 0, charSet: 0, outPrecision: 0,
            clipPrecision: 0, quality: 0, pitchAndFamily: 0, faceName: "Helvetica")))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.extTextOut(point: PointL(x: 6, y: 58), rectangle: nil, options: 0, string: "Hi", dx: nil))
        let r = try renderMetafile(try b.finish())
        let dark = r.countPixels { red, grn, blu in red < 90 && grn < 90 && blu < 90 }
        #expect(dark > 10, "expected dark text glyph pixels, got \(dark)")
    }

    @Test func stretchDIBRendersMagenta() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let dib = WMFEncodeTests.solidDIB(width: 4, height: 4, b: 0xFF, g: 0x00, r: 0xFF)   // BGR magenta
        try b.append(.stretchDIB(
            rop: 0x00CC_0020, colorUsage: 0,
            src: PointL(x: 0, y: 0), srcSize: SizeL(cx: 4, cy: 4),
            dest: PointL(x: 0, y: 0), destSize: SizeL(cx: 96, cy: 96), dib: dib))
        let r = try renderMetafile(try b.finish())
        #expect(near(r.pixel(48, 48), 255, 0, 255, tol: 40), "centre not magenta: \(r.pixel(48, 48))")
    }

    // MARK: - Embedded EMF

    /// A standalone EMF whose 96×96 drawing fills blue, built with E0a's builder.
    static func blueEMF() throws -> Data {
        let builder = EMFDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 95, bottom: 95),
            frame: RectL(left: 0, top: 0, right: 2540, bottom: 2540),
            device: SizeL(cx: 96, cy: 96), millimeters: SizeL(cx: 25, cy: 25))
        let brush = try builder.allocateObjectHandle()
        try builder.append(.selectObject(.stock(.nullPen)))
        try builder.append(.createBrushIndirect(
            CreateBrushPayload(ihBrush: brush, style: 0, color: ColorRef(red: 0, green: 0, blue: 220), hatch: 0)))
        try builder.append(.selectObject(.table(index: brush)))
        try builder.append(.rectangle(box: RectL(left: -5, top: -5, right: 100, bottom: 100)))
        return try builder.finish()
    }

    @Test func embeddedEMFReassemblesExactly() throws {
        let emf = try Self.blueEMF()
        let b = Self.newBuilder(embeddedEMF: emf)
        // Also append a RED GDI fill: if the records played, the centre would be red.
        try Self.setWindow(b)
        let slot = try b.append(.createBrushIndirect(style: 0, color: Self.color(255, 0, 0), hatch: 0))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.rectangle(RectL(left: 0, top: 0, right: 96, bottom: 96)))
        let wmf = try b.finish()

        // 1. The embedded EMF reassembles to the EXACT bytes.
        let file = try WMFFile.parse(wmf)
        let result = WMFEmbeddedEMF.reassemble(file)
        #expect(result == .reassembled(emf), "embedded EMF did not reassemble to the exact bytes")

        // 2. prepare plays the embedded EMF, and the render is blue (not the red records).
        let r = try renderMetafile(wmf)
        #expect(r.prepared.embeddedEMF == .played, "embedded EMF fate: \(r.prepared.embeddedEMF)")
        #expect(near(r.pixel(48, 48), 0, 0, 220), "centre not blue (embedded EMF): \(r.pixel(48, 48))")
        #expect(!r.anyPixel { red, grn, blu in red > 180 && grn < 100 && blu < 100 }, "the WMF red fill must not show")
    }

    // MARK: - WMZ

    @Test func builderWMZInflatesToTheWMF() throws {
        let b = Self.newBuilder()
        try Self.setWindow(b)
        let slot = try b.append(.createBrushIndirect(style: 0, color: Self.color(255, 0, 0), hatch: 0))
        try b.append(.selectObject(index: slot ?? 0))
        try b.append(.rectangle(RectL(left: 0, top: 0, right: 96, bottom: 96)))
        let wmf = try b.finish()
        let wmz = try b.finishCompressed()
        let opened = try OpenedMetafile.open(wmz)
        #expect(opened.wasDecompressed)
        #expect(Data(opened.data) == Data(wmf), "inflated WMZ differs from finish()")
    }
}
