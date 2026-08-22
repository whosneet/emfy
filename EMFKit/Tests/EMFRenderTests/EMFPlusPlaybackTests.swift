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

/// One CONTINUED EmfPlusObject chunk ([MS-EMFPLUS] §2.3.5.1): C bit set in the
/// flags, and the data is TotalObjectSize (u32) followed by `partial` object
/// bytes. The playback ObjectTable accumulates `DataSize − 4` per chunk until it
/// reaches TotalObjectSize, then binds `prefix(total)`.
private func continuedObjectChunk(id: UInt8, type: UInt8, total: UInt32, partial: [UInt8]) -> [UInt8] {
    let flags = UInt16(0x8000) | (UInt16(type) << 8) | UInt16(id)
    return plusRecord(0x4008, flags, le { $0.u32(total) } + partial)
}

/// A pen carrying a preset PenDataLineStyle (PenDataFlags 0x20; the style Int32
/// follows the fixed PenData fields, [MS-EMFPLUS] §2.2.2.33) — for the M4 dash tests.
private func penPayloadLineStyle(width: Float, argb: UInt32, lineStyle: Int32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(0)              // Version, Type
        writer.u32(0x20); writer.u32(0); writer.f32(width)  // PenDataFlags=LineStyle, PenUnit, PenWidth
        writer.i32(lineStyle)                               // OptionalData: PenDataLineStyle
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

/// A single FillRects record carrying TWO direct-colour rects — for the M6
/// winding (union) test.
private func fillRectsDirectTwo(_ color: UInt32, _ r1: (Float, Float, Float, Float), _ r2: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x400A, 0x8000, le { writer in
        writer.u32(color); writer.u32(2)
        writer.f32(r1.0); writer.f32(r1.1); writer.f32(r1.2); writer.f32(r1.3)
        writer.f32(r2.0); writer.f32(r2.1); writer.f32(r2.2); writer.f32(r2.3)
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

/// A linear gradient carrying BOTH blend-factor arrays (BlendFactorsV | H).
/// Decode order is vertical THEN horizontal (§2.2.2.25). The vertical array is
/// REVERSED (factors 1→0) and the horizontal NORMAL (0→1), so the drawn ramp
/// reveals which array the paint uses (audit M13).
private func linearGradientBothBlendPayload(rect: (Float, Float, Float, Float), start: UInt32, end: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(4)    // Version, Type 4 (linear gradient)
        writer.u32(0x18)                          // BrushDataFlags = BlendFactorsV | BlendFactorsH
        writer.i32(4)                             // WrapMode Clamp
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
        writer.u32(start); writer.u32(end)        // StartColor, EndColor
        writer.u32(0); writer.u32(0)              // Reserved1, Reserved2
        writer.u32(2); writer.f32(0); writer.f32(1); writer.f32(1); writer.f32(0)   // Vertical:  reversed (1→0)
        writer.u32(2); writer.f32(0); writer.f32(1); writer.f32(0); writer.f32(1)   // Horizontal: normal (0→1)
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

/// DrawBeziers (§2.3.4.3): float points, C flag clear. Count then the points.
private func drawBeziers(penId: UInt8, _ points: [(Float, Float)]) -> [UInt8] {
    plusRecord(0x4019, UInt16(penId), le { writer in
        writer.u32(UInt32(points.count))
        for point in points { writer.f32(point.0); writer.f32(point.1) }
    })
}

private func translateWorld(_ dx: Float, _ dy: Float) -> [UInt8] {
    plusRecord(0x402D, 0x0000, le { $0.f32(dx); $0.f32(dy) })
}

/// RotateWorldTransform (§2.3.9.6): angle in degrees, pre-multiply.
private func rotateWorld(_ degrees: Float) -> [UInt8] {
    plusRecord(0x402F, 0x0000, le { $0.f32(degrees) })
}

/// SetClipRegion (§2.3.1.6): ObjectID in the low Flags byte, CombineMode in
/// bits 8–11 (0 = Replace by default).
private func setClipRegion(regionId: UInt8, mode: UInt16 = 0) -> [UInt8] {
    plusRecord(0x4034, (mode << 8) | UInt16(regionId))
}

/// An EmfPlusRegion object (§2.2.1.8) whose only node is RegionNodeDataTypeEmpty
/// (0x10000002) — an empty region (clips to nothing).
private func emptyRegionPayload() -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(1); $0.u32(0x1000_0002) }
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

    @Test("FillRects fills the UNION of overlapping rects in one record (winding, M6)")
    func fillRectsUnionOverlap() throws {
        // r1 (10,10)-(40,40), r2 (30,30)-(60,60) → overlap (30,30)-(40,40). Even-odd
        // would leave the overlap an unfilled hole; winding fills the union.
        let file = try plusFile([fillRectsDirectTwo(argb(255, 255, 0, 0), (10, 10, 30, 30), (30, 30, 30, 30))])
        let (image, log) = try renderPlus(file)
        #expect(Self.isRed(image[35, 35]), "the overlap center must be FILLED (winding), got \(image[35, 35])")
        #expect(Self.isRed(image[15, 15]), "r1 non-overlap filled, got \(image[15, 15])")
        #expect(Self.isRed(image[55, 55]), "r2 non-overlap filled, got \(image[55, 55])")
        #expect(Self.isWhite(image[80, 80]), "outside stays background, got \(image[80, 80])")
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

    @Test("with both blend arrays the HORIZONTAL ramp drives the fill (M13)")
    func dualBlendArraysPickHorizontal() throws {
        // Vertical array is reversed (blue→red), horizontal normal (red→blue). The
        // horizontal must win, so the LEFT of the axis is red, the right blue.
        let brush = plusObject(
            id: 3, type: 1,
            payload: linearGradientBothBlendPayload(
                rect: (10, 40, 80, 20), start: argb(255, 255, 0, 0), end: argb(255, 0, 0, 255)))
        let file = try plusFile([brush, fillRectsBrush(3, (10, 40, 80, 20))])
        let (image, _) = try renderPlus(file)
        let left = image[20, 50], right = image[80, 50]
        #expect(Int(left.r) > Int(left.b) + 40, "left should be red (horizontal ramp won), got \(left)")
        #expect(Int(right.b) > Int(right.r) + 40, "right should be blue (horizontal ramp won), got \(right)")
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

    // MARK: - Rotated clip exactness (M9) + empty-clip fix (L5) — audit G1b

    @Test("a rotated SetClipRect clips to the exact rotated rect, not its bounding box")
    func rotatedClipRectIsExact() throws {
        let file = try plusFile([
            translateWorld(50, 50),
            rotateWorld(45),
            setClipRectIntersect((-20, -20, 40, 40)),                          // 40×40 → rotated diamond at (50,50)
            fillRectsDirect(argb(255, 255, 0, 0), (-100, -100, 300, 300)),     // covers the canvas, clipped
        ])
        let (image, _) = try renderPlus(file)
        #expect(Self.isRed(image[50, 50]), "the diamond centre should be filled, got \(image[50, 50])")
        // (75,75) is inside the axis-aligned bbox but OUTSIDE the rotated diamond —
        // the old bbox clip leaked here; the exact quad clip must block it.
        #expect(Self.isWhite(image[75, 75]), "a bbox corner outside the rotated rect must be clipped, got \(image[75, 75])")
    }

    @Test("SetClipRegion replace-with-empty blocks all subsequent drawing (L5)")
    func emptyClipRegionBlocksDrawing() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 4, payload: emptyRegionPayload()),   // type 4 = region, empty node
            setClipRegion(regionId: 1),                                   // Replace clip with the empty region
            fillRectsDirect(argb(255, 255, 0, 0), (0, 0, 100, 100)),      // whole canvas
        ])
        let (image, _) = try renderPlus(file)
        #expect(Self.isWhite(image[20, 20]) && Self.isWhite(image[50, 50]) && Self.isWhite(image[80, 80]),
                "an empty clip region must block ALL drawing, got \(image[50, 50])")
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

    // MARK: - Path replay honesty ([MS-EMFPLUS] §2.2.1.6 / §2.2.2.31, audit M14)

    @Test("a FillPath whose last figure is a dangling bezier triple notes undecodable but still draws the completed part")
    func fillPathDanglingBezierNoted() throws {
        // A square (start + 3 lines) then a bezier that begins with only two of
        // its three required points — the triple is dropped, the square remains.
        let path = plusObject(
            id: 1, type: 3,
            payload: pathPayload(
                points: [(10, 10), (40, 10), (40, 40), (10, 40), (50, 50), (60, 60)],
                types: [0x00, 0x01, 0x01, 0x01, 0x03, 0x03]
            )
        )
        let file = try plusFile([path, fillPathDirect(argb(255, 0, 0, 0), pathId: 1)])
        let (image, log) = try renderPlus(file)

        #expect(Self.isDark(image[25, 25]), "the completed square still fills, got \(image[25, 25])")
        #expect(Self.isWhite(image[70, 20]), "outside the square stays background, got \(image[70, 20])")
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x4014, count: 1)),
                "a dangling bezier triple should note recordUndecodable(0x4014): \(log.entries)")
    }

    @Test("a FillPath with an unknown point kind notes undecodable but still draws the preceding figure")
    func fillPathUnknownKindNoted() throws {
        // start + 3 lines (a square) then a point whose kind nibble (0x02) is not
        // start/line/bezier — the walk stops there.
        let path = plusObject(
            id: 1, type: 3,
            payload: pathPayload(
                points: [(10, 10), (40, 10), (40, 40), (10, 40), (99, 99)],
                types: [0x00, 0x01, 0x01, 0x01, 0x02]
            )
        )
        let file = try plusFile([path, fillPathDirect(argb(255, 0, 0, 0), pathId: 1)])
        let (image, log) = try renderPlus(file)

        #expect(Self.isDark(image[25, 25]), "the figure before the unknown kind still fills, got \(image[25, 25])")
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x4014, count: 1)),
                "an unknown point kind should note recordUndecodable(0x4014): \(log.entries)")
    }

    @Test("a FillPath carrying per-segment DashMode flags renders solid and notes pathDashSegment (M14)")
    func fillPathDashModeNoted() throws {
        // A well-formed closed square where one line point carries the DashMode
        // flag (raw bit 4, i.e. the flags nibble's 0x01 bit → raw 0x11).
        let path = plusObject(
            id: 1, type: 3,
            payload: pathPayload(
                points: [(10, 10), (40, 10), (40, 40), (10, 40)],
                types: [0x00, 0x11, 0x01, 0x81]
            )
        )
        let file = try plusFile([path, fillPathDirect(argb(255, 0, 0, 0), pathId: 1)])
        let (image, log) = try renderPlus(file)

        #expect(Self.isDark(image[25, 25]), "the dashed path still fills solid, got \(image[25, 25])")
        #expect(Self.isWhite(image[60, 60]), "outside the path stays background, got \(image[60, 60])")
        #expect(log.entries.contains(.emfPlusApproximated(feature: .pathDashSegment, count: 1)),
                "per-segment DashMode should note pathDashSegment: \(log.entries)")
        #expect(!log.entries.contains(where: { if case .emfPlusRecordUndecodable = $0 { return true }; return false }),
                "a well-formed dashed path must NOT be undecodable: \(log.entries)")
    }

    @Test("a DrawBeziers with a trailing partial triple strokes the complete curve and notes undecodable")
    func drawBeziersDanglingRemainderNoted() throws {
        // 5 points: start + one full control/control/end triple + a leftover
        // point that cannot form a second curve.
        let pen = plusObject(id: 1, type: 2, payload: penPayload(width: 3, argb: argb(255, 0, 0, 0)))
        let file = try plusFile([
            pen,
            drawBeziers(penId: 1, [(10, 50), (30, 10), (70, 90), (90, 50), (95, 55)]),
        ])
        let (image, log) = try renderPlus(file)

        var drewInk = false
        for x in stride(from: 0, to: 100, by: 2) where !drewInk {
            for y in stride(from: 0, to: 100, by: 2) where Self.isDark(image[x, y]) { drewInk = true; break }
        }
        #expect(drewInk, "the complete first bezier curve should stroke some ink")
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x4019, count: 1)),
                "a leftover bezier point should note recordUndecodable(0x4019): \(log.entries)")
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

/// A 2×2 32bpp-ARGB image whose LEFT column is red and RIGHT column is blue —
/// for SrcRect crop tests where the surviving column must be identifiable.
private func twoColumnImagePayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(1)        // Version, ImageDataTypeBitmap
        writer.i32(2); writer.i32(2); writer.i32(8)   // Width, Height, Stride
        writer.u32(0x0026_200A); writer.u32(0)        // 32bpp ARGB, BitmapDataTypePixel
        writer.raw([0, 0, 0xFF, 0xFF, 0xFF, 0, 0, 0xFF])   // row 0: red, blue (B,G,R,A)
        writer.raw([0, 0, 0xFF, 0xFF, 0xFF, 0, 0, 0xFF])   // row 1: red, blue
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

// MARK: - Honesty channel (audit M7 / C2)

@Suite("EMF+ honesty channel")
struct EMFPlusHonestyTests {

    @Test("a drawing record with a truncated body notes .emfPlusRecordUndecodable with its type")
    func truncatedDrawingBodyNoted() throws {
        // FillRects (S flag) with only the BrushId present — the Count read fails.
        let file = try plusFile([plusRecord(0x400A, 0x8000, le { $0.u32(argb(255, 0, 0, 0)) })])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x400A, count: 1)),
                "a truncated FillRects body should note recordUndecodable: \(log.entries)")
    }

    @Test("a FillRects referencing an unbound brush slot notes .missingReference")
    func fillRectsUnboundBrushNoted() throws {
        // S clear → BrushId is an object-table index (5) that was never bound.
        let file = try plusFile([fillRectsBrush(5, (10, 10, 20, 20))])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .missingReference, count: 1)),
                "an unbound brush should note missingReference: \(log.entries)")
    }

    @Test("an EmfPlusObject with an out-of-range id (70) notes .invalidID")
    func objectInvalidIDNoted() throws {
        let file = try plusFile([
            plusObject(id: 70, type: 1, payload: solidBrushPayload(argb(255, 255, 0, 0))),
            fillRectsDirect(argb(255, 0, 0, 255), (10, 10, 20, 20)),   // a real draw → EMF+ branch
        ])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .invalidID, count: 1)),
                "an id past 63 should note invalidID: \(log.entries)")
    }

    @Test("a malformed brush definition then a draw notes .undecodable (bind) and .missingReference (draw)")
    func malformedBrushNoted() throws {
        // A brush object whose payload is too short to decode → .malformed on
        // bind; the fill then finds no usable brush → missingReference.
        let file = try plusFile([
            plusObject(id: 2, type: 1, payload: le { $0.u32(plusVersion) }),   // truncated brush (Version only)
            fillRectsBrush(2, (10, 10, 20, 20)),
        ])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .undecodable, count: 1)),
                "a malformed brush should note undecodable at bind: \(log.entries)")
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .missingReference, count: 1)),
                "the draw over the malformed slot should note missingReference: \(log.entries)")
    }

    @Test("repeated undecodable records coalesce into a single counted entry")
    func recordUndecodableCoalesces() throws {
        let truncated = plusRecord(0x400A, 0x8000, le { $0.u32(argb(255, 0, 0, 0)) })   // BrushId only
        let file = try plusFile([truncated, truncated, truncated])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x400A, count: 3)),
                "three truncated FillRects should coalesce to count 3: \(log.entries)")
    }

    // MARK: - Audit M1 (D1): save/container map cap

    @Test("a Save flood past the cap survives, notes the cap, and a pre-flood save still restores")
    func saveFloodCappedButPreservesEarlierSaves() throws {
        var records: [[UInt8]] = [
            translateWorld(40, 0),   // world = +40 in x
            save(5),                 // savedStates[5] captures the translated state
            translateWorld(-40, 0),  // back to identity
        ]
        for index in 0 ..< 600 { records.append(save(UInt32(1000 + index))) }   // flood distinct indices
        records.append(restore(5))   // no eviction → index 5 is still there
        records.append(fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)))   // → device (50..70, 10..30)
        let (pixels, log) = try renderPlus(try plusFile(records))

        #expect(log.entries.contains { if case .emfPlusSaveStackCapped = $0 { return true }; return false },
                "the save flood should note the cap: \(log.entries)")
        let restored = pixels[60, 20]
        #expect(restored.r > 200 && restored.g < 60 && restored.b < 60,
                "the pre-flood save (index 5) restored the +40 translate, got \(restored)")
        let original = pixels[20, 20]
        #expect(original.r > 230 && original.g > 230 && original.b > 230,
                "the untranslated position stays empty, got \(original)")
    }

    // MARK: - Clip/state honesty follow-up (D4)

    @Test("SetClipPath referencing an unbound path slot notes .missingReference")
    func setClipPathUnboundNoted() throws {
        let file = try plusFile([
            plusRecord(0x4033, 5),   // SetClipPath, pathId 5 (unbound), mode 0
            fillRectsDirect(argb(255, 0, 0, 0), (10, 10, 20, 20)),   // drawing → EMF+ branch
        ])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .missingReference, count: 1)),
                "an unbound clip path should note missingReference: \(log.entries)")
    }

    @Test("a truncated SetWorldTransform body notes .emfPlusRecordUndecodable with type 0x402A")
    func truncatedWorldTransformNoted() throws {
        let file = try plusFile([
            plusRecord(0x402A, 0, le { $0.f32(1); $0.f32(0) }),      // 8 of the 24 matrix bytes
            fillRectsDirect(argb(255, 0, 0, 0), (10, 10, 20, 20)),   // drawing → EMF+ branch
        ])
        let (_, log) = try renderPlus(file)
        #expect(log.entries.contains(.emfPlusRecordUndecodable(type: 0x402A, count: 1)),
                "a truncated SetWorldTransform should note recordUndecodable(0x402A): \(log.entries)")
    }
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

    @Test("a fully-outside SrcRect draws nothing (M12)")
    func drawImageFullyOutsideSrc() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageObjectPayload()),
            drawImageRecord(imageId: 1, src: (5, 5, 2, 2), dest: (10, 10, 40, 40)),   // src fully outside 2×2
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isWhite(pixels[30, 30]), "a fully-outside SrcRect must draw nothing, got \(pixels[30, 30])")
        #expect(log.isClean, "drawing nothing for an out-of-range SrcRect is correct — no log: \(log.entries)")
    }

    @Test("a half-outside SrcRect paints only the surviving fraction on the matching dest half (M12)")
    func drawImageHalfOutsideSrc() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: twoColumnImagePayload()),                // left red, right blue
            drawImageRecord(imageId: 1, src: (1, 0, 2, 2), dest: (10, 10, 40, 40)),        // src x 1..3 → right column survives
        ])
        let (pixels, _) = try renderPlus(file)
        // The surviving right column (blue) maps to the dest LEFT half (x 10..30);
        // the dest right half (nonexistent source x 2..3) stays blank.
        #expect(isBlue(pixels[18, 25]), "the surviving blue column should paint the dest left half, got \(pixels[18, 25])")
        #expect(isWhite(pixels[42, 25]), "the dest right half stays blank, got \(pixels[42, 25])")
    }

    @Test("DrawImage naming an unbound image object draws nothing and notes a missing reference")
    func drawImageUnboundIsNoOp() throws {
        let file = try plusFile([
            drawImageRecord(imageId: 7, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        // Audit M7: no longer silent — the missing image reference is surfaced.
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .missingReference, count: 1)),
                "an unbound image should note a missing object reference: \(log.entries)")
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

// MARK: - Preset pen dash styles (audit M4 / E1)

@Suite("EMF+ preset pen dashes")
struct EMFPlusPenDashTests {

    private func makePenData(width: Float = 4, lineStyle: Int32? = nil, dashedLine: [Float]? = nil, dashOffset: Float? = nil) -> EMFPlusPenData {
        EMFPlusPenData(
            flags: 0, unit: 0, width: width, transform: nil, startCap: nil, endCap: nil, join: nil,
            miterLimit: nil, lineStyle: lineStyle, dashedLineCap: nil, dashOffset: dashOffset,
            dashedLine: dashedLine, penAlignment: nil, compoundLine: nil, customStartCap: nil, customEndCap: nil)
    }
    private func makePen(_ data: EMFPlusPenData) -> EMFPlusPen {
        EMFPlusPen(
            version: plusVersion, type: 0, penData: data,
            brush: EMFPlusBrush(version: plusVersion, brushType: EMFPlusBrushType(rawValue: 0),
                                data: .solid(EMFPlusARGB(blue: 0, green: 0, red: 0, alpha: 255))))
    }
    private func dashOf(_ data: EMFPlusPenData) -> [CGFloat] {
        var log = EMFRenderLog()
        return EMFPlusPaint.strokeStyle(makePen(data), full: .identity, log: &log).dash
    }

    @Test("a preset LineStyle maps to the GDI dash pattern (× width)")
    func presetPatterns() {
        #expect(dashOf(makePenData(width: 4, lineStyle: 1)) == [12, 4])              // Dash [3,1]
        #expect(dashOf(makePenData(width: 4, lineStyle: 2)) == [4, 4])               // Dot [1,1]
        #expect(dashOf(makePenData(width: 4, lineStyle: 3)) == [12, 4, 4, 4])        // DashDot
        #expect(dashOf(makePenData(width: 4, lineStyle: 4)) == [12, 4, 4, 4, 4, 4])  // DashDotDot
    }

    @Test("a custom DashedLine array wins over a preset LineStyle")
    func customArrayWins() {
        #expect(dashOf(makePenData(width: 4, lineStyle: 1, dashedLine: [5, 2])) == [20, 8],
                "custom [5,2]×4 should win over the Dash preset")
    }

    @Test("an absent/zero/unknown/Custom LineStyle stays solid")
    func unknownStaysSolid() {
        #expect(dashOf(makePenData(lineStyle: nil)).isEmpty)
        #expect(dashOf(makePenData(lineStyle: 0)).isEmpty)
        #expect(dashOf(makePenData(lineStyle: 99)).isEmpty)
        #expect(dashOf(makePenData(lineStyle: 5)).isEmpty, "Custom with no array stays solid")
    }

    @Test("a LineStyle=Dash pen strokes a dashed line (on-dash inked, in-gap clean)")
    func dashPenStrokesDashed() throws {
        // width 6 → Dash [3,1]×6 = [18,6]; line from x=5 → on [5,23), gap [23,29).
        let pen = plusObject(id: 1, type: 2, payload: penPayloadLineStyle(width: 6, argb: argb(255, 0, 0, 0), lineStyle: 1))
        let file = try plusFile([pen, drawLines(penId: 1, [(5, 50), (95, 50)])])
        let (image, log) = try renderPlus(file)
        #expect(image.containsDarkPixel(in: (x: 8, y: 46, width: 8, height: 8)), "on-dash segment should be inked")
        #expect(!image.containsDarkPixel(in: (x: 24, y: 46, width: 3, height: 8)), "in-gap window should be clean")
        #expect(log.isClean, "a preset dash is correct behavior — no note expected: \(log.entries)")
    }
}

/// EmfPlusFillPie (§2.3.4.12), S flag (direct ARGB): BrushId, StartAngle,
/// SweepAngle (f32), RectData (RectF) — for the E2 makeImage probe.
private func fillPieDirect(_ color: UInt32, start: Float, sweep: Float, _ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x4010, 0x8000, le { writer in
        writer.u32(color)
        writer.f32(start); writer.f32(sweep)
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

/// Every point emitted by a path, in order (curve control points included) —
/// so an arc's FIRST point is the on-ellipse start and its LAST is the endpoint.
private func pathPoints(_ path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = []
    path.applyWithBlock { elementPtr in
        let element = elementPtr.pointee
        switch element.type {
        case .moveToPoint, .addLineToPoint:
            points.append(element.points[0])
        case .addQuadCurveToPoint:
            points.append(element.points[0]); points.append(element.points[1])
        case .addCurveToPoint:
            points.append(element.points[0]); points.append(element.points[1]); points.append(element.points[2])
        case .closeSubpath:
            break
        @unknown default:
            break
        }
    }
    return points
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    (((a.x - b.x) * (a.x - b.x)) + ((a.y - b.y) * (a.y - b.y))).squareRoot()
}

// MARK: - Arc/pie true-angle convention (audit M5 / E2 + L12)

@Suite("EMF+ arc angle convention")
struct EMFPlusArcTests {

    @Test("an elliptical arc's start point is the TRUE-angle ray∩ellipse, not the parametric point")
    func ellipticalArcStartIsTrueAngle() {
        let path = CGMutablePath()
        // rect 200×100 → rx=100, ry=50, center (100,50). Start 45° true, sweep 90°.
        EMFPlusGeometry.appendArc(rect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                  startDegrees: 45, sweepDegrees: 90, pie: false, to: path, transform: .identity)
        let start = pathPoints(path).first!
        #expect(distance(start, CGPoint(x: 144.72, y: 94.72)) < 0.5,
                "true-angle start should be ≈(144.72, 94.72), got \(start)")
        // Bind the CONVERSION, not just the tolerance: far from the old parametric
        // point (170.71, 85.36).
        #expect(distance(start, CGPoint(x: 170.71, y: 85.36)) > 10,
                "must differ from the old parametric point, got \(start)")
    }

    @Test("a circular arc is unchanged (parametric == true)")
    func circularArcIsIdentity() {
        let path = CGMutablePath()
        // rect 100×100 → circle rx=ry=50, center (50,50). Start 45° → (85.36, 85.36).
        EMFPlusGeometry.appendArc(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  startDegrees: 45, sweepDegrees: 90, pie: false, to: path, transform: .identity)
        let start = pathPoints(path).first!
        #expect(distance(start, CGPoint(x: 85.36, y: 85.36)) < 0.5,
                "a circle's start point is unchanged, got \(start)")
    }

    @Test("a zero-sweep arc and pie emit an empty path (L12)")
    func zeroSweepEmpty() {
        let arc = CGMutablePath()
        EMFPlusGeometry.appendArc(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  startDegrees: 30, sweepDegrees: 0, pie: false, to: arc, transform: .identity)
        #expect(arc.isEmpty, "a zero-sweep arc draws nothing")
        let pie = CGMutablePath()
        EMFPlusGeometry.appendArc(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  startDegrees: 30, sweepDegrees: 0, pie: true, to: pie, transform: .identity)
        #expect(pie.isEmpty, "a zero-sweep pie draws nothing")
    }

    @Test("a negative sweep lands its endpoint on the correct (lower) side")
    func negativeSweepEndpoint() {
        let path = CGMutablePath()
        // Start 45° (upper right), sweep -90° → end at true -45° (lower right).
        EMFPlusGeometry.appendArc(rect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                  startDegrees: 45, sweepDegrees: -90, pie: false, to: path, transform: .identity)
        let points = pathPoints(path)
        let start = points.first!, end = points.last!
        #expect(start.y > 50 && end.y < 50, "start is above center, endpoint below, got start \(start) end \(end)")
        #expect(end.x > 100, "endpoint stays on the right (true -45°), got \(end)")
    }

    @Test("a FillPie renders its wedge on the true-angle side (makeImage probe)")
    func fillPieRendersWedge() throws {
        // Ellipse rect (10,10,80,60) → rx=40, ry=30, center (50,40). Start 45°,
        // sweep 90° → wedge spans true 45°→135° (the lower-middle region).
        let file = try plusFile([fillPieDirect(argb(255, 255, 0, 0), start: 45, sweep: 90, (10, 10, 80, 60))])
        let (image, _) = try renderPlus(file)
        let inside = image[50, 60]
        #expect(inside.r > 200 && inside.g < 60 && inside.b < 60, "the wedge interior should be red, got \(inside)")
        #expect(image[50, 15].r > 230, "the opposite side stays background, got \(image[50, 15])")
    }
}

// MARK: - Approximation-fallback fixtures (audit H4 / F2)

/// True when the log carries exactly `count` occurrences of an approximation.
private func hasApprox(_ log: EMFRenderLog, _ feature: EMFPlusApproximation, count: Int = 1) -> Bool {
    log.entries.contains(.emfPlusApproximated(feature: feature, count: count))
}

/// EmfPlusHatchBrushData (§2.2.2.20): Version, Type 1, HatchStyle, ForeColor, BackColor.
private func hatchBrushPayload(style: UInt32, fore: UInt32, back: UInt32) -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(1); $0.u32(style); $0.u32(fore); $0.u32(back) }
}

/// EmfPlusPathGradientBrushData (§2.2.2.29), minimal: no surrounding colors, an
/// empty point boundary. The playback falls back to CenterColor.
private func pathGradientBrushPayload(center: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(3)   // Version, Type 3 (path gradient)
        writer.u32(0)                             // BrushDataFlags
        writer.i32(0)                             // WrapMode
        writer.u32(center)                        // CenterColor (ARGB)
        writer.f32(50); writer.f32(50)            // CenterPoint
        writer.u32(0)                             // SurroundingColorCount
        writer.i32(0)                             // boundary point count (BrushDataPath clear)
    }
}

/// EmfPlusTextureBrushData (§2.2.2.45): Version, Type 2, then raw (undecoded).
private func textureBrushPayload() -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(2) }
}

/// A pen whose trailing BrushObject is a HATCH (non-solid) → penNonSolidBrush.
private func penHatchBrushPayload(width: Float, fore: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(0)          // Version, Type
        writer.u32(0); writer.u32(0); writer.f32(width)  // PenDataFlags 0, PenUnit, PenWidth
        writer.raw(hatchBrushPayload(style: 0, fore: fore, back: argb(255, 255, 255, 255)))
    }
}

/// A pen with a triangle StartCap (PenDataFlags 0x2) and a solid brush → penCap.
private func penTriangleCapPayload(width: Float, color: UInt32) -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(0)
        writer.u32(0x02); writer.u32(0); writer.f32(width)   // PenDataFlags=StartCap
        writer.i32(3)                                        // LineCapTypeTriangle
        writer.u32(plusVersion); writer.u32(0); writer.u32(color)   // solid brush
    }
}

/// SetClipRect (§2.3.1.4) with CombineMode Union (CM = 2, bits 8–11).
private func setClipRectUnion(_ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x4032, UInt16(2) << 8, le { $0.f32(rect.0); $0.f32(rect.1); $0.f32(rect.2); $0.f32(rect.3) })
}

/// A RegionNodeDataTypeRect leaf (§2.2.2.40) covering `r`.
private func regionRectLeaf(_ r: (Float, Float, Float, Float)) -> [UInt8] {
    le { $0.u32(0x1000_0000); $0.f32(r.0); $0.f32(r.1); $0.f32(r.2); $0.f32(r.3) }
}

/// An EmfPlusRegion object (§2.2.1.8) whose root is an AND (Intersect) combine of
/// two rect leaves — a non-union node the playback resolves as a union + note.
private func regionAndPayload(_ a: (Float, Float, Float, Float), _ b: (Float, Float, Float, Float)) -> [UInt8] {
    le { $0.u32(plusVersion); $0.u32(3) } + le { $0.u32(0x0000_0001) } + regionRectLeaf(a) + regionRectLeaf(b)
}

/// FillRegion (§2.3.4.13), S flag: BrushId (direct ARGB); ObjectID = region slot.
private func fillRegionDirect(_ color: UInt32, regionId: UInt8) -> [UInt8] {
    plusRecord(0x4013, 0x8000 | UInt16(regionId), le { $0.u32(color) })
}

private func offsetClipRecord() -> [UInt8] { plusRecord(0x4035, 0) }   // §2.3.1.3

/// SetPageTransform (§2.3.9.5): PageUnit in the low Flags byte, PageScale (f32).
private func setPageTransformRecord(scale: Float, unit: UInt16) -> [UInt8] {
    plusRecord(0x4030, unit, le { $0.f32(scale) })
}

/// SetCompositingMode (§2.3.6.4): CompositingMode in the low Flags byte.
private func setCompositingModeRecord(_ mode: UInt16) -> [UInt8] { plusRecord(0x4023, mode) }

/// BeginContainer (§2.3.7.1): DestRect, SrcRect (RectF), StackIndex (u32).
private func beginContainerRecord(dest: (Float, Float, Float, Float), src: (Float, Float, Float, Float), index: UInt32) -> [UInt8] {
    plusRecord(0x4027, 0, le { writer in
        writer.f32(dest.0); writer.f32(dest.1); writer.f32(dest.2); writer.f32(dest.3)
        writer.f32(src.0); writer.f32(src.1); writer.f32(src.2); writer.f32(src.3)
        writer.u32(index)
    })
}

/// A pixel bitmap image whose Stride (4) is smaller than width·bpp (2×4) → invalid.
private func imageInvalidStridePayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(1)   // Version, ImageDataTypeBitmap
        writer.i32(2); writer.i32(2); writer.i32(4)   // Width, Height, Stride (< 2×4)
        writer.u32(0x0026_200A); writer.u32(0)   // 32bpp ARGB, BitmapDataTypePixel
        writer.raw([UInt8](repeating: 0, count: 16))
    }
}

/// A compressed image whose stream is GIF ("GIF89a") — CoreGraphics declines it.
private func imageCompressedGIFPayload() -> [UInt8] {
    le { writer in
        writer.u32(plusVersion); writer.u32(1)   // Version, ImageDataTypeBitmap
        writer.i32(0); writer.i32(0); writer.i32(0); writer.u32(0)   // dims/format unused
        writer.u32(1)             // BitmapDataTypeCompressed
        writer.raw([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x00, 0x00])   // "GIF89a" padded to a 4-aligned record
    }
}

// MARK: - Approximation fallbacks: brushes & pens (audit H4 / F2a)

@Suite("EMF+ fallback: brushes & pens")
struct EMFPlusFallbackBrushPenTests {
    private func isColor(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), r: UInt8, g: UInt8, b: UInt8) -> Bool {
        abs(Int(p.r) - Int(r)) < 60 && abs(Int(p.g) - Int(g)) < 60 && abs(Int(p.b) - Int(b)) < 60
    }

    @Test("a hatch brush fills its foreground colour with a note")
    func hatchBrush() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 1, payload: hatchBrushPayload(style: 0, fore: argb(255, 0, 160, 0), back: argb(255, 255, 255, 255))),
            fillRectsBrush(1, (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isColor(pixels[25, 25], r: 0, g: 160, b: 0), "hatch → foreColor solid, got \(pixels[25, 25])")
        #expect(hasApprox(log, .hatchBrush), "expected a hatchBrush note: \(log.entries)")
    }

    @Test("a path-gradient brush fills its centre colour with a note")
    func pathGradientBrush() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 1, payload: pathGradientBrushPayload(center: argb(255, 0, 0, 200))),
            fillRectsBrush(1, (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isColor(pixels[25, 25], r: 0, g: 0, b: 200), "path gradient → centerColor solid, got \(pixels[25, 25])")
        #expect(hasApprox(log, .pathGradientBrush), "expected a pathGradientBrush note: \(log.entries)")
    }

    @Test("a texture brush draws no ink and notes the skip")
    func textureBrush() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 1, payload: textureBrushPayload()),
            fillRectsBrush(1, (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(pixels[25, 25].r > 230 && pixels[25, 25].g > 230 && pixels[25, 25].b > 230,
                "a texture fill should leave the region blank, got \(pixels[25, 25])")
        #expect(hasApprox(log, .textureBrush), "expected a textureBrush note: \(log.entries)")
    }

    @Test("a pen with a non-solid brush strokes a representative solid with a note")
    func penNonSolidBrush() throws {
        let file = try plusFile([
            plusObject(id: 2, type: 2, payload: penHatchBrushPayload(width: 4, fore: argb(255, 0, 0, 0))),
            drawLines(penId: 2, [(10, 50), (90, 50)]),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(pixels.containsDarkPixel(in: (x: 40, y: 47, width: 20, height: 6)), "the stroke should draw ink")
        #expect(hasApprox(log, .penNonSolidBrush), "expected a penNonSolidBrush note: \(log.entries)")
    }

    @Test("a pen with a triangle cap strokes with a note")
    func penCap() throws {
        let file = try plusFile([
            plusObject(id: 2, type: 2, payload: penTriangleCapPayload(width: 4, color: argb(255, 0, 0, 0))),
            drawLines(penId: 2, [(10, 50), (90, 50)]),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(pixels.containsDarkPixel(in: (x: 40, y: 47, width: 20, height: 6)), "the stroke should draw ink")
        #expect(hasApprox(log, .penCap), "expected a penCap note: \(log.entries)")
    }
}

// MARK: - Approximation fallbacks: clip & state (audit H4 / F2b)

@Suite("EMF+ fallback: clip & state")
struct EMFPlusFallbackClipStateTests {
    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 }

    @Test("SetClipRect Union is applied as an intersection with a note")
    func clipCombineMode() throws {
        let file = try plusFile([
            setClipRectUnion((10, 10, 30, 30)),                        // CM=Union → intersect + note
            fillRectsDirect(argb(255, 255, 0, 0), (0, 0, 100, 100)),   // whole canvas, clipped
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[20, 20]), "ink inside the clip rect")
        #expect(isWhite(pixels[60, 60]), "no ink outside — applied as an intersection")
        #expect(hasApprox(log, .clipCombineMode), "expected a clipCombineMode note: \(log.entries)")
    }

    @Test("a non-union region combine renders as a union with a note")
    func regionCombine() throws {
        let file = try plusFile([
            plusObject(id: 3, type: 4, payload: regionAndPayload((10, 10, 20, 20), (25, 25, 20, 20))),
            fillRegionDirect(argb(255, 255, 0, 0), regionId: 3),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[15, 15]) || isRed(pixels[35, 35]), "the region union should fill somewhere, got \(pixels[15, 15]) / \(pixels[35, 35])")
        #expect(hasApprox(log, .regionCombine), "expected a regionCombine note: \(log.entries)")
    }

    @Test("OffsetClip leaves the clip in place with a note")
    func offsetClip() throws {
        let file = try plusFile([
            setClipRectIntersect((10, 10, 30, 30)),                    // clip to (10..40)
            offsetClipRecord(),                                        // no-op + note
            fillRectsDirect(argb(255, 255, 0, 0), (0, 0, 100, 100)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[20, 20]), "clip stayed at its original position")
        #expect(isWhite(pixels[60, 60]), "outside the unchanged clip stays blank")
        #expect(hasApprox(log, .offsetClip), "expected an offsetClip note: \(log.entries)")
    }

    @Test("a Point page unit converts EXACTLY via the header DPI, with no note (M10)")
    func pageUnitPointExact() throws {
        // Header DPI 96 (plusHeader default) → Point factor 96/72 = 1.333, so page
        // scale 2 becomes 2.667 device px/unit. The fill at world (10..20) lands at
        // device (26.7..53.3) — a raw ×2 would stop at 40, so ink at (48,48) binds
        // the DPI conversion.
        let file = try plusFile([
            setPageTransformRecord(scale: 2, unit: 3),                 // PageUnit Point
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 10, 10)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[48, 48]), "DPI-converted extent should reach (48,48), got \(pixels[48, 48])")
        #expect(isWhite(pixels[22, 22]), "the DPI-converted start is beyond the raw-scale start, got \(pixels[22, 22])")
        #expect(!hasApprox(log, .pageUnit), "an exact physical unit must NOT note: \(log.entries)")
    }

    @Test("a Display page unit is a noted approximation (spec-unused)")
    func pageUnitDisplayNote() throws {
        let file = try plusFile([
            setPageTransformRecord(scale: 2, unit: 1),                 // PageUnit Display → note, raw ×2
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 10, 10)),   // world (10..20) → ×2 → (20..40)
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[30, 30]), "the raw ×2 fill should render at (20..40), got \(pixels[30, 30])")
        #expect(hasApprox(log, .pageUnit), "Display should note a pageUnit approximation: \(log.entries)")
    }

    @Test("a non-source-over compositing mode still blends source-over with a note")
    func compositingMode() throws {
        let file = try plusFile([
            setCompositingModeRecord(1),                               // non-SourceOver → note
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 20, 20)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[20, 20]), "the fill still drew (source-over)")
        #expect(hasApprox(log, .compositingMode), "expected a compositingMode note: \(log.entries)")
    }

    @Test("BeginContainer applies its src→dest mapping with a note")
    func container() throws {
        let file = try plusFile([
            beginContainerRecord(dest: (0, 0, 100, 100), src: (0, 0, 50, 50), index: 1),   // ×2 mapping
            fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 10, 10)),                        // (10..20) → ×2 → (20..40)
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isRed(pixels[30, 30]), "the container's ×2 mapping placed the fill at (20..40), got \(pixels[30, 30])")
        #expect(isWhite(pixels[15, 15]), "the unmapped position is empty")
        #expect(hasApprox(log, .container), "expected a container note: \(log.entries)")
    }
}

// MARK: - Approximation fallbacks: images (audit H4 / F2c)

@Suite("EMF+ fallback: images")
struct EMFPlusFallbackImageTests {
    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 }

    @Test("an invalid-stride pixel bitmap draws nothing and notes imageInvalid")
    func imageInvalid() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageInvalidStridePayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isWhite(pixels[30, 30]), "an invalid image should draw nothing, got \(pixels[30, 30])")
        #expect(hasApprox(log, .imageInvalid), "expected an imageInvalid note: \(log.entries)")
    }

    @Test("a GIF compressed image draws nothing and notes imageCompressed")
    func imageCompressed() throws {
        let file = try plusFile([
            plusObject(id: 1, type: 5, payload: imageCompressedGIFPayload()),
            drawImageRecord(imageId: 1, src: (0, 0, 2, 2), dest: (10, 10, 40, 40)),
        ])
        let (pixels, log) = try renderPlus(file)
        #expect(isWhite(pixels[30, 30]), "a GIF image should draw nothing, got \(pixels[30, 30])")
        #expect(hasApprox(log, .imageCompressed), "expected an imageCompressed note: \(log.entries)")
    }
}

// MARK: - Continuation / cross-comment reassembly through render (audit H3 / M17 / F1)

@Suite("EMF+ continuation through render")
struct EMFPlusContinuationTests {

    private func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 130 && p.r < 90 && p.b < 90 }

    @Test("a solid brush split across two continued objects in two comments completes and fills")
    func continuedObjectAcrossComments() throws {
        let brushBytes = solidBrushPayload(argb(255, 0, 200, 0))   // 12 bytes, green
        let total = UInt32(brushBytes.count)
        // Split at a 4-byte boundary so each chunk record's Size stays 4-aligned.
        let chunk1 = continuedObjectChunk(id: 1, type: 1, total: total, partial: Array(brushBytes[0 ..< 8]))
        let chunk2 = continuedObjectChunk(id: 1, type: 1, total: total, partial: Array(brushBytes[8...]))

        var fixture = RenderFixture()
        fixture.plusComment(plusHeader() + chunk1)                        // comment 1: header + first chunk
        fixture.plusComment(chunk2 + fillRectsBrush(1, (10, 10, 30, 30))) // comment 2: second chunk + a draw

        let (pixels, log) = try renderPlus(try fixture.parsed())
        #expect(isGreen(pixels[25, 25]), "the reassembled brush should fill green, got \(pixels[25, 25])")
        #expect(!log.entries.contains { if case .emfPlusObjectIssue = $0 { return true }; return false },
                "a completed continuation must not log an object issue: \(log.entries)")
        #expect(!log.entries.contains { if case .emfPlusStreamIssue = $0 { return true }; return false },
                "clean cross-comment reassembly must not log a stream issue: \(log.entries)")
    }

    @Test("a continuation that OVERSHOOTS TotalObjectSize binds prefix(total) and still fills")
    func continuedObjectOvershoot() throws {
        let brushBytes = solidBrushPayload(argb(255, 0, 200, 0))
        let total = UInt32(brushBytes.count)
        let chunk1 = continuedObjectChunk(id: 1, type: 1, total: total, partial: Array(brushBytes[0 ..< 8]))
        // Second chunk carries the remaining 4 bytes PLUS 4 extra tail bytes (both
        // 4-aligned): accumulation overshoots TotalObjectSize and binds prefix(total).
        let chunk2 = continuedObjectChunk(id: 1, type: 1, total: total, partial: Array(brushBytes[8...]) + [0xDE, 0xAD, 0xBE, 0xEF])

        var fixture = RenderFixture()
        fixture.plusComment(plusHeader() + chunk1)
        fixture.plusComment(chunk2 + fillRectsBrush(1, (10, 10, 30, 30)))

        let (pixels, log) = try renderPlus(try fixture.parsed())
        #expect(isGreen(pixels[25, 25]), "overshoot should still bind prefix(total), got \(pixels[25, 25])")
        #expect(!log.entries.contains { if case .emfPlusObjectIssue = $0 { return true }; return false },
                "overshoot completion must not log an object issue: \(log.entries)")
    }

    @Test("a single drawing record split mid-body across two comments reassembles and draws")
    func drawingRecordSplitAcrossComments() throws {
        let record = fillRectsDirect(argb(255, 255, 0, 0), (10, 10, 30, 30))   // one 36-byte FillRects
        var fixture = RenderFixture()
        fixture.plusComment(plusHeader() + Array(record[0 ..< 20]))   // record's first 20 bytes
        fixture.plusComment(Array(record[20...]))                      // record's remaining bytes

        let (pixels, log) = try renderPlus(try fixture.parsed())
        let ink = pixels[25, 25]
        #expect(ink.r > 200 && ink.g < 60 && ink.b < 60, "the split record should reassemble and fill red, got \(ink)")
        #expect(!log.entries.contains { if case .emfPlusStreamIssue = $0 { return true }; return false },
                "byte-level cross-comment reassembly must not log a stream issue: \(log.entries)")
    }
}
