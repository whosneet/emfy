import CoreGraphics
import Foundation
import Testing
import EMFParse
import EMFRender
import EMFWrite

/// Renders a from-scratch dual file and reads pixels back, proving the writer
/// produces files EMFRender draws — in EMF+ mode (default) AND in GDI-fallback
/// mode (`RenderOptions(emfPlusArbitration: .gdi)`). Assertions sample pixels
/// with a per-channel tolerance; no committed PNG baselines are needed, because
/// the from-scratch content is known exactly.
@Suite("EMF+ dual builder render")
struct EMFPlusDualRenderTests {

    static let side = 100

    /// An opaque straight-RGBA8 render of `file` on a white background. Byte order
    /// is R,G,B,A; buffer row 0 is the context's bottom row (the renderer applies
    /// its own canvas y-flip, so centre/symmetric samples are orientation-stable).
    static func renderRGBA(_ file: EMFFile, options: RenderOptions) -> [UInt8]? {
        let w = side, h = side
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            _ = EMFRenderer.render(file, into: ctx, target: CGRect(x: 0, y: 0, width: w, height: h), options: options)
            return true
        }
        return ok ? buffer : nil
    }

    /// The RGBA at buffer pixel (x, y).
    static func pixel(_ buffer: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let o = (y * side + x) * 4
        return (Int(buffer[o]), Int(buffer[o + 1]), Int(buffer[o + 2]), Int(buffer[o + 3]))
    }

    static func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ r: Int, _ g: Int, _ b: Int, tol: Int = 20) -> Bool {
        abs(p.r - r) <= tol && abs(p.g - g) <= tol && abs(p.b - b) <= tol
    }

    static func countNonWhite(_ buffer: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: buffer.count, by: 4) where buffer[i] < 240 || buffer[i + 1] < 240 || buffer[i + 2] < 240 {
            n += 1
        }
        return n
    }

    /// Non-white pixels inside the buffer rectangle [x0,x1) × [y0,y1) — lets a
    /// test assert ink lands at a known destination rect (and nowhere else).
    static func countNonWhite(in buffer: [UInt8], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        var n = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let o = (y * side + x) * 4
                if buffer[o] < 240 || buffer[o + 1] < 240 || buffer[o + 2] < 240 { n += 1 }
            }
        }
        return n
    }

    /// A 100×100 dual builder: bounds (0,0)-(99,99), device 100×100.
    static func builder() -> EMFPlusDualDocumentBuilder {
        EMFPlusDualDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 99, bottom: 99),
            frame: RectL(left: 0, top: 0, right: 2645, bottom: 2645),
            device: SizeL(cx: 100, cy: 100),
            millimeters: SizeL(cx: 26, cy: 26))
    }

    static let rectFull = EMFPlusRectF(x: 0, y: 0, width: 100, height: 100)
    static func argb(_ a: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> EMFPlusARGB {
        EMFPlusARGB(blue: b, green: g, red: r, alpha: a)
    }

    /// Opaque red EMF+ fill vs opaque blue GDI fallback: EMF+ mode shows red, the
    /// `.gdi` arbitration shows blue. Proves the dual file renders both ways.
    @Test func solidArbitration() throws {
        let b = Self.builder()
        b.appendPlus(.fillRects(brush: .color(Self.argb(255, 220, 0, 0)), rects: [Self.rectFull]))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        #expect(file.emfPlusIsDual())
        let plusImage = try #require(Self.renderRGBA(file, options: .default))
        let gdiImage = try #require(Self.renderRGBA(file, options: RenderOptions(emfPlusArbitration: .gdi)))
        #expect(Self.near(Self.pixel(plusImage, 50, 50), 220, 0, 0), "EMF+ mode centre not red: \(Self.pixel(plusImage, 50, 50))")
        #expect(Self.near(Self.pixel(gdiImage, 50, 50), 0, 0, 220), "GDI mode centre not blue: \(Self.pixel(gdiImage, 50, 50))")
    }

    /// A semi-transparent EMF+ fill blends over the white page (alpha ≈ 0.5 black
    /// → mid-grey). The GDI fallback stays opaque blue.
    @Test func alphaFill() throws {
        let b = Self.builder()
        b.appendPlus(.fillRects(brush: .color(Self.argb(128, 0, 0, 0)), rects: [Self.rectFull]))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        let plusImage = try #require(Self.renderRGBA(file, options: .default))
        let c = Self.pixel(plusImage, 50, 50)
        #expect((100 ... 160).contains(c.r) && (100 ... 160).contains(c.g) && (100 ... 160).contains(c.b),
                "alpha blend centre not mid-grey: \(c)")
        let gdiImage = try #require(Self.renderRGBA(file, options: RenderOptions(emfPlusArbitration: .gdi)))
        #expect(Self.near(Self.pixel(gdiImage, 50, 50), 0, 0, 220), "GDI centre not blue: \(Self.pixel(gdiImage, 50, 50))")
    }

    /// A horizontal EMF+ linear gradient (red→blue) over the canvas: the left is
    /// red-dominant, the right blue-dominant.
    @Test func linearGradient() throws {
        let b = Self.builder()
        let brush = EMFPlusBrush(
            version: 1, brushType: .linearGradient,
            data: .linearGradient(EMFPlusLinearGradientBrush(
                brushDataFlags: 0, wrapMode: 4,   // Clamp
                rect: EMFPlusRectF(x: 0, y: 0, width: 100, height: 100),
                startColor: Self.argb(255, 230, 0, 0), endColor: Self.argb(255, 0, 0, 230),
                reserved1: 0, reserved2: 0, transform: nil, blend: nil)))
        let brushID = try b.addObject(.brush(brush))
        b.appendPlus(.fillRects(brush: .object(brushID), rects: [Self.rectFull]))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        let image = try #require(Self.renderRGBA(file, options: .default))
        let left = Self.pixel(image, 8, 50)
        let right = Self.pixel(image, 92, 50)
        #expect(left.r > left.b + 60, "gradient left not red-dominant: \(left)")
        #expect(right.b > right.r + 60, "gradient right not blue-dominant: \(right)")
    }

    /// A green EMF+ stroked path (a thick horizontal line) drawn through a pen and
    /// path object: the line centre is green, a corner is the white page.
    @Test func strokedPath() throws {
        let b = Self.builder()
        let pen = EMFPlusPen(
            version: 1, type: 0,
            penData: EMFPlusPenData(
                flags: 0, unit: 0, width: 8, transform: nil, startCap: nil, endCap: nil, join: nil,
                miterLimit: nil, lineStyle: nil, dashedLineCap: nil, dashOffset: nil, dashedLine: nil,
                penAlignment: nil, compoundLine: nil, customStartCap: nil, customEndCap: nil),
            brush: EMFPlusBrush(version: 1, brushType: .solid, data: .solid(Self.argb(255, 0, 180, 0))))
        let path = EMFPlusPath(
            version: 1, pointCount: 2, flags: 0,
            points: [EMFPlusPointF(x: 10, y: 50), EMFPlusPointF(x: 90, y: 50)],
            pointTypes: [0x00, 0x01])
        let penID = try b.addObject(.pen(pen))
        let pathID = try b.addObject(.path(path))
        b.appendPlus(.drawPath(pathID: pathID, penID: UInt32(penID)))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        let image = try #require(Self.renderRGBA(file, options: .default))
        #expect(Self.near(Self.pixel(image, 50, 50), 0, 180, 0, tol: 40), "stroke centre not green: \(Self.pixel(image, 50, 50))")
        #expect(Self.near(Self.pixel(image, 5, 5), 255, 255, 255), "corner not white page: \(Self.pixel(image, 5, 5))")
    }

    /// EMF+ DrawString draws glyph pixels; the GDI fallback fills blue. EMF+ mode
    /// has dark text pixels on white; GDI mode is blue with none.
    @Test func text() throws {
        let b = Self.builder()
        let font = EMFPlusFont(version: 1, emSize: 36, sizeUnit: 2 /* Pixel */, styleFlags: 0, familyName: "Helvetica")
        let brush = EMFPlusBrush(version: 1, brushType: .solid, data: .solid(Self.argb(255, 0, 0, 0)))
        let fontID = try b.addObject(.font(font))
        _ = try b.addObject(.brush(brush))   // an object the drawing could reference
        b.appendPlus(.drawString(
            fontID: fontID, brush: .color(Self.argb(255, 0, 0, 0)), formatID: 0xFFFF_FFFF,
            layoutRect: EMFPlusRectF(x: 5, y: 30, width: 90, height: 40), text: "Hi"))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        let plusImage = try #require(Self.renderRGBA(file, options: .default))
        var dark = 0
        for i in stride(from: 0, to: plusImage.count, by: 4) where plusImage[i] < 80 && plusImage[i + 1] < 80 && plusImage[i + 2] < 80 {
            dark += 1
        }
        #expect(dark > 10, "EMF+ text produced \(dark) dark pixels (expected glyphs)")
        let gdiImage = try #require(Self.renderRGBA(file, options: RenderOptions(emfPlusArbitration: .gdi)))
        #expect(Self.near(Self.pixel(gdiImage, 50, 50), 0, 0, 220), "GDI centre not blue: \(Self.pixel(gdiImage, 50, 50))")
    }

    /// A real EMF+ image object (lifted from the committed handmade file, decoded,
    /// then rebuilt through the object encoder) draws into its DESTINATION RECT and
    /// nowhere else. `imageAttributesID` is `nil` (no attributes) — it encodes the
    /// `noImageAttributes` sentinel ([MS-EMFPLUS] §2.3.4.8 / §3.1.2 object ids
    /// 0…63), not a 0 that would collide with slot 0 and make type-unchecked readers
    /// drop the image.
    @Test func image() throws {
        let corpus = try EMFFile.parse(try corpusData("handmade-emfplus-image.emf"))
        let (definitions, _) = corpus.emfPlusStream().objectDefinitions()
        let imageValue = try #require(definitions.compactMap { definition -> EMFPlusObjectValue? in
            if case .image = definition.decodedValue() { return definition.decodedValue() }
            return nil
        }.first, "no image object in the committed file")

        let b = Self.builder()
        let imageID = try b.addObject(imageValue)
        // Destination rect (25,25)-(75,75): a 50×50 box centred in the 100×100 canvas.
        b.appendPlus(.drawImage(
            imageID: imageID, imageAttributesID: nil, srcUnit: 2 /* Pixel */,
            srcRect: EMFPlusRectF(x: 0, y: 0, width: 8, height: 8),
            destRect: EMFPlusRectF(x: 25, y: 25, width: 50, height: 50)))
        try appendBlueGDIFill(b)
        let file = try EMFFile.parse(try b.finish())

        let image = try #require(Self.renderRGBA(file, options: .default))
        // Image pixels land INSIDE the destination rect (buffer y matches device y
        // here because the rect is vertically symmetric about the canvas centre)…
        let insideInk = Self.countNonWhite(in: image, 28, 28, 72, 72)
        #expect(insideInk > 100, "expected image pixels inside the destination rect, got \(insideInk)")
        // …and the page OUTSIDE it stays white — the GDI fallback must not draw in
        // EMF+ mode, so the corners are the untouched white page.
        let cornerInk = Self.countNonWhite(in: image, 0, 0, 18, 18)
        #expect(cornerInk == 0, "expected white page outside the destination rect, got \(cornerInk)")
    }

    // MARK: - Shared GDI fallback

    /// A blue GDI fallback filling the canvas: NULL_PEN (no outline) + a blue brush
    /// + EMR_RECTANGLE. Drawn outside any GetDC window, so EMF+ mode ignores it.
    private func appendBlueGDIFill(_ b: EMFPlusDualDocumentBuilder) throws {
        try b.appendGDIFallback(.selectObject(.stock(.nullPen)))
        try b.appendGDIFallback(.createBrushIndirect(
            CreateBrushPayload(ihBrush: 1, style: 0 /* BS_SOLID */, color: ColorRef(red: 0, green: 0, blue: 220), hatch: 0)))
        try b.appendGDIFallback(.selectObject(.table(index: 1)))
        try b.appendGDIFallback(.rectangle(box: RectL(left: 0, top: 0, right: 100, bottom: 100)))
    }
}
