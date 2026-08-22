import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - EMF+ text fixture builders
//
// Hand-builds EMF+ DrawString/DrawDriverString records (and the font/format/brush
// objects they reference) so the renderer takes the EMF+ text path. Each record
// is Type(u16)/Flags(u16)/Size(u32)/DataSize(u32) then 4-aligned data.

private let textPlusVersion: UInt32 = 0xDBC0_1002

private func tle(_ build: (inout RenderFixture.LE) -> Void) -> [UInt8] {
    var writer = RenderFixture.LE()
    build(&writer)
    return writer.bytes
}

/// Pads `bytes` with trailing zeros to a 4-byte boundary (EMF+ records are
/// 32-bit-aligned; the decoders ignore trailing AlignmentPadding).
private func pad4(_ bytes: [UInt8]) -> [UInt8] {
    var out = bytes
    let extra = (4 - out.count % 4) % 4
    out.append(contentsOf: repeatElement(0, count: extra))
    return out
}

private func tPlusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8] = []) -> [UInt8] {
    tle { writer in
        writer.u16(type)
        writer.u16(flags)
        writer.u32(UInt32(12 + data.count))
        writer.u32(UInt32(data.count))
        writer.raw(data)
    }
}

private func tPlusHeader() -> [UInt8] {
    tPlusRecord(0x4001, 0x0001, tle { $0.u32(textPlusVersion); $0.u32(0); $0.u32(96); $0.u32(96) })
}

private func tPlusObject(id: UInt8, type: UInt8, payload: [UInt8]) -> [UInt8] {
    tPlusRecord(0x4008, (UInt16(type) << 8) | UInt16(id), payload)
}

private func tArgb(_ a: UInt8, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
}

private func tSolidBrush(_ argb: UInt32) -> [UInt8] {
    tle { $0.u32(textPlusVersion); $0.u32(0); $0.u32(argb) }
}

/// EmfPlusFont object payload ([MS-EMFPLUS] §2.2.1.3): Version, EmSize (f32),
/// SizeUnit, FontStyleFlags (i32), Reserved, Length (chars), FamilyName (UTF-16LE),
/// padded to a 4-byte boundary.
private func tFont(emSize: Float, sizeUnit: UInt32 = 0, style: Int32 = 0, family: String) -> [UInt8] {
    let units = Array(family.utf16)
    return pad4(tle { writer in
        writer.u32(textPlusVersion)
        writer.f32(emSize)
        writer.u32(sizeUnit)
        writer.i32(style)
        writer.u32(0)                    // Reserved
        writer.u32(UInt32(units.count))  // Length (characters)
        for unit in units { writer.u16(unit) }
    })
}

/// EmfPlusStringFormat object payload ([MS-EMFPLUS] §2.2.1.9), fifteen fixed
/// fields with no tab stops or character ranges by default.
private func tStringFormat(
    stringAlignment: UInt32 = 0, lineAlign: UInt32 = 0,
    flags: UInt32 = 0, trimming: UInt32 = 0, hotkeyPrefix: Int32 = 0,
    tabStops: [Float] = [], ranges: [(Int32, Int32)] = []
) -> [UInt8] {
    tle { writer in
        writer.u32(textPlusVersion)          // Version
        writer.u32(flags)                    // StringFormatFlags
        writer.u32(0)                        // Language
        writer.u32(stringAlignment)          // StringAlignment
        writer.u32(lineAlign)                // LineAlign
        writer.u32(0)                        // DigitSubstitution
        writer.u32(0)                        // DigitLanguage
        writer.f32(0)                        // FirstTabOffset
        writer.i32(hotkeyPrefix)             // HotkeyPrefix
        writer.f32(0)                        // LeadingMargin
        writer.f32(0)                        // TrailingMargin
        writer.f32(0)                        // Tracking
        writer.u32(trimming)                 // Trimming
        writer.i32(Int32(tabStops.count))    // TabStopCount
        writer.i32(Int32(ranges.count))      // RangeCount
        for stop in tabStops { writer.f32(stop) }
        for range in ranges { writer.i32(range.0); writer.i32(range.1) }
    }
}

/// EmfPlusDrawString record ([MS-EMFPLUS] §2.3.4.14). `sBit` set → BrushId is a
/// direct ARGB colour; clear → an object-table brush index.
private func tDrawString(
    fontID: UInt8, sBit: Bool, brushID: UInt32, formatID: UInt32,
    rect: (Float, Float, Float, Float), string: String
) -> [UInt8] {
    let units = Array(string.utf16)
    let flags = (sBit ? 0x8000 : 0) | UInt16(fontID)
    let data = pad4(tle { writer in
        writer.u32(brushID)
        writer.u32(formatID)
        writer.u32(UInt32(units.count))
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
        for unit in units { writer.u16(unit) }
    })
    return tPlusRecord(0x401C, flags, data)
}

/// EmfPlusDrawDriverString record ([MS-EMFPLUS] §2.3.4.6). `options` is the
/// DriverStringOptions flag word; a non-nil `matrix` sets MatrixPresent.
private func tDrawDriverString(
    fontID: UInt8, sBit: Bool, brushID: UInt32, options: UInt32,
    glyphs: [UInt16], positions: [(Float, Float)],
    matrix: (Float, Float, Float, Float, Float, Float)? = nil
) -> [UInt8] {
    let flags = (sBit ? 0x8000 : 0) | UInt16(fontID)
    let data = pad4(tle { writer in
        writer.u32(brushID)
        writer.u32(options)
        writer.u32(matrix == nil ? 0 : 1)
        writer.u32(UInt32(glyphs.count))
        for glyph in glyphs { writer.u16(glyph) }
        for point in positions { writer.f32(point.0); writer.f32(point.1) }
        if let matrix {
            writer.f32(matrix.0); writer.f32(matrix.1); writer.f32(matrix.2)
            writer.f32(matrix.3); writer.f32(matrix.4); writer.f32(matrix.5)
        }
    })
    return tPlusRecord(0x4036, flags, data)
}

private extension RenderFixture {
    mutating func textComment(_ stream: [UInt8]) {
        var payload = LE()
        payload.u32(UInt32(4 + stream.count))
        payload.u32(0x2B46_4D45)                 // "EMF+"
        payload.raw(stream)
        append(type: 70, payload: payload.bytes)
    }
}

/// A 100×100 EMF file whose single EMF+ comment carries `records` after a header.
private func textFile(_ records: [[UInt8]]) throws -> EMFFile {
    var fixture = RenderFixture()
    fixture.textComment(tPlusHeader() + records.reduce([], +))
    return try fixture.parsed()
}

private func renderText(_ file: EMFFile) throws -> (RasterizedImage, EMFRenderLog) {
    let rendered = try #require(EMFRenderer.makeImage(file), "makeImage returned nil")
    return (try #require(RasterizedImage(rendered.0)), rendered.1)
}

/// The smallest x column carrying dark ink inside `band`, or nil if none.
private func leftmostInkColumn(_ image: RasterizedImage, band: (x: Int, y: Int, width: Int, height: Int)) -> Int? {
    let x0 = max(0, band.x), y0 = max(0, band.y)
    let x1 = min(image.width, band.x + band.width), y1 = min(image.height, band.y + band.height)
    guard x0 < x1, y0 < y1 else { return nil }
    for x in x0 ..< x1 {
        for y in y0 ..< y1 where image[x, y].r < 160 {
            return x
        }
    }
    return nil
}

/// The largest x column carrying dark ink inside `band`, or nil if none.
private func rightmostInkColumn(_ image: RasterizedImage, band: (x: Int, y: Int, width: Int, height: Int)) -> Int? {
    let x0 = max(0, band.x), y0 = max(0, band.y)
    let x1 = min(image.width, band.x + band.width), y1 = min(image.height, band.y + band.height)
    guard x0 < x1, y0 < y1 else { return nil }
    for x in stride(from: x1 - 1, through: x0, by: -1) {
        for y in y0 ..< y1 where image[x, y].r < 160 {
            return x
        }
    }
    return nil
}

/// The bounding box of dark ink across the whole image, or nil if none — a
/// transform-agnostic orientation probe (rotated runs land anywhere on canvas).
private func inkBoundingBox(_ image: RasterizedImage, threshold: UInt8 = 160)
    -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0 ..< image.height {
        for x in 0 ..< image.width where image[x, y].r < threshold {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return (minX, minY, maxX, maxY)
}

/// EmfPlusTranslateWorldTransform ([MS-EMFPLUS] §2.3.9.8): dx, dy (f32), applied
/// pre-multiply (flags 0). b == c == 0, so playback keeps the axis-aligned path.
private func tTranslateWorld(_ dx: Float, _ dy: Float) -> [UInt8] {
    tPlusRecord(0x402D, 0, tle { $0.f32(dx); $0.f32(dy) })
}

/// EmfPlusRotateWorldTransform ([MS-EMFPLUS] §2.3.9.6): angle in DEGREES (f32),
/// applied pre-multiply (flags 0) — introduces a rotation (b, c != 0).
private func tRotateWorld(_ degrees: Float) -> [UInt8] {
    tPlusRecord(0x402F, 0, tle { $0.f32(degrees) })
}

// MARK: - Decode unit tests (byte fixtures)

@Suite("EMF+ text decode")
struct EMFPlusTextDecodeTests {

    // DrawString (§2.3.4.14)

    @Test("DrawString decodes BrushId, FormatID, LayoutRect, and the UTF-16 string")
    func decodeStringWellFormed() {
        let body = tle { writer in
            writer.u32(0xFF00_8040)          // BrushId
            writer.u32(7)                    // FormatID
            writer.u32(4)                    // Length (chars)
            writer.f32(10); writer.f32(20); writer.f32(80); writer.f32(30)   // LayoutRect
            for unit in Array("Emfy".utf16) { writer.u16(unit) }
        }
        let decoded = EMFPlusText.decodeString(Data(body))
        #expect(decoded?.brushId == 0xFF00_8040)
        #expect(decoded?.formatId == 7)
        #expect(decoded?.string == "Emfy")
        #expect(decoded?.layoutRect == CGRect(x: 10, y: 20, width: 80, height: 30))
    }

    @Test("DrawString with a lone surrogate decodes losslessly to U+FFFD")
    func decodeStringLoneSurrogate() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0)
            writer.u32(1)                    // Length 1
            writer.f32(0); writer.f32(0); writer.f32(0); writer.f32(0)
            writer.u16(0xD800)               // a lone high surrogate
        }
        let decoded = EMFPlusText.decodeString(Data(body))
        #expect(decoded?.string == "\u{FFFD}", "a lone surrogate should become U+FFFD, not fail")
    }

    @Test("a truncated DrawString header decodes to nil, never traps")
    func decodeStringTruncated() {
        // Only BrushId + FormatID present; Length and LayoutRect missing.
        let body = tle { $0.u32(0); $0.u32(0) }
        #expect(EMFPlusText.decodeString(Data(body)) == nil)
    }

    @Test("a lying DrawString Length (more chars than bytes) decodes to nil")
    func decodeStringLyingLength() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0)
            writer.u32(100)                  // Length claims 100 chars…
            writer.f32(0); writer.f32(0); writer.f32(0); writer.f32(0)
            writer.u16(0x0041)               // …but only one code unit follows
        }
        #expect(EMFPlusText.decodeString(Data(body)) == nil,
                "a Length past the buffer must fail before allocating")
    }

    // DrawDriverString (§2.3.4.6)

    @Test("DrawDriverString decodes glyphs, positions, and no matrix")
    func decodeDriverStringWellFormed() {
        let body = tle { writer in
            writer.u32(0xFF00_0000)          // BrushId
            writer.u32(0)                    // Options
            writer.u32(0)                    // MatrixPresent
            writer.u32(2)                    // GlyphCount
            writer.u16(10); writer.u16(20)   // Glyphs
            writer.f32(1); writer.f32(2)     // GlyphPos[0]
            writer.f32(3); writer.f32(4)     // GlyphPos[1]
        }
        let decoded = EMFPlusText.decodeDriverString(Data(body))
        #expect(decoded?.values == [10, 20])
        #expect(decoded?.positions == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
        #expect(decoded?.matrix == nil)
        #expect(decoded?.cmapLookup == false)
    }

    @Test("DrawDriverString reads the optional 24-byte transform matrix")
    func decodeDriverStringMatrix() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0x1)   // Options = CmapLookup
            writer.u32(1)                    // MatrixPresent
            writer.u32(1)                    // GlyphCount
            writer.u16(0x0041)               // one glyph/char
            writer.f32(5); writer.f32(6)     // GlyphPos[0]
            writer.f32(2); writer.f32(0); writer.f32(0); writer.f32(2); writer.f32(1); writer.f32(1)
        }
        let decoded = EMFPlusText.decodeDriverString(Data(body))
        #expect(decoded?.cmapLookup == true)
        #expect(decoded?.matrix == CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 1, ty: 1))
    }

    @Test("DrawDriverString RealizedAdvance carries a single origin")
    func decodeDriverStringRealizedAdvance() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0x4)   // Options = RealizedAdvance
            writer.u32(0)                    // MatrixPresent
            writer.u32(3)                    // GlyphCount = 3
            writer.u16(1); writer.u16(2); writer.u16(3)
            writer.f32(10); writer.f32(20)   // only ONE position
        }
        let decoded = EMFPlusText.decodeDriverString(Data(body))
        #expect(decoded?.realizedAdvance == true)
        #expect(decoded?.values.count == 3)
        #expect(decoded?.positions.count == 1, "RealizedAdvance stores just the first origin")
    }

    @Test("a truncated DrawDriverString (missing positions) decodes to nil")
    func decodeDriverStringTruncated() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0); writer.u32(0)
            writer.u32(2)                    // GlyphCount 2
            writer.u16(1); writer.u16(2)     // glyphs, but no positions
        }
        #expect(EMFPlusText.decodeDriverString(Data(body)) == nil)
    }

    @Test("a lying DrawDriverString GlyphCount decodes to nil")
    func decodeDriverStringLyingCount() {
        let body = tle { writer in
            writer.u32(0); writer.u32(0); writer.u32(0)
            writer.u32(100_000)              // GlyphCount far past the buffer
            writer.u16(1)
        }
        #expect(EMFPlusText.decodeDriverString(Data(body)) == nil,
                "a GlyphCount past the buffer must fail before allocating")
    }

    // Alignment (pure)

    @Test("drawStringOrigin places Near/Center/Far correctly in device space")
    func alignmentOrigin() {
        // rect device: minX 100, midX 130, maxX 160; minY 50, midY 60, maxY 70.
        let rect = CGRect(x: 100, y: 50, width: 60, height: 20)
        let near = EMFPlusText.drawStringOrigin(rectDevice: rect, lineWidth: 40, ascent: 16, descent: 4, horizontal: 0, vertical: 0)
        #expect(near == CGPoint(x: 100, y: 66))            // left, baseline = top + ascent
        let center = EMFPlusText.drawStringOrigin(rectDevice: rect, lineWidth: 40, ascent: 16, descent: 4, horizontal: 1, vertical: 1)
        #expect(center == CGPoint(x: 110, y: 66))          // midX - w/2, midY + (asc-desc)/2
        let far = EMFPlusText.drawStringOrigin(rectDevice: rect, lineWidth: 40, ascent: 16, descent: 4, horizontal: 2, vertical: 2)
        #expect(far == CGPoint(x: 120, y: 66))             // maxX - w, maxY - descent
    }
}

// MARK: - Render tests

@Suite("EMF+ text playback")
struct EMFPlusTextPlaybackTests {

    private static let band = (x: 4, y: 4, width: 92, height: 44)

    private func hasApprox(_ log: EMFRenderLog, _ feature: EMFPlusApproximation) -> Bool {
        log.entries.contains { if case .emfPlusApproximated(let f, _) = $0 { return f == feature }; return false }
    }

    @Test("DrawString draws legible dark ink inside its layout rect, clean log")
    func drawStringInk() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 24, family: "Arial")),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "Emfy"),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: Self.band), "no text ink drawn")
        #expect(!hasApprox(log, .stringFormatSimplified), "no format present → no simplified note: \(log.entries)")
        // Blank well below the run.
        #expect(image[50, 90].r > 230, "canvas below the run should stay blank")
    }

    @Test("DrawString honours a direct S-bit ARGB colour")
    func drawStringDirectColor() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 28, family: "Arial")),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 220, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "Red"),
        ])
        let (image, _) = try renderText(file)
        #expect(image.contains(in: Self.band) { $0.r > 180 && $0.g < 90 && $0.b < 90 },
                "expected red glyph ink")
    }

    @Test("DrawString fills from an object brush when the S bit is clear")
    func drawStringBrushFill() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 28, family: "Arial")),
            tPlusObject(id: 2, type: 1, payload: tSolidBrush(tArgb(255, 0, 160, 0))),   // green
            tDrawString(fontID: 1, sBit: false, brushID: 2, formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "Grn"),
        ])
        let (image, log) = try renderText(file)
        #expect(image.contains(in: Self.band) { $0.g > 120 && $0.r < 120 && $0.b < 120 },
                "expected green glyph ink")
        #expect(log.isClean, "solid brush text should log nothing: \(log.entries)")
    }

    @Test("StringFormat alignment shifts the run: Center starts right of Near")
    func drawStringAlignmentShift() throws {
        func leftEdge(alignment: UInt32) throws -> Int {
            let file = try textFile([
                tPlusObject(id: 1, type: 6, payload: tFont(emSize: 20, family: "Arial")),
                tPlusObject(id: 2, type: 7, payload: tStringFormat(stringAlignment: alignment)),
                tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                            rect: (5, 5, 90, 40), string: "Hi"),
            ])
            let (image, _) = try renderText(file)
            return try #require(leftmostInkColumn(image, band: Self.band), "no ink for alignment \(alignment)")
        }
        let near = try leftEdge(alignment: 0)     // StringAlignmentNear
        let center = try leftEdge(alignment: 1)   // StringAlignmentCenter
        #expect(center > near + 10, "center run (\(center)) should start well right of near (\(near))")
    }

    @Test("a missing font family logs a substitution but still draws")
    func drawStringSubstitutionLogged() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 24, family: "Nonexistent Family QZX")),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "Sub"),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: Self.band), "substituted text should still draw")
        #expect(log.entries.contains { if case .fontSubstituted(let req, _, _) = $0 { return req == "Nonexistent Family QZX" }; return false },
                "expected a font-substitution note: \(log.entries)")
    }

    @Test("a StringFormat with a non-default feature logs .stringFormatSimplified")
    func drawStringSimplifiedNote() throws {
        // A defined tab stop is a feature the single-line playback ignores.
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 22, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat(tabStops: [40])),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 90, 40), string: "Tab"),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: Self.band), "text should still draw")
        #expect(hasApprox(log, .stringFormatSimplified), "a tab stop should log .stringFormatSimplified: \(log.entries)")
    }

    @Test("a plain alignment-only StringFormat logs no simplification")
    func drawStringPlainFormatClean() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 22, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat(stringAlignment: 1, lineAlign: 1)),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 90, 40), string: "OK"),
        ])
        let (_, log) = try renderText(file)
        #expect(!hasApprox(log, .stringFormatSimplified), "center/center alignment is honoured, not simplified: \(log.entries)")
    }

    @Test("a right-to-left StringFormat flag logs .stringFormatSimplified")
    func drawStringRTLSimplified() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 22, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat(flags: 0x0001)),   // DirectionRightToLeft
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 90, 40), string: "RTL"),
        ])
        let (_, log) = try renderText(file)
        #expect(hasApprox(log, .stringFormatSimplified), "an RTL flag should log a simplification: \(log.entries)")
    }

    @Test("an empty DrawString draws nothing and logs nothing")
    func drawStringEmptyNoOp() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 24, family: "Arial")),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: ""),
        ])
        let (image, log) = try renderText(file)
        #expect(!image.containsDarkPixel(in: Self.band), "an empty string should draw no ink")
        #expect(log.isClean, "an empty string should log nothing: \(log.entries)")
    }

    @Test("a DrawString naming an unbound font draws nothing and notes a missing reference")
    func drawStringUnboundFontNoOp() throws {
        let file = try textFile([
            tDrawString(fontID: 9, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "Hi"),
        ])
        let (image, log) = try renderText(file)
        #expect(!image.containsDarkPixel(in: Self.band), "an unbound font should draw nothing")
        // Audit M7: no longer silent — the missing font reference is surfaced.
        #expect(log.entries.contains(.emfPlusObjectIssue(kind: .missingReference, count: 1)),
                "an unbound font should note a missing object reference: \(log.entries)")
    }

    @Test("a bold-italic font object resolves its traits and draws")
    func drawStringBoldItalicTraits() throws {
        // FontStyleBold (0x1) | FontStyleItalic (0x2).
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 28, style: 0x3, family: "Arial")),
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 90, 40), string: "BI"),
        ])
        let (image, _) = try renderText(file)
        #expect(image.containsDarkPixel(in: Self.band), "bold-italic text should draw")
    }

    // DrawDriverString

    @Test("DrawDriverString with CmapLookup draws character ink")
    func drawDriverStringCmapInk() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 26, family: "Arial")),
            tDrawDriverString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), options: 0x1,   // CmapLookup
                              glyphs: Array("AB".utf16), positions: [(10, 30), (30, 30)]),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: (x: 8, y: 8, width: 60, height: 30)), "driver-string characters drew no ink")
        #expect(log.isClean, "a plain horizontal driver string should log nothing: \(log.entries)")
    }

    @Test("DrawDriverString with raw glyph indices draws glyph ink")
    func drawDriverStringGlyphIndexInk() throws {
        // Query real glyph indices from the resolved font so the index path is
        // deterministic; the values ARE font-dependent (documented).
        var log0 = EMFRenderLog()
        let resolved = FontMapper.resolveFamily("Arial", bold: false, italic: false, log: &log0)
        let sized = CTFontCreateCopyWithAttributes(resolved, 26, nil, nil)
        var chars: [UniChar] = Array("Ag".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(sized, &chars, &glyphs, chars.count)

        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 26, family: "Arial")),
            tDrawDriverString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), options: 0x0,   // glyph indices
                              glyphs: glyphs.map { UInt16($0) }, positions: [(12, 34), (34, 34)]),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: (x: 8, y: 10, width: 60, height: 34)), "glyph-index driver string drew no ink")
        #expect(log.isClean, "a plain driver string should log nothing: \(log.entries)")
    }

    @Test("a RealizedAdvance driver string lays out and logs a simplification")
    func drawDriverStringRealizedAdvance() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 26, family: "Arial")),
            tDrawDriverString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), options: 0x1 | 0x4,   // Cmap + RealizedAdvance
                              glyphs: Array("Emfy".utf16), positions: [(10, 34)]),
        ])
        let (image, log) = try renderText(file)
        #expect(image.containsDarkPixel(in: (x: 8, y: 12, width: 84, height: 30)), "realized-advance run drew no ink")
        #expect(hasApprox(log, .stringFormatSimplified), "RealizedAdvance should log a simplification: \(log.entries)")
    }
}

// MARK: - Rotated / sheared text (audit H2)

/// A rotated/sheared world transform must ROTATE text, not draw a silent upright
/// line (the GDI path rotates via escapement, so dual files regressed). The
/// axis-aligned branch stays byte-stable (pinned by the existing snapshots); a
/// translated-but-unrotated transform is probed here to confirm it still takes
/// the device path.
@Suite("EMF+ text rotation")
struct EMFPlusTextRotationTests {

    /// Rotate about the world origin, then shift the result onto the 100×100
    /// canvas (records play in order: translate first, rotate second, which
    /// composes to "rotate then translate").
    private func rotatedPrefix(degrees: Float, tx: Float, ty: Float) -> [[UInt8]] {
        [tTranslateWorld(tx, ty), tRotateWorld(degrees)]
    }

    @Test("a 90° world rotation draws DrawString along a vertical baseline")
    func drawStringRotated90() throws {
        let file = try textFile(
            [tPlusObject(id: 1, type: 6, payload: tFont(emSize: 20, family: "Arial"))]
            + rotatedPrefix(degrees: 90, tx: 50, ty: 50)
            + [tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                           rect: (-30, -8, 60, 16), string: "Emfy")]
        )
        let (image, _) = try renderText(file)
        let box = try #require(inkBoundingBox(image), "rotated DrawString drew no ink")
        let w = box.maxX - box.minX, h = box.maxY - box.minY
        #expect(h > w, "a 90°-rotated run should be taller than wide (vertical baseline), got w=\(w) h=\(h)")
    }

    @Test("90° rotates a DrawDriverString run vertical; unrotated it is horizontal")
    func drawDriverStringRotationOrientation() throws {
        func box(_ transforms: [[UInt8]]) throws -> (w: Int, h: Int) {
            let records =
                [tPlusObject(id: 1, type: 6, payload: tFont(emSize: 20, family: "Arial"))]
                + transforms
                + [tDrawDriverString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), options: 0x1,
                                     glyphs: Array("AAAA".utf16),
                                     positions: [(0, 0), (14, 0), (28, 0), (42, 0)])]
            let (image, _) = try renderText(textFile(records))
            let bb = try #require(inkBoundingBox(image), "driver string drew no ink")
            return (bb.maxX - bb.minX, bb.maxY - bb.minY)
        }
        let rotated = try box(rotatedPrefix(degrees: 90, tx: 40, ty: 25))
        #expect(rotated.h > rotated.w, "90° driver-string run should be taller than wide, got \(rotated)")
        let flat = try box([tTranslateWorld(15, 45)])
        #expect(flat.w > flat.h, "an unrotated driver-string run should be wider than tall, got \(flat)")
    }

    @Test("a realized-advance run follows the rotated baseline, not device +x")
    func realizedAdvanceFollowsRotatedBaseline() throws {
        let file = try textFile(
            [tPlusObject(id: 1, type: 6, payload: tFont(emSize: 20, family: "Arial"))]
            + rotatedPrefix(degrees: 90, tx: 50, ty: 20)
            + [tDrawDriverString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), options: 0x1 | 0x4,
                                 glyphs: Array("Emfy".utf16), positions: [(0, 0)])]
        )
        let (image, _) = try renderText(file)
        // Under 90° the baseline runs down device +y: the first glyph near the
        // start, a later glyph further DOWN — both present.
        #expect(image.containsDarkPixel(in: (x: 44, y: 20, width: 26, height: 18)), "no ink near the rotated run start")
        #expect(image.containsDarkPixel(in: (x: 44, y: 46, width: 26, height: 22)), "no ink further down the rotated baseline")
        // The OLD bug advanced along device +x, which would place later glyphs far
        // to the right on the START row; that region must stay empty.
        #expect(!image.containsDarkPixel(in: (x: 80, y: 16, width: 18, height: 14)),
                "ink leaked along device +x — the realized-advance baseline was not rotated")
    }

    @Test("a translated (non-rotated) DrawString still draws horizontally via the device path")
    func drawStringTranslatedAxisAligned() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 20, family: "Arial")),
            tTranslateWorld(10, 20),   // b == c == 0 → axis-aligned device branch
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 0xFFFF_FFFF,
                        rect: (5, 5, 80, 30), string: "Emfy"),
        ])
        let (image, _) = try renderText(file)
        let box = try #require(inkBoundingBox(image), "translated DrawString drew no ink")
        let w = box.maxX - box.minX, h = box.maxY - box.minY
        #expect(w > h, "a non-rotated run should be wider than tall, got w=\(w) h=\(h)")
    }
}

// MARK: - DrawString wrap + clip (audit M8 / G1a)

@Suite("EMF+ text wrap & clip")
struct EMFPlusTextWrapClipTests {

    private func hasApprox(_ log: EMFRenderLog, _ feature: EMFPlusApproximation) -> Bool {
        log.entries.contains { if case .emfPlusApproximated(let f, _) = $0 { return f == feature }; return false }
    }

    @Test("a long paragraph wraps within its rect and clips below it")
    func drawStringWraps() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 18, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat()),   // flags 0 → default wrap + clip
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 40, 50), string: "AAAAAAA BBBBBBB CCCCCCC DDDDDDD"),
        ])
        let (image, log) = try renderText(file)
        // Ink on a second line (a single unwrapped line would leave this band blank).
        #expect(image.containsDarkPixel(in: (x: 6, y: 30, width: 38, height: 14)), "no second-line ink — did not wrap")
        // Clipped: nothing below the rect bottom (y > 55).
        #expect(!image.containsDarkPixel(in: (x: 6, y: 58, width: 38, height: 30)), "ink leaked below the rect — not clipped")
        #expect(!hasApprox(log, .stringFormatSimplified), "a plain wrap should note nothing: \(log.entries)")
    }

    @Test("NoWrap + NoClip: a single overflowing line inks beyond the rect edge")
    func drawStringNoWrapNoClip() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 18, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat(flags: 0x5000)),   // NoWrap | NoClip
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 40, 50), string: "AAAAAAA BBBBBBB CCCCCCC"),
        ])
        let (image, _) = try renderText(file)
        #expect(image.containsDarkPixel(in: (x: 48, y: 6, width: 40, height: 20)), "no ink beyond the rect — NoClip not honored")
        #expect(!image.containsDarkPixel(in: (x: 6, y: 32, width: 38, height: 20)), "second-line ink — NoWrap not honored")
    }

    @Test("NoWrap with clipping: the overflowing line is clipped at the rect edge")
    func drawStringNoWrapClipped() throws {
        let file = try textFile([
            tPlusObject(id: 1, type: 6, payload: tFont(emSize: 18, family: "Arial")),
            tPlusObject(id: 2, type: 7, payload: tStringFormat(flags: 0x1000)),   // NoWrap, clip enabled
            tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                        rect: (5, 5, 40, 50), string: "AAAAAAA BBBBBBB CCCCCCC"),
        ])
        let (image, _) = try renderText(file)
        #expect(image.containsDarkPixel(in: (x: 6, y: 6, width: 38, height: 20)), "the visible part of the line should ink inside the rect")
        #expect(!image.containsDarkPixel(in: (x: 48, y: 6, width: 40, height: 20)), "ink beyond the rect edge — clip not applied")
    }

    // Audit M15 (G1c): trailing whitespace is excluded from the alignment width
    // unless MeasureTrailingSpaces (0x800) is set.
    @Test("Far alignment excludes trailing whitespace unless MeasureTrailingSpaces is set")
    func trailingSpaceMeasurement() throws {
        func rightmostInk(_ string: String, flags: UInt32) throws -> Int {
            let file = try textFile([
                tPlusObject(id: 1, type: 6, payload: tFont(emSize: 24, family: "Arial")),
                tPlusObject(id: 2, type: 7, payload: tStringFormat(stringAlignment: 2, flags: flags)),   // Far
                tDrawString(fontID: 1, sBit: true, brushID: tArgb(255, 0, 0, 0), formatID: 2,
                            rect: (5, 5, 90, 40), string: string),
            ])
            let (image, _) = try renderText(file)
            return try #require(rightmostInkColumn(image, band: (x: 0, y: 4, width: 100, height: 44)), "no ink for \"\(string)\"")
        }
        let baseX = try rightmostInk("X", flags: 0)
        let spaceExcluded = try rightmostInk("X ", flags: 0)          // default: trailing space excluded
        let spaceMeasured = try rightmostInk("X ", flags: 0x800)      // MeasureTrailingSpaces
        #expect(abs(spaceExcluded - baseX) <= 1, "\"X \" should align flush like \"X\" (\(spaceExcluded) vs \(baseX))")
        #expect(spaceMeasured < baseX - 3, "with 0x800 the trailing space shifts \"X\" left (\(spaceMeasured) vs \(baseX))")
    }
}
