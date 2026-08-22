import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - EMF+ fixture builders
//
// Hand-builds EMF files whose EMF+ stream carries drawing records, so the
// renderer takes the EMF+ playback path ([MS-EMFPLUS] §1.3.1). Each EMF+ record
// is Type(u16)/Flags(u16)/Size(u32)/DataSize(u32) then data; the stream is
// wrapped in one or more EMR_COMMENT_EMFPLUS records via `RenderFixture`.

private let plusVersion: UInt32 = 0xDBC0_1002

/// Little-endian byte bag (reuses RenderFixture's writer).
private func le(_ build: (inout RenderFixture.LE) -> Void) -> [UInt8] {
    var writer = RenderFixture.LE()
    build(&writer)
    return writer.bytes
}

/// One EMF+ record ([MS-EMFPLUS] §2.3): 12-byte header + data.
private func plusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8] = []) -> [UInt8] {
    le { writer in
        writer.u16(type)
        writer.u16(flags)
        writer.u32(UInt32(12 + data.count))
        writer.u32(UInt32(data.count))
        writer.raw(data)
    }
}

/// EmfPlusHeader (§2.3.3.3), dual by default.
private func plusHeader() -> [UInt8] {
    plusRecord(0x4001, 0x0001, le { $0.u32(plusVersion); $0.u32(0); $0.u32(96); $0.u32(96) })
}

/// An EmfPlusObject record (§2.3.5.1): Flags = ObjectType<<8 | ObjectID.
private func plusObject(id: UInt8, type: UInt8, payload: [UInt8]) -> [UInt8] {
    plusRecord(0x4008, (UInt16(type) << 8) | UInt16(id), payload)
}

/// EmfPlusBrush solid (§2.2.1.1/§2.2.2.43): Version, Type 0, SolidColor(ARGB).
private func solidBrushPayload(_ argb: UInt32) -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(0); $0.u32(argb) }
}

/// EmfPlusPen (§2.2.1.7): Version, Type 0, PenData(no optional blocks: flags 0,
/// unit 0, width), then a solid BrushObject.
private func penPayload(width: Float, argb: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(0)          // Version, Type
        writer.u32(0); writer.u32(0); writer.f32(width)  // PenDataFlags, PenUnit, PenWidth
        writer.u32(plusVersion); writer.u32(0); writer.u32(argb)   // BrushObject (solid)
    }
}

/// EmfPlusPath (§2.2.1.6) with absolute 32-bit points (Flags 0).
private func pathPayload(points: [(Float, Float)], types: [UInt8]) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion)
        writer.u32(UInt32(points.count))
        writer.u32(0)
        for point in points { writer.f32(point.0); writer.f32(point.1) }
        for type in types { writer.raw([type]) }
        let pad = (4 - (types.count % 4)) % 4
        writer.raw([UInt8](repeating: 0, count: pad))
    }
}

/// An ARGB DWORD (0xAARRGGBB) from straight channels.
private func argb(_ a: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
}

// Drawing records.

private func fillRectsDirect(_ color: UInt32, _ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x400A, 0x8000, le { writer in
        writer.u32(color); writer.u32(1)
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

private func fillRectsDirectI16(_ color: UInt32, _ rect: (Int16, Int16, Int16, Int16)) -> [UInt8] {
    plusRecord(0x400A, 0xC000, le { writer in
        writer.u32(color); writer.u32(1)
        writer.i16(rect.0); writer.i16(rect.1); writer.i16(rect.2); writer.i16(rect.3)
    })
}

/// EmfPlusLinearGradientBrushData (§2.2.2.24): a plain two-colour horizontal
/// gradient (BrushDataFlags 0 → no transform, no blend). `wrapMode` defaults to
/// 0x04 Clamp (§2.1.1.33) — the mode the fill reproduces exactly, so no
/// wrap-mode approximation note fires; pass a tiling value (0x00–0x03) to
/// exercise that note.
private func linearGradientBrushPayload(rect: (Float, Float, Float, Float), start: UInt32, end: UInt32, wrapMode: Int32 = 4) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(4)   // Version, Type 4 (linear gradient)
        writer.u32(0)                             // BrushDataFlags
        writer.i32(wrapMode)                      // WrapMode
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
        writer.u32(start); writer.u32(end)        // StartColor, EndColor
        writer.u32(0); writer.u32(0)              // Reserved1, Reserved2
    }
}

private func fillRectsBrush(_ brushId: UInt32, _ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x400A, 0x0000, le { writer in
        writer.u32(brushId); writer.u32(1)
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

private func fillPathDirect(_ color: UInt32, pathId: UInt8) -> [UInt8] {
    plusRecord(0x4014, 0x8000 | UInt16(pathId), le { $0.u32(color) })
}

private func drawLines(penId: UInt8, _ points: [(Float, Float)]) -> [UInt8] {
    plusRecord(0x400D, UInt16(penId), le { writer in
        writer.u32(UInt32(points.count))
        for point in points { writer.f32(point.0); writer.f32(point.1) }
    })
}

private func translateWorld(_ dx: Float, _ dy: Float) -> [UInt8] {
    plusRecord(0x402D, 0x0000, le { $0.f32(dx); $0.f32(dy) })
}

/// EmfPlusDrawCurve (§2.3.4.4): Tension, Offset, NumSegments, Count, PointData
/// (absolute f32 points; pen in the ObjectId low byte).
private func drawCurve(penId: UInt8, tension: Float, offset: UInt32, numSegments: UInt32, _ points: [(Float, Float)]) -> [UInt8] {
    plusRecord(0x4018, UInt16(penId), le { writer in
        writer.f32(tension)
        writer.u32(offset)
        writer.u32(numSegments)
        writer.u32(UInt32(points.count))
        for point in points { writer.f32(point.0); writer.f32(point.1) }
    })
}

private func save(_ index: UInt32) -> [UInt8] { plusRecord(0x4025, 0, le { $0.u32(index) }) }
private func restore(_ index: UInt32) -> [UInt8] { plusRecord(0x4026, 0, le { $0.u32(index) }) }

/// SetClipRect (§2.3.1.4) with CombineMode Intersect (CM = 1, bits 8-11).
private func setClipRectIntersect(_ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x4032, UInt16(1) << 8, le { writer in
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

private func getDC() -> [UInt8] { plusRecord(0x4004, 0) }

/// An EmfPlusSerializableObject (§2.3.5.2, 0x4038) — a record type outside the
/// P4 playback set, so the playback logs it unsupported and renders the rest.
private func serializableObject() -> [UInt8] {
    plusRecord(0x4038, 0, le { $0.u32(0) })
}

private extension RenderFixture {
    /// Appends an EMR_COMMENT_EMFPLUS carrying `stream` ([MS-EMF] §2.3.3.4).
    mutating func plusComment(_ stream: [UInt8]) {
        var payload = LE()
        payload.u32(UInt32(4 + stream.count))   // DataSize (identifier + stream)
        payload.u32(0x2B46_4D45)                // "EMF+"
        payload.raw(stream)
        append(type: 70, payload: payload.bytes)
    }
}

/// Builds a 100×100 EMF file whose single EMF+ comment carries `records`.
private func plusFile(_ records: [[UInt8]]) throws -> EMFFile {
    var fixture = RenderFixture()
    fixture.plusComment(plusHeader() + records.reduce([], +))
    return try fixture.parsed()
}

/// Renders a file and returns its raster + log.
private func renderPlus(_ file: EMFFile) throws -> (RasterizedImage, EMFRenderLog) {
    let rendered = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
    return (try #require(RasterizedImage(rendered.0)), rendered.1)
}

@Suite("EMF+ playback")
struct EMFPlusPlaybackTests {

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 200 && p.g < 60 && p.b < 60
    }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.b > 200 && p.r < 60 && p.g < 60
    }
    private static func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.g > 180 && p.r < 80 && p.b < 80
    }
    private static func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 230 && p.g > 230 && p.b > 230
    }
    private static func isDark(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r < 60 && p.g < 60 && p.b < 60
    }

    // MARK: - 1. Solid FillPath, direct-colour FillRects, DrawLines

    @Test("solid FillPath fills where expected and leaves the background elsewhere")
    func fillPathSolid() throws {
        // A black square path (10,10)-(40,40): start + three lines, last closed.
        let path = plusObject(
            id: 1, type: 3,
            payload: pathPayload(
                points: [(10, 10), (40, 10), (40, 40), (10, 40)],
                types: [0x00, 0x01, 0x01, 0x81]
            )
        )
        let file = try plusFile([path, fillPathDirect(argb(255, 0, 0, 0), pathId: 1)])
        let (image, log) = try renderPlus(file)

        #expect(Self.isDark(image[25, 25]), "path interior filled")
        #expect(Self.isWhite(image[60, 60]), "outside the path stays background")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    @Test("direct-colour FillRects fills an exact colour")
    func fillRectsDirectColor() throws {
        let file = try plusFile([fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20))])
        let (image, log) = try renderPlus(file)

        let pixel = image[20, 20]
        #expect(pixel.r == 255 && pixel.g == 0 && pixel.b == 0, "expected exact red, got \(pixel)")
        #expect(Self.isWhite(image[60, 60]), "outside the rect stays background")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    @Test("DrawLines strokes with the pen's colour and width")
    func drawLinesPen() throws {
        // A blue width-4 pen strokes a horizontal line at y=50.
        let pen = plusObject(id: 2, type: 2, payload: penPayload(width: 4, argb: argb(255, 0, 0, 255)))
        let file = try plusFile([pen, drawLines(penId: 2, [(10, 50), (90, 50)])])
        let (image, log) = try renderPlus(file)

        #expect(image.containsBluePixel(in: (x: 45, y: 48, width: 10, height: 5)), "expected blue ink on the line")
        #expect(Self.isWhite(image[50, 20]), "well off the line stays background")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    @Test("a linear-gradient FillRects blends from its start colour to its end colour")
    func fillRectsLinearGradient() throws {
        // Red→blue horizontal gradient across (10,40)-(90,60).
        let brush = plusObject(
            id: 3, type: 1,
            payload: linearGradientBrushPayload(
                rect: (10, 40, 80, 20),
                start: argb(255, 255, 0, 0),
                end: argb(255, 0, 0, 255)
            )
        )
        let file = try plusFile([brush, fillRectsBrush(3, (10, 40, 80, 20))])
        let (image, log) = try renderPlus(file)

        let left = image[20, 50]
        let right = image[80, 50]
        #expect(Int(left.r) > Int(left.b) + 40, "left of the gradient is redder, got \(left)")
        #expect(Int(right.b) > Int(right.r) + 40, "right of the gradient is bluer, got \(right)")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    // MARK: - 2. World transform

    @Test("TranslateWorldTransform shifts a later fill")
    func translateShiftsFill() throws {
        let file = try plusFile([
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)),   // at (10..30, 10..30)
            translateWorld(40, 0),
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)),   // now at (50..70, 10..30)
        ])
        let (image, _) = try renderPlus(file)

        #expect(Self.isRed(image[20, 20]), "first (untranslated) fill present")
        #expect(Self.isRed(image[60, 20]), "second fill shifted +40 in x")
        #expect(Self.isWhite(image[40, 20]), "the gap between the two fills stays background")
    }

    // MARK: - 3. Save / Restore

    @Test("Save/Restore isolates the world transform")
    func saveRestoreIsolatesTransform() throws {
        let file = try plusFile([
            save(1),
            translateWorld(40, 0),
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)),   // translated → (50..70)
            restore(1),
            fillRectsDirect(argb(255, 0, 0, 255), (10, 10, 20, 20)),   // reverted → (10..30)
        ])
        let (image, _) = try renderPlus(file)

        #expect(Self.isRed(image[60, 20]), "translated red fill present")
        #expect(Self.isBlue(image[20, 20]), "post-restore fill is back at the original position")
    }

    // MARK: - 4. Clip

    @Test("SetClipRect intersect confines a later fill")
    func clipRectIntersect() throws {
        let file = try plusFile([
            setClipRectIntersect((10, 10, 30, 30)),                     // clip to (10..40, 10..40)
            fillRectsDirect(argb(255, 255, 0, 0), (0, 0, 100, 100)),    // whole canvas, clipped
        ])
        let (image, log) = try renderPlus(file)

        #expect(Self.isRed(image[20, 20]), "ink inside the clip")
        #expect(Self.isWhite(image[60, 60]), "no ink outside the clip")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    // MARK: - 5. Object redefinition (position-sensitive binding)

    @Test("an object id redefined mid-stream binds at its stream position")
    func objectRedefinition() throws {
        let file = try plusFile([
            plusObject(id: 0, type: 1, payload: solidBrushPayload(argb(255, 255, 0, 0))),   // id 0 = red
            fillRectsBrush(0, (10, 10, 20, 20)),
            plusObject(id: 0, type: 1, payload: solidBrushPayload(argb(255, 0, 0, 255))),   // id 0 = blue
            fillRectsBrush(0, (60, 10, 20, 20)),
        ])
        let (image, _) = try renderPlus(file)

        #expect(Self.isRed(image[20, 20]), "first fill used the red binding")
        #expect(Self.isBlue(image[70, 20]), "second fill used the redefined blue binding")
    }

    // MARK: - 6. GetDC arbitration (the decisive test)

    @Test("a GetDC window plays interleaved GDI; a following EMF+ record closes it")
    func getDCArbitration() throws {
        var fixture = RenderFixture()
        fixture.plusComment(plusHeader())
        fixture.plusComment(fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)))   // EMF+ red
        fixture.plusComment(getDC())                                                    // open window
        // Windowed GDI: a green rectangle at (40,40)-(60,60).
        fixture.createSolidBrush(index: 1, r: 0, g: 200, b: 0)
        fixture.selectObject(1)
        fixture.selectObject(0x8000_0008)   // NULL_PEN
        fixture.rectangle(40, 40, 60, 60)
        fixture.plusComment(fillRectsDirect(argb(255, 0, 0, 255), (10, 70, 20, 20)))   // EMF+ blue → closes window
        // NOT windowed: this GDI rectangle must be skipped.
        fixture.rectangle(70, 40, 90, 60)

        let (image, _) = try renderPlus(try fixture.parsed())

        #expect(Self.isRed(image[20, 20]), "EMF+ red rendered")
        #expect(Self.isBlue(image[20, 80]), "EMF+ blue rendered")
        #expect(Self.isGreen(image[50, 50]), "the GetDC-windowed GDI rectangle rendered")
        #expect(Self.isWhite(image[80, 50]), "the non-windowed GDI rectangle was skipped")
    }

    // MARK: - 7. Compressed (i16) rect variant

    @Test("a C-flag (16-bit) FillRects fills the same region as the float form")
    func fillRectsI16() throws {
        let file = try plusFile([fillRectsDirectI16(argb(255, 255, 0, 0), (10, 10, 20, 20))])
        let (image, log) = try renderPlus(file)

        #expect(Self.isRed(image[20, 20]), "16-bit rect filled")
        #expect(Self.isWhite(image[60, 60]), "outside stays background")
        #expect(log.isClean, "unexpected log: \(log.entries)")
    }

    // MARK: - 8. Unsupported record still lets the rest render

    @Test("an unsupported EMF+ record is logged and the rest still renders")
    func unsupportedRecordLogged() throws {
        let file = try plusFile([
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)),
            serializableObject(),
        ])
        let (image, log) = try renderPlus(file)

        #expect(Self.isRed(image[20, 20]), "the fill before the unsupported record still drew")
        #expect(
            log.entries.contains(.emfPlusUnsupportedRecord(type: 0x4038, count: 1)),
            "expected an unsupported-record note, got \(log.entries)"
        )
    }

    // MARK: - 9. Deferred approximations now logged (P3-C)

    @Test("a tiling-wrap-mode linear gradient still fills but logs a wrap-mode approximation")
    func linearGradientTileWrapModeLogged() throws {
        // WrapModeTile (0) tiles; the fill clamps, so the approximation is noted.
        let brush = plusObject(
            id: 1, type: 1,
            payload: linearGradientBrushPayload(
                rect: (10, 40, 80, 20),
                start: argb(255, 255, 0, 0), end: argb(255, 0, 0, 255),
                wrapMode: 0
            )
        )
        let file = try plusFile([brush, fillRectsBrush(1, (10, 40, 80, 20))])
        let (image, log) = try renderPlus(file)

        #expect(!Self.isWhite(image[20, 50]), "the gradient still filled")
        #expect(
            log.entries.contains(.emfPlusApproximated(feature: .linearGradientWrapMode, count: 1)),
            "expected a wrap-mode approximation note, got \(log.entries)"
        )
    }

    @Test("a clamp-wrap-mode linear gradient logs no wrap-mode note")
    func linearGradientClampWrapModeClean() throws {
        // WrapModeClamp (4, the helper default) is reproduced exactly.
        let brush = plusObject(
            id: 1, type: 1,
            payload: linearGradientBrushPayload(
                rect: (10, 40, 80, 20),
                start: argb(255, 255, 0, 0), end: argb(255, 0, 0, 255)
            )
        )
        let file = try plusFile([brush, fillRectsBrush(1, (10, 40, 80, 20))])
        let (_, log) = try renderPlus(file)

        #expect(log.isClean, "unexpected log for a clamped gradient: \(log.entries)")
    }

    @Test("a DrawCurve with a partial Offset/NumSegments range is logged as approximated")
    func drawCurvePartialRangeLogged() throws {
        // 5 points → 4 segments; request only 2 segments starting at offset 1.
        let pen = plusObject(id: 1, type: 2, payload: penPayload(width: 2, argb: argb(255, 0, 0, 0)))
        let file = try plusFile([
            pen,
            drawCurve(penId: 1, tension: 0.5, offset: 1, numSegments: 2,
                      [(10, 50), (30, 20), (50, 60), (70, 20), (90, 50)]),
        ])
        let (_, log) = try renderPlus(file)

        #expect(
            log.entries.contains(.emfPlusApproximated(feature: .curveSegmentRange, count: 1)),
            "expected a curve segment-range note, got \(log.entries)"
        )
    }

    @Test("a DrawCurve covering the whole spline logs no segment-range note")
    func drawCurveFullRangeClean() throws {
        // offset 0, numSegments 4 == points − 1: the whole open spline.
        let pen = plusObject(id: 1, type: 2, payload: penPayload(width: 2, argb: argb(255, 0, 0, 0)))
        let file = try plusFile([
            pen,
            drawCurve(penId: 1, tension: 0.5, offset: 0, numSegments: 4,
                      [(10, 50), (30, 20), (50, 60), (70, 20), (90, 50)]),
        ])
        let (_, log) = try renderPlus(file)

        #expect(log.isClean, "unexpected log for a full-range curve: \(log.entries)")
    }
}

// MARK: - EMF+ image record fixtures ([MS-EMFPLUS] §2.2.2.2, §2.3.4.8/9)

/// EmfPlusImage bitmap object (§2.2.2.2): a 2×2 32bpp-ARGB pixel bitmap —
/// red (top-left), green (top-right), blue (bottom-left), white (bottom-right).
private func imageObjectPayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion)   // Version
        writer.u32(1)             // Type = ImageDataTypeBitmap
        writer.i32(2)             // Width
        writer.i32(2)             // Height
        writer.i32(8)             // Stride (2 px × 4 bytes)
        writer.u32(0x0026_200A)   // PixelFormat = 32bpp ARGB
        writer.u32(0)             // Type = BitmapDataTypePixel
        writer.raw([0x00, 0x00, 0xFF, 0xFF])   // (0,0) red    B,G,R,A
        writer.raw([0x00, 0xFF, 0x00, 0xFF])   // (1,0) green
        writer.raw([0xFF, 0x00, 0x00, 0xFF])   // (0,1) blue
        writer.raw([0xFF, 0xFF, 0xFF, 0xFF])   // (1,1) white
    }
}

/// A solid-colour 24bpp-RGB pixel bitmap image object (§2.2.2.2) of `side × side`
/// source pixels — used to exercise the destination decode budget (audit H1 /
/// A2). Bytes are B,G,R per pixel, rows padded to a 4-aligned stride.
private func largeSolid24ImageObjectPayload(side: Int, b: UInt8, g: UInt8, r: UInt8) -> [UInt8] {
    let stride = ((side * 24 + 31) / 32) * 4
    var pixels = [UInt8](repeating: 0, count: stride * side)
    for row in 0 ..< side {
        var i = row * stride
        for _ in 0 ..< side { pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; i += 3 }
    }
    return le { writer in
        writer.u32(plusVersion)      // Version
        writer.u32(1)                // Type = ImageDataTypeBitmap
        writer.i32(Int32(side))      // Width
        writer.i32(Int32(side))      // Height
        writer.i32(Int32(stride))    // Stride
        writer.u32(0x0002_1808)      // PixelFormat = 24bpp RGB
        writer.u32(0)                // BitmapDataType = Pixel
        writer.raw(pixels)
    }
}

/// EmfPlusImage metafile object (§2.2.2.27): a metafile-content image.
private func metafileImageObjectPayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion)   // Version
        writer.u32(2)             // Type = ImageDataTypeMetafile
        writer.u32(1)             // MetafileType
        writer.u32(4)             // MetafileDataSize
        writer.raw([0, 0, 0, 0])  // (dummy embedded metafile bytes)
    }
}

/// EmfPlusImage bitmap object with an unsupported PixelFormat (32bpp PARGB).
private func pargbImageObjectPayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(1)   // Version, ImageDataTypeBitmap
        writer.i32(2); writer.i32(2); writer.i32(8)
        writer.u32(0x000E_200B)   // PixelFormat = 32bpp PARGB (unsupported)
        writer.u32(0)             // BitmapDataTypePixel
        writer.raw([UInt8](repeating: 0, count: 16))
    }
}

/// EmfPlusImageAttributes object (§2.2.1.5): Version, Reserved1, WrapMode,
/// ClampColor, ObjectClamp, Reserved2.
private func imageAttributesPayload(wrapMode: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion)   // Version
        writer.u32(0)             // Reserved1
        writer.u32(wrapMode)      // WrapMode
        writer.u32(0)             // ClampColor
        writer.u32(0)             // ObjectClamp
        writer.u32(0)             // Reserved2
    }
}

/// EmfPlusDrawImage (§2.3.4.8), C flag clear (EmfPlusRectF dest).
private func drawImageRecord(
    imageId: UInt8,
    src: (Float, Float, Float, Float),
    dest: (Float, Float, Float, Float),
    attrId: UInt32 = 0,
    srcUnit: Int32 = 2
) -> [UInt8] {
    plusRecord(0x401A, UInt16(imageId), le { writer in
        writer.u32(attrId)
        writer.i32(srcUnit)
        writer.f32(src.0); writer.f32(src.1); writer.f32(src.2); writer.f32(src.3)
        writer.f32(dest.0); writer.f32(dest.1); writer.f32(dest.2); writer.f32(dest.3)
    })
}

/// EmfPlusDrawImagePoints (§2.3.4.9), C clear; `extraFlags` can set the P bit.
private func drawImagePointsRecord(
    imageId: UInt8,
    extraFlags: UInt16 = 0,
    src: (Float, Float, Float, Float),
    points: [(Float, Float)]
) -> [UInt8] {
    plusRecord(0x401B, UInt16(imageId) | extraFlags, le { writer in
        writer.u32(0)             // ImageAttributesID
        writer.i32(2)             // SrcUnit = UnitTypePixel
        writer.f32(src.0); writer.f32(src.1); writer.f32(src.2); writer.f32(src.3)
        writer.u32(UInt32(points.count))
        for point in points { writer.f32(point.0); writer.f32(point.1) }
    })
}

@Suite("EMF+ image playback")
struct EMFPlusImagePlaybackTests {

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 70 && p.b < 70 }
    private func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 130 && p.r < 90 && p.b < 90 }
    private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 70 && p.g < 70 }
    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 }

    private func hasApprox(_ log: EMFRenderLog, _ feature: EMFPlusApproximation) -> Bool {
        log.entries.contains { if case .emfPlusApproximated(let f, _) = $0 { return f == feature }; return false }
    }
    private func hasUnsupported(_ log: EMFRenderLog, type: UInt16) -> Bool {
        log.entries.contains { if case .emfPlusUnsupportedRecord(let t, _) = $0 { return t == type }; return false }
    }

    @Test("DrawImage scales the bitmap into the dest rect, quadrants placed, clean log")
    func drawImagePlacesQuadrants() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(log.isClean, "unexpected log: \(log.entries)")
        #expect(isRed(pixels[18, 18]), "top-left quadrant, got \(pixels[18, 18])")
        #expect(isGreen(pixels[42, 18]), "top-right quadrant, got \(pixels[42, 18])")
        #expect(isBlue(pixels[18, 42]), "bottom-left quadrant, got \(pixels[18, 42])")
        #expect(isWhite(pixels[42, 42]), "bottom-right quadrant, got \(pixels[42, 42])")
    }

    @Test("DrawImage SrcRect crops to a sub-image (the green pixel fills the dest)")
    func drawImageCropSelectsSubImage() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            // Src = the single top-right (green) pixel → the whole dest is green.
            drawImageRecord(imageId: 1, src: (1, 0, 1, 1), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(log.isClean, "unexpected log: \(log.entries)")
        #expect(isGreen(pixels[18, 18]), "cropped region should be all green, got \(pixels[18, 18])")
        #expect(isGreen(pixels[42, 42]), "cropped region should be all green, got \(pixels[42, 42])")
        #expect(!isRed(pixels[18, 18]), "crop should have excluded the red pixel")
    }

    @Test("DrawImage naming an unbound image object is a clean no-op")
    func drawImageUnboundIsNoOp() throws {
        let file = try plusFile([
            drawImageRecord(imageId: 7, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(log.isClean, "an unbound image should skip silently: \(log.entries)")
        #expect(isWhite(pixels[30, 30]), "nothing should have drawn, got \(pixels[30, 30])")
    }

    @Test("DrawImagePoints maps the image into a parallelogram")
    func drawImagePointsMapsParallelogram() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            // UL(50,10) UR(90,20) LL(60,60): a sheared parallelogram.
            drawImagePointsRecord(imageId: 1, src: (0, 0, 2, 2), points: [(50, 10), (90, 20), (60, 60)]),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(log.isClean, "unexpected log: \(log.entries)")
        // The red quadrant sits near the upper-left corner of the parallelogram.
        #expect(pixels.contains(in: (x: 52, y: 14, width: 12, height: 12)) { isRed($0) },
                "no red near the parallelogram's upper-left corner")
    }

    @Test("DrawImagePoints with the P (relative) flag logs an unsupported record")
    func drawImagePointsRelativeLogsUnsupported() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            drawImagePointsRecord(imageId: 1, extraFlags: 0x0800, src: (0, 0, 2, 2), points: [(50, 10), (90, 20), (60, 60)]),
        ])
        let (_, log) = try renderPlus(file)
        #expect(hasUnsupported(log, type: 0x401B), "relative DrawImagePoints should log unsupported: \(log.entries)")
    }

    @Test("DrawImage with a non-pixel SrcUnit draws and logs the approximation")
    func drawImageNonPixelSrcUnitLogs() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40), srcUnit: 0),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(hasApprox(log, .imageSrcUnit), "non-pixel SrcUnit should log .imageSrcUnit: \(log.entries)")
        #expect(isRed(pixels[18, 18]), "the image should still have drawn, got \(pixels[18, 18])")
    }

    @Test("DrawImage of a metafile image logs .imageMetafile and draws nothing")
    func drawImageMetafileLogsSkip() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: metafileImageObjectPayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(hasApprox(log, .imageMetafile), "a metafile image should log .imageMetafile: \(log.entries)")
        #expect(isWhite(pixels[30, 30]), "a metafile image should draw nothing, got \(pixels[30, 30])")
    }

    @Test("DrawImage of an unsupported pixel format logs the raw format value")
    func drawImageUnsupportedFormatLogs() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: pargbImageObjectPayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (_, log) = try renderPlus(file)
        #expect(hasApprox(log, .imageBitmapPixelFormat(0x000E_200B)),
                "an unsupported format should log its raw value: \(log.entries)")
    }

    @Test("DrawImage referencing a tiling ImageAttributes logs .imageAttributes")
    func drawImageTilingAttributesLogs() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            plusObject(id: 3, type: 8, payload: imageAttributesPayload(wrapMode: 0)),   // WrapModeTile
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40), attrId: 3),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(hasApprox(log, .imageAttributes), "a tiling wrap should log .imageAttributes: \(log.entries)")
        #expect(isRed(pixels[18, 18]), "the image should still have drawn, got \(pixels[18, 18])")
    }

    // MARK: - Audit H1 / A1: one decode per object, note per draw

    @Test("200 DrawImage records over one image object still render correctly (cached decode)")
    func repeatedDrawImageRendersCorrectly() throws {
        var records: [[UInt8]] = [plusObject(id: 1, type: 5, payload: imageObjectPayload())]
        for _ in 0 ..< 200 {
            records.append(drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)))
        }
        let (pixels, log) = try renderPlus(try plusFile(records))
        #expect(log.isClean, "unexpected log: \(log.entries)")
        #expect(isRed(pixels[18, 18]), "top-left quadrant, got \(pixels[18, 18])")
        #expect(isGreen(pixels[42, 18]), "top-right quadrant, got \(pixels[42, 18])")
        #expect(isBlue(pixels[18, 42]), "bottom-left quadrant, got \(pixels[18, 42])")
        #expect(isWhite(pixels[42, 42]), "bottom-right quadrant, got \(pixels[42, 42])")
    }

    @Test("200 draws of an undecodable image note the skip ONCE PER DRAW (decode runs once)")
    func repeatedUndecodableImageNotesPerDraw() throws {
        var records: [[UInt8]] = [plusObject(id: 1, type: 5, payload: pargbImageObjectPayload())]
        for _ in 0 ..< 200 {
            records.append(drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)))
        }
        let (_, log) = try renderPlus(try plusFile(records))
        // The decode is cached (see DecodedImageCacheTests), but the skip note
        // still fires per draw so the coalesced count stays meaningful.
        #expect(
            log.entries.contains(.emfPlusApproximated(feature: .imageBitmapPixelFormat(0x000E_200B), count: 200)),
            "the skip note must fire once per draw (count 200), got \(log.entries)"
        )
    }

    // MARK: - Audit H1 / A2: pixel-path destination decode budget

    @Test("a large pixel bitmap drawn into a small dest decodes downsampled and still renders")
    func largePixelImageDownsamples() throws {
        // 2100×2100 = 4.41 Mpx > the 4 Mpx floor → decoding for a ~40px dest
        // falls below native (audit H1 / A2). The sampling MAGNITUDE is covered
        // by EMFPlusImageDecoderTests.decodePixelsDownsamples; here the point is
        // the footprint→budget→note→render wiring. Solid blue so the probe is blue.
        let img = largeSolid24ImageObjectPayload(side: 2100, b: 255, g: 0, r: 0)
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: img),
            drawImageRecord(imageId: 1, src: (0, 0, 2100, 2100), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(hasApprox(log, .imageDownsampled), "expected .imageDownsampled, got \(log.entries)")
        #expect(isBlue(pixels[30, 30]), "the downsampled image still rendered, got \(pixels[30, 30])")
    }
}
