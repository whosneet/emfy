import Foundation
@testable import EMFParse

/// Hand-builds complete little-endian EMF byte streams for renderer tests:
/// a 108-byte extension2 header, the appended records, and a trailing
/// EMR_EOF, with the advisory Bytes/Records fields set consistently.
///
/// This intentionally duplicates the tiny byte-writing core of
/// EMFParseTests' FixtureBuilder — SPM test targets cannot share sources,
/// and the two targets exercise different layers (decode vs playback).
struct RenderFixture {

    /// Little-endian byte writer.
    struct LE {
        private(set) var bytes: [UInt8] = []

        mutating func u32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }

        mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

        mutating func i16(_ value: Int16) {
            let raw = UInt16(bitPattern: value)
            bytes.append(UInt8(raw & 0xFF))
            bytes.append(UInt8((raw >> 8) & 0xFF))
        }

        mutating func u16(_ value: UInt16) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
        }

        mutating func f32(_ value: Float) { u32(value.bitPattern) }

        /// ColorRef on-disk order: Red, Green, Blue, Reserved
        /// ([MS-WMF] §2.2.2.8).
        mutating func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            bytes.append(contentsOf: [r, g, b, 0])
        }

        mutating func raw(_ raw: [UInt8]) {
            bytes.append(contentsOf: raw)
        }
    }

    /// Header `rclBounds` (inclusive-inclusive device space).
    var bounds: (left: Int32, top: Int32, right: Int32, bottom: Int32) = (0, 0, 99, 99)
    /// Header reference-device metrics (drive the fixed metric map modes).
    var device: (cx: Int32, cy: Int32) = (1000, 1000)
    var millimeters: (cx: Int32, cy: Int32) = (250, 250)

    private var records: [[UInt8]] = []

    // MARK: - Generic record

    mutating func append(type: UInt32, payload: [UInt8]) {
        var writer = LE()
        writer.u32(type)
        writer.u32(UInt32(8 + payload.count))
        writer.raw(payload)
        records.append(writer.bytes)
    }

    // MARK: - Typed records (types per [MS-EMF] §2.1.1)

    mutating func setMapMode(_ raw: UInt32) {
        var body = LE(); body.u32(raw)
        append(type: 17, payload: body.bytes)
    }

    mutating func setWindowExtEx(_ cx: Int32, _ cy: Int32) {
        var body = LE(); body.i32(cx); body.i32(cy)
        append(type: 9, payload: body.bytes)
    }

    mutating func setViewportExtEx(_ cx: Int32, _ cy: Int32) {
        var body = LE(); body.i32(cx); body.i32(cy)
        append(type: 11, payload: body.bytes)
    }

    mutating func setPolyFillMode(_ raw: UInt32) {
        var body = LE(); body.u32(raw)
        append(type: 19, payload: body.bytes)
    }

    mutating func setROP2(_ raw: UInt32) {
        var body = LE(); body.u32(raw)
        append(type: 20, payload: body.bytes)
    }

    mutating func setBkMode(_ raw: UInt32) {
        var body = LE(); body.u32(raw)
        append(type: 18, payload: body.bytes)
    }

    /// EMR_SETWORLDTRANSFORM §2.3.12.2 — six FLOATs M11,M12,M21,M22,Dx,Dy.
    mutating func setWorldTransform(
        _ m11: Float, _ m12: Float, _ m21: Float, _ m22: Float, _ dx: Float, _ dy: Float
    ) {
        var body = LE()
        for value in [m11, m12, m21, m22, dx, dy] {
            body.u32(value.bitPattern)
        }
        append(type: 35, payload: body.bytes)
    }

    // MARK: - Clipping / path bracket records

    mutating func saveDC() { append(type: 33, payload: []) }

    mutating func restoreDC(_ savedDC: Int32) {
        var body = LE(); body.i32(savedDC)
        append(type: 34, payload: body.bytes)
    }

    /// EMR_INTERSECTCLIPRECT §2.3.2.3 — a Clip RectL in logical units.
    mutating func intersectClipRect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        var body = LE(); body.i32(l); body.i32(t); body.i32(r); body.i32(b)
        append(type: 30, payload: body.bytes)
    }

    mutating func beginPath() { append(type: 59, payload: []) }
    mutating func endPath() { append(type: 60, payload: []) }
    mutating func closeFigure() { append(type: 61, payload: []) }

    /// A RectL bounds body shared by the FILL/STROKE closers.
    private static func rectBody(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) -> [UInt8] {
        var body = LE(); body.i32(l); body.i32(t); body.i32(r); body.i32(b)
        return body.bytes
    }

    /// EMR_FILLPATH §2.3.5.9 — Bounds (advisory).
    mutating func fillPath(_ l: Int32 = 0, _ t: Int32 = 0, _ r: Int32 = 0, _ b: Int32 = 0) {
        append(type: 62, payload: Self.rectBody(l, t, r, b))
    }

    /// EMR_STROKEANDFILLPATH §2.3.5.38 — Bounds (advisory).
    mutating func strokeAndFillPath(_ l: Int32 = 0, _ t: Int32 = 0, _ r: Int32 = 0, _ b: Int32 = 0) {
        append(type: 63, payload: Self.rectBody(l, t, r, b))
    }

    /// EMR_STROKEPATH §2.3.5.39 — Bounds (advisory).
    mutating func strokePath(_ l: Int32 = 0, _ t: Int32 = 0, _ r: Int32 = 0, _ b: Int32 = 0) {
        append(type: 64, payload: Self.rectBody(l, t, r, b))
    }

    /// EMR_SELECTCLIPPATH §2.3.2.5 — a RegionMode.
    mutating func selectClipPath(_ regionMode: UInt32) {
        var body = LE(); body.u32(regionMode)
        append(type: 67, payload: body.bytes)
    }

    /// EMR_EXTSELECTCLIPRGN §2.3.2.2. Builds the RegionData object (§2.2.24)
    /// from `rects` (logical units), or the RGN_COPY reset form when `rects`
    /// is empty (RgnDataSize 0, no region data).
    mutating func extSelectClipRgn(
        mode: UInt32,
        rects: [(l: Int32, t: Int32, r: Int32, b: Int32)]
    ) {
        var body = LE()
        if rects.isEmpty {
            body.u32(0)              // RgnDataSize
            body.u32(mode)           // RegionMode (RGN_COPY reset expected)
            append(type: 75, payload: body.bytes)
            return
        }
        // RegionDataHeader (32 bytes) + CountRects × RectL (16 bytes each).
        let rgnDataSize = UInt32(32 + rects.count * 16)
        body.u32(rgnDataSize)        // RgnDataSize
        body.u32(mode)               // RegionMode
        // RegionDataHeader §2.2.25.
        body.u32(0x20)               // Size (MUST be 0x20)
        body.u32(0x01)               // Type (RDH_RECTANGLES)
        body.u32(UInt32(rects.count))// CountRects
        body.u32(UInt32(rects.count * 16)) // RgnSize (advisory)
        // Bounds: the union of the rects.
        let ls = rects.map(\.l), ts = rects.map(\.t), rs = rects.map(\.r), bs = rects.map(\.b)
        body.i32(ls.min() ?? 0); body.i32(ts.min() ?? 0)
        body.i32(rs.max() ?? 0); body.i32(bs.max() ?? 0)
        for rect in rects {
            body.i32(rect.l); body.i32(rect.t); body.i32(rect.r); body.i32(rect.b)
        }
        append(type: 75, payload: body.bytes)
    }

    // MARK: - More geometry

    mutating func polyline16(_ points: [(Int16, Int16)]) {
        append(type: 87, payload: Self.poly16Body(points))
    }

    /// EMR_RECTANGLE §2.3.5.34 — an inclusive-inclusive Box RectL.
    mutating func rectangle(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        append(type: 43, payload: Self.rectBody(l, t, r, b))
    }

    /// EMR_ELLIPSE §2.3.5.5 — an inclusive-inclusive Box RectL.
    mutating func ellipse(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        append(type: 42, payload: Self.rectBody(l, t, r, b))
    }

    /// EMR_CREATEBRUSHINDIRECT §2.3.7.1 (LogBrushEx §2.2.12).
    mutating func createSolidBrush(index: UInt32, r: UInt8, g: UInt8, b: UInt8) {
        var body = LE()
        body.u32(index)
        body.u32(0)             // BS_SOLID
        body.color(r, g, b)
        body.u32(0)             // BrushHatch
        append(type: 39, payload: body.bytes)
    }

    /// EMR_CREATEPEN §2.3.7.7 (LogPen §2.2.19): ihPen, PenStyle, Width PointL
    /// (only x used), ColorRef. `width` 0 → cosmetic one-device-pixel pen;
    /// `width` > 0 with PS_SOLID (style 0) → a geometric solid pen.
    mutating func createPen(index: UInt32, style: UInt32, width: Int32, r: UInt8, g: UInt8, b: UInt8) {
        var body = LE()
        body.u32(index)
        body.u32(style)
        body.i32(width); body.i32(0)   // Width PointL (y ignored)
        body.color(r, g, b)
        append(type: 38, payload: body.bytes)
    }

    /// EMR_SELECTOBJECT §2.3.8.5 — pass a table index or a 0x8000_00xx
    /// stock value.
    mutating func selectObject(_ raw: UInt32) {
        var body = LE(); body.u32(raw)
        append(type: 37, payload: body.bytes)
    }

    mutating func moveToEx(_ x: Int32, _ y: Int32) {
        var body = LE(); body.i32(x); body.i32(y)
        append(type: 27, payload: body.bytes)
    }

    mutating func lineTo(_ x: Int32, _ y: Int32) {
        var body = LE(); body.i32(x); body.i32(y)
        append(type: 54, payload: body.bytes)
    }

    /// The common 16-bit poly body: Bounds, Count, PointS array.
    private static func poly16Body(_ points: [(Int16, Int16)]) -> [UInt8] {
        var body = LE()
        let xs = points.map { Int32($0.0) }
        let ys = points.map { Int32($0.1) }
        body.i32(xs.min() ?? 0)
        body.i32(ys.min() ?? 0)
        body.i32(xs.max() ?? 0)
        body.i32(ys.max() ?? 0)
        body.u32(UInt32(points.count))
        for (x, y) in points {
            body.i16(x); body.i16(y)
        }
        return body.bytes
    }

    mutating func polygon16(_ points: [(Int16, Int16)]) {
        append(type: 86, payload: Self.poly16Body(points))
    }

    mutating func polyBezier16(_ points: [(Int16, Int16)]) {
        append(type: 85, payload: Self.poly16Body(points))
    }

    mutating func polyBezierTo16(_ points: [(Int16, Int16)]) {
        append(type: 88, payload: Self.poly16Body(points))
    }

    // MARK: - Phase-4 text records (types per [MS-EMF] §2.1.1)

    /// EMR_SETTEXTCOLOR §2.3.11.26 — a ColorRef.
    mutating func setTextColor(r: UInt8, g: UInt8, b: UInt8) {
        var body = LE(); body.color(r, g, b)
        append(type: 24, payload: body.bytes)
    }

    /// EMR_SETBKCOLOR §2.3.11.10 — a ColorRef.
    mutating func setBkColor(r: UInt8, g: UInt8, b: UInt8) {
        var body = LE(); body.color(r, g, b)
        append(type: 25, payload: body.bytes)
    }

    /// EMR_SETTEXTALIGN §2.3.11.25 — a TextAlignmentMode mask.
    mutating func setTextAlign(_ mask: UInt32) {
        var body = LE(); body.u32(mask)
        append(type: 22, payload: body.bytes)
    }

    /// A 92-byte LogFont ([MS-EMF] §2.2.13). `height` is signed.
    static func logFontBytes(
        height: Int32,
        weight: Int32 = 400,
        escapement: Int32 = 0,
        italic: UInt8 = 0,
        underline: UInt8 = 0,
        strikeOut: UInt8 = 0,
        faceName: String
    ) -> [UInt8] {
        var b = LE()
        b.i32(height)          // +0 Height
        b.i32(0)               // +4 Width
        b.i32(escapement)      // +8 Escapement
        b.i32(0)               // +12 Orientation
        b.i32(weight)          // +16 Weight
        b.raw([italic, underline, strikeOut, 0])   // +20 Italic/Underline/StrikeOut/CharSet
        b.raw([0, 0, 0, 0])    // +24 OutPrecision/ClipPrecision/Quality/PitchAndFamily
        var units = Array(faceName.utf16)          // +28 FaceName (64 bytes = 32 units)
        if units.count > 32 { units = Array(units.prefix(32)) }
        for unit in units { b.u16(unit) }
        let pad = 32 - units.count
        for _ in 0 ..< pad { b.u16(0) }
        return b.bytes
    }

    /// EMR_EXTCREATEFONTINDIRECTW §2.3.7.8 — ihFonts + a 92-byte LogFont.
    mutating func extCreateFontIndirectW(
        index: UInt32,
        height: Int32,
        weight: Int32 = 400,
        escapement: Int32 = 0,
        italic: UInt8 = 0,
        underline: UInt8 = 0,
        strikeOut: UInt8 = 0,
        faceName: String
    ) {
        var body = LE()
        body.u32(index)
        body.raw(Self.logFontBytes(
            height: height, weight: weight, escapement: escapement,
            italic: italic, underline: underline, strikeOut: strikeOut,
            faceName: faceName
        ))
        append(type: 82, payload: body.bytes)
    }

    /// EMR_EXTTEXTOUTW §2.3.5.8 with its EmrText object §2.2.5. The fixed EmrText
    /// fields occupy record offsets 36..76; the string is placed at offset 76,
    /// the optional Dx (32-bit aligned) immediately after.
    mutating func extTextOutW(
        reference: (x: Int32, y: Int32),
        string: String,
        options: UInt32 = 0,
        rectangle: (l: Int32, t: Int32, r: Int32, b: Int32) = (0, 0, 0, 0),
        dx: [UInt32]? = nil,
        graphicsMode: UInt32 = 1,
        exScale: Float = 1,
        eyScale: Float = 1
    ) {
        let units = Array(string.utf16)
        let offString = 76
        let stringBytes = units.count * 2
        let dxStart = (offString + stringBytes + 3) & ~3
        let hasDx = dx != nil

        var body = LE()                                  // record offset 8
        body.i32(0); body.i32(0); body.i32(0); body.i32(0)   // Bounds@8 (ignored)
        body.u32(graphicsMode)                           // iGraphicsMode@24
        body.f32(exScale)                                // exScale@28
        body.f32(eyScale)                                // eyScale@32
        body.i32(reference.x); body.i32(reference.y)     // Reference@36
        body.u32(UInt32(units.count))                    // Chars@44
        body.u32(UInt32(offString))                      // offString@48
        body.u32(options)                                // Options@52
        body.i32(rectangle.l); body.i32(rectangle.t)     // Rectangle@56
        body.i32(rectangle.r); body.i32(rectangle.b)
        body.u32(hasDx ? UInt32(dxStart) : 0)            // offDx@72
        // body length now 68 → record offset 76. String, then padded Dx.
        for unit in units { body.u16(unit) }
        if hasDx {
            let currentRecordOffset = 8 + body.bytes.count
            let pad = dxStart - currentRecordOffset
            if pad > 0 { body.raw([UInt8](repeating: 0, count: pad)) }
            for value in dx! { body.u32(value) }
        }
        // Records MUST be 4-aligned; pad the tail.
        let recordSize = 8 + body.bytes.count
        let alignPad = (4 - recordSize % 4) % 4
        if alignPad > 0 { body.raw([UInt8](repeating: 0, count: alignPad)) }
        append(type: 84, payload: body.bytes)
    }

    // MARK: - Phase-4 bitmap records

    /// A 40-byte BitmapInfoHeader ([MS-WMF] §2.2.2.3). `height` signed.
    static func bitmapInfoHeader(
        width: Int32, height: Int32, bitCount: UInt16,
        compression: UInt32 = 0, colorUsed: UInt32 = 0
    ) -> [UInt8] {
        var b = LE()
        b.u32(40)              // HeaderSize
        b.i32(width)
        b.i32(height)
        b.u16(1)               // Planes
        b.u16(bitCount)
        b.u32(compression)     // BI_RGB
        b.u32(0)               // ImageSize
        b.i32(2835); b.i32(2835)   // Pels/metre
        b.u32(colorUsed)
        b.u32(0)               // ColorImportant
        return b.bytes
    }

    /// EMR_STRETCHDIBITS §2.3.1.7. The 80-byte fixed part, then bmi, then bits.
    mutating func stretchDIBits(
        bounds: (l: Int32, t: Int32, r: Int32, b: Int32),
        dest: (x: Int32, y: Int32),
        destSize: (cx: Int32, cy: Int32),
        src: (x: Int32, y: Int32) = (0, 0),
        srcSize: (cx: Int32, cy: Int32),
        usageSrc: UInt32 = 0,
        rasterOperation: UInt32 = 0x00CC_0020,   // SRCCOPY
        bmi: [UInt8],
        bits: [UInt8]
    ) {
        let offBmi = 80
        let cbBmi = bmi.count
        let offBits = offBmi + cbBmi
        let cbBits = bits.count

        var body = LE()                              // record offset 8
        body.i32(bounds.l); body.i32(bounds.t); body.i32(bounds.r); body.i32(bounds.b) // Bounds@8
        body.i32(dest.x); body.i32(dest.y)           // xDest,yDest@24
        body.i32(src.x); body.i32(src.y)             // xSrc,ySrc@32
        body.i32(srcSize.cx); body.i32(srcSize.cy)   // cxSrc,cySrc@40
        body.u32(UInt32(offBmi))                     // offBmiSrc@48
        body.u32(UInt32(cbBmi))                      // cbBmiSrc@52
        body.u32(UInt32(offBits))                    // offBitsSrc@56
        body.u32(UInt32(cbBits))                     // cbBitsSrc@60
        body.u32(usageSrc)                           // UsageSrc@64
        body.u32(rasterOperation)                    // rop@68
        body.i32(destSize.cx); body.i32(destSize.cy) // cxDest,cyDest@72
        body.raw(bmi)
        body.raw(bits)
        append(type: 81, payload: body.bytes)
    }

    /// EMR_STRETCHDIBITS §2.3.1.7 — sourceless rop-only form (cbBmiSrc == 0),
    /// the 80-byte fixed part with no bitmap.
    mutating func stretchDIBitsSourceless(
        dest: (x: Int32, y: Int32),
        destSize: (cx: Int32, cy: Int32),
        rasterOperation: UInt32
    ) {
        var body = LE()                              // record offset 8
        body.i32(0); body.i32(0); body.i32(0); body.i32(0)  // Bounds@8
        body.i32(dest.x); body.i32(dest.y)           // xDest,yDest@24
        body.i32(0); body.i32(0)                     // xSrc,ySrc@32
        body.i32(0); body.i32(0)                     // cxSrc,cySrc@40
        body.u32(0)                                  // offBmiSrc@48
        body.u32(0)                                  // cbBmiSrc@52 == 0 → sourceless
        body.u32(0)                                  // offBitsSrc@56
        body.u32(0)                                  // cbBitsSrc@60
        body.u32(0)                                  // UsageSrc@64
        body.u32(rasterOperation)                    // rop@68
        body.i32(destSize.cx); body.i32(destSize.cy) // cxDest,cyDest@72
        append(type: 81, payload: body.bytes)
    }

    /// EMR_SETDIBITSTODEVICE §2.3.1.5 — sourceless form (cbBmiSrc == 0), the
    /// 76-byte fixed part with no bitmap and no raster op.
    mutating func setDIBitsToDeviceSourceless(
        dest: (x: Int32, y: Int32),
        srcSize: (cx: Int32, cy: Int32)
    ) {
        var body = LE()                              // record offset 8
        body.i32(0); body.i32(0); body.i32(0); body.i32(0)  // Bounds@8
        body.i32(dest.x); body.i32(dest.y)           // xDest,yDest@24
        body.i32(0); body.i32(0)                     // xSrc,ySrc@32
        body.i32(srcSize.cx); body.i32(srcSize.cy)   // cxSrc,cySrc@40
        body.u32(0)                                  // offBmiSrc@48
        body.u32(0)                                  // cbBmiSrc@52 == 0 → sourceless
        body.u32(0)                                  // offBitsSrc@56
        body.u32(0)                                  // cbBitsSrc@60
        body.u32(0)                                  // UsageSrc@64
        body.u32(0)                                  // iStartScan@68
        body.u32(0)                                  // cScans@72
        append(type: 80, payload: body.bytes)
    }

    /// EMR_BITBLT §2.3.1.2 — sourceless rop-only form (cbBmiSrc == 0).
    mutating func bitBltSourceless(
        dest: (x: Int32, y: Int32),
        destSize: (cx: Int32, cy: Int32),
        rasterOperation: UInt32
    ) {
        var body = LE()                              // record offset 8
        body.i32(0); body.i32(0); body.i32(0); body.i32(0)  // Bounds@8
        body.i32(dest.x); body.i32(dest.y)           // xDest,yDest@24
        body.i32(destSize.cx); body.i32(destSize.cy) // cxDest,cyDest@32
        body.u32(rasterOperation)                    // rop@40
        body.i32(0); body.i32(0)                     // xSrc,ySrc@44
        body.f32(1); body.f32(0); body.f32(0); body.f32(1); body.f32(0); body.f32(0) // XformSrc@52
        body.color(0, 0, 0)                          // BkColorSrc@76
        body.u32(0)                                  // UsageSrc@80
        body.u32(0)                                  // offBmiSrc@84
        body.u32(0)                                  // cbBmiSrc@88 == 0 → sourceless
        body.u32(0)                                  // offBitsSrc@92
        body.u32(0)                                  // cbBitsSrc@96
        append(type: 76, payload: body.bytes)
    }

    // MARK: - Assembly

    /// The complete file: header + records + EOF.
    func data() -> Data {
        var header = LE()
        let recordBytes = records.reduce(0) { $0 + $1.count }
        let totalBytes = UInt32(108 + recordBytes + 20)
        let totalRecords = UInt32(1 + records.count + 1)

        header.u32(1)                    // 0   iType = EMR_HEADER
        header.u32(108)                  // 4   nSize (extension2 fixed part)
        header.i32(bounds.left)          // 8   rclBounds
        header.i32(bounds.top)
        header.i32(bounds.right)
        header.i32(bounds.bottom)
        header.i32(0)                    // 24  rclFrame (unused by makeImage)
        header.i32(0)
        header.i32(2646)
        header.i32(2646)
        header.u32(0x464D_4520)          // 40  RecordSignature " EMF"
        header.u32(0x0001_0000)          // 44  Version
        header.u32(totalBytes)           // 48  Bytes (advisory, set true)
        header.u32(totalRecords)         // 52  Records (advisory, set true)
        header.i16(8)                    // 56  Handles
        header.i16(0)                    // 58  Reserved
        header.u32(0)                    // 60  nDescription
        header.u32(0)                    // 64  offDescription
        header.u32(0)                    // 68  nPalEntries
        header.i32(device.cx)            // 72  Device
        header.i32(device.cy)
        header.i32(millimeters.cx)       // 80  Millimeters
        header.i32(millimeters.cy)
        header.u32(0)                    // 88  cbPixelFormat
        header.u32(0)                    // 92  offPixelFormat
        header.u32(0)                    // 96  bOpenGL
        header.u32(0)                    // 100 MicrometersX
        header.u32(0)                    // 104 MicrometersY

        var eof = LE()
        eof.u32(14)                      // EMR_EOF
        eof.u32(20)
        eof.u32(0)                       // nPalEntries
        eof.u32(16)                      // offPalEntries
        eof.u32(20)                      // SizeLast

        var all = header.bytes
        for record in records { all.append(contentsOf: record) }
        all.append(contentsOf: eof.bytes)
        return Data(all)
    }

    /// Parses the assembled bytes.
    func parsed() throws(EMFParseError) -> EMFFile {
        try EMFFile.parse(data())
    }
}
