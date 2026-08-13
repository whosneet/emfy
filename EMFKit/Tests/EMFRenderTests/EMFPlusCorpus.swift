import Foundation

/// Deterministic byte generator for the two committed EMF+ corpus files
/// (`corpus/handmade-emfplus-shapes.emf` and `corpus/handmade-emfplus-dual.emf`).
///
/// The CJK precedent (`CJKTextCorpus`): a self-contained, hand-authored EMF whose
/// bytes are a pure function of the literals below, so each committed file is
/// provenance-verifiable — `SnapshotEMFPlusTests` asserts the on-disk file equals
/// the generator byte-for-byte, and re-materialises it under `EMFY_RECORD=1`.
///
/// No committed EMF+ file with real EMF+ DRAWING content exists in any corpus, so
/// these are hand-authored to cover the phase-3 EMF+ playback path that the
/// LibreOffice shell files cannot reach:
///
/// - **shapes** is EMF+-ONLY (EmfPlusHeader Dual flag CLEAR): every EMF+ record
///   lives in one EMR_COMMENT_EMFPLUS, exercising object-table paths/brushes/
///   pens, direct-colour and object-brush fills, a linear gradient, a world
///   translate, an intersect clip, and an open i16 polyline.
/// - **dual** is DUAL (Dual flag SET) with a DIVERGENT GDI fallback: it proves
///   the EMF+ arbitration ([MS-EMFPLUS] §1.3.1) renders the EMF+ half plus only
///   the GDI records inside a GetDC window — a GDI-only rectangle placed outside
///   any window renders in a v1-style GDI player but MUST NOT here.
///
/// Every field layout is cited against [MS-EMF] / [MS-EMFPLUS]. EMF record types
/// are the [MS-EMF] §2.1.1 RecordType values; EMF+ record types are the
/// [MS-EMFPLUS] §2.1.1.1 values.
enum EMFPlusCorpus {

    // MARK: - Layout constants

    /// Header `rclBounds`, inclusive-inclusive device space ([MS-EMF] §2.2.9):
    /// a 360×240 canvas (`makeImage` sizes width = right−left+1, height = …).
    static let boundsRight: Int32 = 359
    static let boundsBottom: Int32 = 239

    /// EmfPlusGraphicsVersion ([MS-EMFPLUS] §2.2.2.19), GDI+ 1.1.
    private static let plusVersion: UInt32 = 0xDBC0_1002

    // MARK: - Assembled bytes

    static let shapesData = Data(shapesBytes)
    static let dualData = Data(dualBytes)
    static let imageData = Data(imageBytes)

    /// **handmade-emfplus-shapes.emf** — EMF+-only, Dual flag CLEAR.
    ///
    /// EMF+ record order (all in one EMR_COMMENT_EMFPLUS): Header → Object(path
    /// #1, triangle) → Object(brush #2, green) → FillPath(#1, #2) → Object(pen
    /// #3, black w3) → DrawPath(#1, #3) → FillRects(direct red) →
    /// Object(brush #4, red→blue linear gradient) → FillEllipse(#4) →
    /// TranslateWorldTransform(+200,0) → FillRects(direct magenta, shifted) →
    /// ResetWorldTransform → SetClipRect(Intersect) → FillRects(direct orange,
    /// clipped) → ResetClip → DrawLines(i16 open polyline, pen #3) → EndOfFile.
    static var shapesBytes: [UInt8] {
        var stream: [UInt8] = []
        stream += plusHeader(dual: false)

        // Object #1: a triangle path — start, line, line+close ([MS-EMFPLUS]
        // §2.2.1.6 / §2.2.2.31: high-nibble 0x8 closes the subpath).
        stream += plusObject(id: 1, type: 3, payload: pathPayload(
            points: [(20, 80), (70, 20), (120, 80)],
            types: [0x00, 0x01, 0x81]
        ))
        // Object #2: a solid green brush; FillPath fills the triangle with it.
        stream += plusObject(id: 2, type: 1, payload: solidBrushPayload(colorGreen))
        stream += fillPath(pathId: 1, brushId: 2)
        // Object #3: a solid black width-3 pen; DrawPath strokes the outline.
        stream += plusObject(id: 3, type: 2, payload: penPayload(width: 3, argb: colorBlack))
        stream += drawPath(pathId: 1, penId: 3)

        // Direct-colour FillRects (S bit): a red rectangle.
        stream += fillRectsDirect(color: colorRed, rect: (140, 25, 45, 40))

        // Object #4: a red→blue horizontal linear gradient (WrapMode Clamp, so no
        // wrap-mode approximation); FillEllipse fills an ellipse with it.
        stream += plusObject(id: 4, type: 1, payload: linearGradientPayload(
            rect: (230, 20, 100, 60), start: colorRed, end: colorBlue, wrapMode: 4
        ))
        stream += fillEllipse(brushId: 4, rect: (230, 20, 100, 60))

        // Translate the world +200 in x, fill a magenta rect (drawn at x+200),
        // then reset — proving the shift while keeping the clip section clean.
        stream += translateWorld(200, 0)
        stream += fillRectsDirect(color: colorMagenta, rect: (20, 150, 40, 30))
        stream += resetWorldTransform()

        // Intersect clip to a small rect, fill a wide orange rect (confined to
        // the clip), then reset the clip so the lines draw freely.
        stream += setClipRectIntersect(rect: (230, 195, 50, 35))
        stream += fillRectsDirect(color: colorOrange, rect: (0, 190, 360, 50))
        stream += resetClip()

        // Open polyline through i16 (C-flag) points, stroked by pen #3.
        stream += drawLinesI16(penId: 3, points: [(30, 95), (120, 90), (210, 95), (300, 100)])

        stream += plusEndOfFile()

        return assemble(body: [emfPlusComment(stream)], handles: 8)
    }

    /// **handmade-emfplus-dual.emf** — Dual flag SET, divergent GDI fallback.
    ///
    /// EMR record order: HEADER → COMMENT[Header(dual), FillRects red @A] →
    /// COMMENT[GetDC] → GDI green rectangle @B (brush/pen select + RECTANGLE) →
    /// COMMENT[SetAntiAliasMode] (closes the window) → GDI RECTANGLE @C (window
    /// closed → skipped) → COMMENT[EndOfFile] → GDI blue rectangle @D (outside
    /// any window → skipped) → EOF. A v1-style GDI player would draw B, C, and D
    /// but not A; EMF+ playback draws A and B only — that is the arbitration proof.
    ///
    /// Rects (device): A(30,30,60,60) red EMF+, B(150,30)-(210,90) green GDI,
    /// C(240,30)-(300,90) skipped, D(60,150)-(150,210) skipped.
    static var dualBytes: [UInt8] {
        var body: [[UInt8]] = []
        body.append(emfPlusComment(plusHeader(dual: true)
            + fillRectsDirect(color: colorRed, rect: (30, 30, 60, 60))))       // @A
        body.append(emfPlusComment(getDC()))                                   // open window

        // GDI green rectangle @B inside the window (NULL_PEN → no outline).
        body.append(createSolidBrush(index: 1, r: 0, g: 200, b: 0))
        body.append(selectObject(1))
        body.append(selectObject(0x8000_0008))                                 // NULL_PEN
        body.append(rectangle(150, 30, 210, 90))                               // @B

        body.append(emfPlusComment(setAntiAliasMode()))                        // closes window
        body.append(rectangle(240, 30, 300, 90))                               // @C — must NOT render

        body.append(emfPlusComment(plusEndOfFile()))

        // GDI-only blue rectangle @D outside any window — the divergence proof.
        body.append(createSolidBrush(index: 2, r: 0, g: 0, b: 200))
        body.append(selectObject(2))
        body.append(rectangle(60, 150, 150, 210))                              // @D — must NOT render

        return assemble(body: body, handles: 8)
    }

    /// **handmade-emfplus-image.emf** — EMF+-only, Dual flag CLEAR.
    ///
    /// EMF+ record order (all in one EMR_COMMENT_EMFPLUS): Header →
    /// Object(image #1, an 8×8 32bpp-ARGB pixel bitmap with four solid quadrants
    /// red/green/blue/white) → DrawImage(#1) scaling the whole image into a
    /// 120×120 dest rect → DrawImagePoints(#1) mapping the SAME image into a
    /// sheared parallelogram → EndOfFile. Proves bitmap decode, DrawImage
    /// scaling, and DrawImagePoints shear from one reused image object.
    static var imageBytes: [UInt8] {
        var stream: [UInt8] = []
        stream += plusHeader(dual: false)
        // Object #1: the 8×8 four-quadrant bitmap.
        stream += plusObject(id: 1, type: 5, payload: bitmapImagePayload())
        // DrawImage: scale the whole 8×8 image into a 120×120 dest at (40,30).
        stream += drawImage(imageId: 1, src: (0, 0, 8, 8), dest: (40, 30, 120, 120))
        // DrawImagePoints: map the same image into a sheared parallelogram.
        stream += drawImagePoints(imageId: 1, src: (0, 0, 8, 8),
                                  points: [(220, 40), (320, 60), (240, 150)])
        stream += plusEndOfFile()
        return assemble(body: [emfPlusComment(stream)], handles: 8)
    }

    // MARK: - Colours (ARGB DWORD 0xAARRGGBB, [MS-EMFPLUS] §2.2.2.1)

    private static let colorRed: UInt32 = 0xFFFF_0000
    private static let colorBlue: UInt32 = 0xFF00_00FF
    private static let colorGreen: UInt32 = 0xFF00_A000
    private static let colorBlack: UInt32 = 0xFF00_0000
    private static let colorMagenta: UInt32 = 0xFFFF_00FF
    private static let colorOrange: UInt32 = 0xFFFF_8C00

    // MARK: - Little-endian writer

    /// A minimal little-endian byte buffer ([MS-EMF] §1.3.1). Self-contained so
    /// the corpus bytes depend on nothing but this file (the provenance anchor).
    private struct LE {
        private(set) var bytes: [UInt8] = []
        mutating func u32(_ v: UInt32) {
            bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 24) & 0xFF))
        }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func u16(_ v: UInt16) {
            bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
        }
        mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
        /// ColorRef on-disk order Red, Green, Blue, Reserved ([MS-WMF] §2.2.2.8).
        mutating func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            bytes.append(contentsOf: [r, g, b, 0])
        }
        mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
        mutating func raw(_ r: [UInt8]) { bytes.append(contentsOf: r) }
    }

    // MARK: - EMF record framing

    /// Wraps a body as `iType`, `nSize`, body — with the tail padded to a 4-byte
    /// record boundary ([MS-EMF] §2.1, §3.2.1).
    private static func record(type: UInt32, body: [UInt8]) -> [UInt8] {
        var padded = body
        let unaligned = (8 + padded.count) % 4
        if unaligned != 0 { padded.append(contentsOf: repeatElement(0, count: 4 - unaligned)) }
        var w = LE()
        w.u32(type)
        w.u32(UInt32(8 + padded.count))
        w.raw(padded)
        return w.bytes
    }

    /// Assembles the complete file: header + body records + EMR_EOF, with the
    /// advisory Bytes/Records fields set truthfully (no exporter quirks).
    private static func assemble(body: [[UInt8]], handles: UInt16) -> [UInt8] {
        let eofRecord = eof()
        let recordCount = UInt32(1 + body.count + 1)   // header + body + EOF
        let totalBytes = UInt32(108 + body.reduce(0) { $0 + $1.count } + eofRecord.count)
        var out = header(totalBytes: totalBytes, recordCount: recordCount, handles: handles)
        for record in body { out.append(contentsOf: record) }
        out.append(contentsOf: eofRecord)
        return out
    }

    // MARK: - Header ([MS-EMF] §2.3.4.2, EmfMetafileHeaderExtension2)

    private static func header(totalBytes: UInt32, recordCount: UInt32, handles: UInt16) -> [UInt8] {
        var w = LE()
        w.u32(1)                    // 0   iType = EMR_HEADER
        w.u32(108)                  // 4   nSize (extension2 fixed part)
        w.i32(0); w.i32(0)          // 8   rclBounds.left, .top
        w.i32(boundsRight); w.i32(boundsBottom)  // 16  .right, .bottom
        // rclFrame in 0.01mm (§2.2.9): 360×240 px at ~96 DPI ≈ 95.25×63.5 mm.
        w.i32(0); w.i32(0); w.i32(9525); w.i32(6350)   // 24  rclFrame
        w.u32(0x464D_4520)          // 40  RecordSignature " EMF"
        w.u32(0x0001_0000)          // 44  Version
        w.u32(totalBytes)           // 48  Bytes (advisory, set TRUE)
        w.u32(recordCount)          // 52  Records (advisory, set TRUE)
        w.u16(handles)              // 56  Handles (> max GDI object index)
        w.u16(0)                    // 58  Reserved
        w.u32(0)                    // 60  nDescription
        w.u32(0)                    // 64  offDescription
        w.u32(0)                    // 68  nPalEntries
        w.i32(360); w.i32(240)      // 72  Device (px)
        w.i32(95); w.i32(63)        // 80  Millimeters
        w.u32(0); w.u32(0); w.u32(0)   // 88  cbPixelFormat, offPixelFormat, bOpenGL
        w.u32(0); w.u32(0)          // 100 MicrometersX, MicrometersY
        return w.bytes              // exactly 108 bytes
    }

    private static func eof() -> [UInt8] {
        var b = LE()
        b.u32(0)      // nPalEntries
        b.u32(16)     // offPalEntries
        b.u32(20)     // SizeLast
        return record(type: 14, body: b.bytes)   // 20 bytes
    }

    // MARK: - EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4)

    /// One EMR_COMMENT carrying an EMF+ record stream: DataSize (u32) =
    /// 4 + stream, the "EMF+" identifier (u32, 0x2B464D45), then the stream.
    private static func emfPlusComment(_ stream: [UInt8]) -> [UInt8] {
        var b = LE()
        b.u32(UInt32(4 + stream.count))   // DataSize (identifier + stream)
        b.u32(0x2B46_4D45)                // CommentIdentifier "EMF+"
        b.raw(stream)
        return record(type: 70, body: b.bytes)
    }

    // MARK: - EMF+ record framing ([MS-EMFPLUS] §2.3)

    /// One EMF+ record: Type (u16), Flags (u16), Size (u32, incl. the 12-byte
    /// header), DataSize (u32, excl. it), then data. EMF+ data is 4-aligned.
    private static func plusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8] = []) -> [UInt8] {
        var w = LE()
        w.u16(type)
        w.u16(flags)
        w.u32(UInt32(12 + data.count))
        w.u32(UInt32(data.count))
        w.raw(data)
        return w.bytes
    }

    // MARK: - EMF+ control records

    /// EmfPlusHeader (§2.3.3.3): Size MUST 0x1C, DataSize MUST 0x10; the record
    /// Flags bit 0 is Dual. Data = Version, EmfPlusFlags, LogicalDpiX/Y (96 dpi).
    private static func plusHeader(dual: Bool) -> [UInt8] {
        plusRecord(0x4001, dual ? 0x0001 : 0x0000, le { w in
            w.u32(plusVersion); w.u32(0); w.u32(96); w.u32(96)
        })
    }

    private static func plusEndOfFile() -> [UInt8] { plusRecord(0x4002, 0) }   // §2.3.3.1
    private static func getDC() -> [UInt8] { plusRecord(0x4004, 0) }           // §2.3.3.2
    private static func resetWorldTransform() -> [UInt8] { plusRecord(0x402B, 0) }  // §2.3.9.6
    private static func resetClip() -> [UInt8] { plusRecord(0x4031, 0) }       // §2.3.1.1

    /// EmfPlusSetAntiAliasMode (§2.3.6.1): SmoothingMode + antialias bit live in
    /// Flags; no data. Used here purely to close the preceding GetDC window.
    private static func setAntiAliasMode() -> [UInt8] { plusRecord(0x401E, 0x0001) }

    // MARK: - EMF+ objects ([MS-EMFPLUS] §2.3.5.1)

    /// EmfPlusObject: Flags = ObjectType<<8 | ObjectID (brush 1, pen 2, path 3).
    private static func plusObject(id: UInt8, type: UInt8, payload: [UInt8]) -> [UInt8] {
        plusRecord(0x4008, (UInt16(type) << 8) | UInt16(id), payload)
    }

    /// EmfPlusBrush solid (§2.2.1.1 / §2.2.2.43): Version, Type 0, SolidColor.
    private static func solidBrushPayload(_ argb: UInt32) -> [UInt8] {
        le { w in w.u32(plusVersion); w.u32(0); w.u32(argb) }
    }

    /// EmfPlusLinearGradientBrushData (§2.2.2.24): Version, Type 4, BrushDataFlags
    /// 0 (no transform/blend), WrapMode, RectF, StartColor, EndColor, Reserved×2.
    private static func linearGradientPayload(
        rect: (Float, Float, Float, Float), start: UInt32, end: UInt32, wrapMode: Int32
    ) -> [UInt8] {
        le { w in
            w.u32(plusVersion); w.u32(4)
            w.u32(0)
            w.i32(wrapMode)
            w.f32(rect.0); w.f32(rect.1); w.f32(rect.2); w.f32(rect.3)
            w.u32(start); w.u32(end)
            w.u32(0); w.u32(0)
        }
    }

    /// EmfPlusPen (§2.2.1.7 / §2.2.2.33): Version, Type 0, PenData (flags 0, unit
    /// 0, width — no optional blocks), then a solid BrushObject.
    private static func penPayload(width: Float, argb: UInt32) -> [UInt8] {
        le { w in
            w.u32(plusVersion); w.u32(0)            // Version, Type
            w.u32(0); w.u32(0); w.f32(width)        // PenDataFlags, PenUnit, PenWidth
            w.u32(plusVersion); w.u32(0); w.u32(argb)   // BrushObject (solid)
        }
    }

    /// EmfPlusPath (§2.2.1.6) with absolute 32-bit points (Flags 0): Version,
    /// PathPointCount, Flags, PointData (f32 pairs), PathPointTypes (1 byte each),
    /// padded to a 4-byte boundary.
    private static func pathPayload(points: [(Float, Float)], types: [UInt8]) -> [UInt8] {
        le { w in
            w.u32(plusVersion)
            w.u32(UInt32(points.count))
            w.u32(0)
            for point in points { w.f32(point.0); w.f32(point.1) }
            w.raw(types)
            let pad = (4 - (types.count % 4)) % 4
            w.zeros(pad)
        }
    }

    // MARK: - EMF+ drawing records ([MS-EMFPLUS] §2.3.4)

    /// EmfPlusFillPath (§2.3.4.17): Flags low byte = path ObjectId (S clear → the
    /// BrushId names an object-table brush). Data = BrushId.
    private static func fillPath(pathId: UInt8, brushId: UInt32) -> [UInt8] {
        plusRecord(0x4014, UInt16(pathId), le { $0.u32(brushId) })
    }

    /// EmfPlusDrawPath (§2.3.4.8): Flags low byte = path ObjectId; Data = PenId.
    private static func drawPath(pathId: UInt8, penId: UInt32) -> [UInt8] {
        plusRecord(0x4015, UInt16(pathId), le { $0.u32(penId) })
    }

    /// EmfPlusFillRects (§2.3.4.20) with the S flag (direct ARGB colour) and one
    /// RectF: Data = BrushId(=ARGB), Count, RectF.
    private static func fillRectsDirect(color: UInt32, rect: (Float, Float, Float, Float)) -> [UInt8] {
        plusRecord(0x400A, 0x8000, le { w in
            w.u32(color); w.u32(1)
            w.f32(rect.0); w.f32(rect.1); w.f32(rect.2); w.f32(rect.3)
        })
    }

    /// EmfPlusFillEllipse (§2.3.4.16): Data = BrushId (object brush, S clear),
    /// RectData (RectF, C clear).
    private static func fillEllipse(brushId: UInt32, rect: (Float, Float, Float, Float)) -> [UInt8] {
        plusRecord(0x400E, 0x0000, le { w in
            w.u32(brushId)
            w.f32(rect.0); w.f32(rect.1); w.f32(rect.2); w.f32(rect.3)
        })
    }

    /// EmfPlusDrawLines (§2.3.4.10) with the C flag (i16 EmfPlusPoint) and no L
    /// (open): Flags low byte = pen ObjectId; Data = Count, then i16 point pairs.
    private static func drawLinesI16(penId: UInt8, points: [(Int16, Int16)]) -> [UInt8] {
        plusRecord(0x400D, UInt16(penId) | 0x4000, le { w in
            w.u32(UInt32(points.count))
            for point in points { w.i16(point.0); w.i16(point.1) }
        })
    }

    // MARK: - EMF+ images ([MS-EMFPLUS] §2.2.2.2, §2.3.4.8, §2.3.4.9)

    /// EmfPlusImage bitmap object (§2.2.1.4 / §2.2.2.2): Version, Type
    /// (ImageDataTypeBitmap 1), then the EmfPlusBitmap — Width, Height, Stride,
    /// PixelFormat (32bpp ARGB, 0x0026200A), Type (BitmapDataTypePixel 0), and
    /// the PixelData. The 8×8 image has four solid quadrants (top-down): red
    /// (top-left), green (top-right), blue (bottom-left), white (bottom-right).
    private static func bitmapImagePayload() -> [UInt8] {
        le { w in
            w.u32(plusVersion)     // Version
            w.u32(1)               // Type = ImageDataTypeBitmap
            w.i32(8)               // Width
            w.i32(8)               // Height
            w.i32(32)              // Stride (8 px × 4 bytes)
            w.u32(0x0026_200A)     // PixelFormat = 32bpp ARGB
            w.u32(0)               // Type = BitmapDataTypePixel
            // PixelData, top-down; each pixel is B, G, R, A (a little-endian
            // 0xAARRGGBB DWORD, [MS-EMFPLUS] §2.1.1.24 32bppARGB).
            for row in 0 ..< 8 {
                for col in 0 ..< 8 {
                    let (r, g, b): (UInt8, UInt8, UInt8)
                    switch (row < 4, col < 4) {
                    case (true, true):   (r, g, b) = (255, 0, 0)        // red
                    case (true, false):  (r, g, b) = (0, 255, 0)        // green
                    case (false, true):  (r, g, b) = (0, 0, 255)        // blue
                    case (false, false): (r, g, b) = (255, 255, 255)    // white
                    }
                    w.raw([b, g, r, 255])
                }
            }
        }
    }

    /// EmfPlusDrawImage (§2.3.4.8), C flag clear (RectData is an EmfPlusRectF):
    /// Flags low byte = image ObjectID; Data = ImageAttributesID (0), SrcUnit
    /// (UnitTypePixel 2), SrcRect (EmfPlusRectF), dest RectData (EmfPlusRectF).
    private static func drawImage(
        imageId: UInt8,
        src: (Float, Float, Float, Float),
        dest: (Float, Float, Float, Float)
    ) -> [UInt8] {
        plusRecord(0x401A, UInt16(imageId), le { w in
            w.u32(0)               // ImageAttributesID
            w.i32(2)               // SrcUnit = UnitTypePixel
            w.f32(src.0); w.f32(src.1); w.f32(src.2); w.f32(src.3)
            w.f32(dest.0); w.f32(dest.1); w.f32(dest.2); w.f32(dest.3)
        })
    }

    /// EmfPlusDrawImagePoints (§2.3.4.9), C and P clear (absolute EmfPlusPointF):
    /// Flags low byte = image ObjectID; Data = ImageAttributesID (0), SrcUnit
    /// (UnitTypePixel 2), SrcRect (EmfPlusRectF), Count (3), then the upper-left,
    /// upper-right, and lower-left corners of the destination parallelogram.
    private static func drawImagePoints(
        imageId: UInt8,
        src: (Float, Float, Float, Float),
        points: [(Float, Float)]
    ) -> [UInt8] {
        plusRecord(0x401B, UInt16(imageId), le { w in
            w.u32(0)               // ImageAttributesID
            w.i32(2)               // SrcUnit = UnitTypePixel
            w.f32(src.0); w.f32(src.1); w.f32(src.2); w.f32(src.3)
            w.u32(UInt32(points.count))
            for point in points { w.f32(point.0); w.f32(point.1) }
        })
    }

    // MARK: - EMF+ state records

    /// EmfPlusTranslateWorldTransform (§2.3.9.8), A flag clear (pre-multiply).
    private static func translateWorld(_ dx: Float, _ dy: Float) -> [UInt8] {
        plusRecord(0x402D, 0x0000, le { $0.f32(dx); $0.f32(dy) })
    }

    /// EmfPlusSetClipRect (§2.3.1.4) with CombineMode Intersect (1) in bits 8-11.
    private static func setClipRectIntersect(rect: (Float, Float, Float, Float)) -> [UInt8] {
        plusRecord(0x4032, UInt16(1) << 8, le { w in
            w.f32(rect.0); w.f32(rect.1); w.f32(rect.2); w.f32(rect.3)
        })
    }

    // MARK: - GDI records (the dual file's fallback, types per [MS-EMF] §2.1.1)

    /// EMR_CREATEBRUSHINDIRECT §2.3.7.1 (LogBrushEx §2.2.12): ihBrush, BS_SOLID,
    /// ColorRef, BrushHatch.
    private static func createSolidBrush(index: UInt32, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var body = LE()
        body.u32(index)
        body.u32(0)             // BS_SOLID
        body.color(r, g, b)
        body.u32(0)             // BrushHatch
        return record(type: 39, body: body.bytes)
    }

    /// EMR_SELECTOBJECT §2.3.8.5 — a table index or a 0x8000_00xx stock value.
    private static func selectObject(_ raw: UInt32) -> [UInt8] {
        record(type: 37, body: le { $0.u32(raw) })
    }

    /// EMR_RECTANGLE §2.3.5.34 — an inclusive-inclusive Box RectL.
    private static func rectangle(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] {
        record(type: 43, body: le { w in w.i32(l); w.i32(t); w.i32(r); w.i32(b) })
    }

    // MARK: - Writer sugar

    private static func le(_ build: (inout LE) -> Void) -> [UInt8] {
        var writer = LE()
        build(&writer)
        return writer.bytes
    }
}
