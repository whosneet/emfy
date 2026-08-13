import Foundation

/// Deterministic byte generator for `corpus/handmade-cjk-text.emf`.
///
/// A self-contained, hand-authored EMF (the handmade-strokes-paths precedent:
/// exact header, truthful `Bytes`/`Records`, no LibreOffice exporter shell). It
/// exercises the CJK text path — LOGFONTW facename + non-Latin charset
/// resolution (`FontMapper`) and UTF-16LE `EMR_EXTTEXTOUTW` playback
/// (`TextDrawer`), including a surrogate-pair (non-BMP) run — with content no
/// self-generated exporter on this machine can produce (LibreOffice is gone).
///
/// The bytes are a pure function of the literals below, so the committed corpus
/// file is provenance-verifiable: `CJKTextCorpusTests` asserts the on-disk file
/// equals `data` byte-for-byte, and re-materialises it under `EMFY_RECORD=1`.
///
/// Every field layout is cited against [MS-EMF] / [MS-WMF]. Record types are the
/// spec's RecordType values ([MS-EMF] §2.1.1).
enum CJKTextCorpus {

    // MARK: - Layout constants

    /// Header `rclBounds`, inclusive-inclusive device space ([MS-EMF] §2.2.9):
    /// a 360×240 canvas (`makeImage` sizes width=right−left+1, height=…).
    static let boundsRight: Int32 = 359
    static let boundsBottom: Int32 = 239

    /// The four text runs, top to bottom. `charSet` is the [MS-WMF] §2.1.1.5
    /// CharacterSet value the Windows facename would carry. Colours are distinct
    /// and dark (legible on the white canvas, each detectable by the render
    /// probes). `reference` is the baseline anchor (TA_LEFT | TA_BASELINE).
    struct Run {
        let string: String
        let faceName: String
        let charSet: UInt8
        let color: (r: UInt8, g: UInt8, b: UInt8)
        let reference: (x: Int32, y: Int32)
    }

    /// GB2312 / SHIFTJIS / HANGUL charset values ([MS-WMF] §2.1.1.5):
    /// SHIFTJIS_CHARSET=128, HANGUL_CHARSET=129, GB2312_CHARSET=134.
    static let runs: [Run] = [
        Run(string: "中文测试", faceName: "SimSun", charSet: 134,
            color: (0, 0, 0), reference: (20, 55)),
        Run(string: "日本語テスト", faceName: "MS Mincho", charSet: 128,
            color: (0, 0, 170), reference: (20, 110)),
        Run(string: "한글 테스트", faceName: "Batang", charSet: 129,
            color: (170, 0, 0), reference: (20, 165)),
        // Non-BMP: U+2000B (𠀋) is the surrogate pair 0xD840 0xDC0B in UTF-16LE
        // — proves surrogate handling from Chars/offString bytes to CGGlyph.
        Run(string: "\u{2000B}", faceName: "SimSun", charSet: 134,
            color: (0, 110, 0), reference: (20, 215)),
    ]

    static let fontHeight: Int32 = -34          // character (em) height, §2.2.13
    static let textAlign: UInt32 = 24           // TA_LEFT | TA_BASELINE, §2.1.2.3

    // MARK: - Assembled bytes

    static let data = Data(bytes)

    static var bytes: [UInt8] {
        var body: [[UInt8]] = []
        body.append(setMapMode(1))              // MM_TEXT (§2.1.1.20)
        body.append(setBkMode(1))               // TRANSPARENT (§2.1.1.4)
        body.append(setTextAlign(textAlign))
        for (offset, run) in runs.enumerated() {
            let index = UInt32(offset + 1)       // object-table slots 1…4
            body.append(setTextColor(run.color))
            body.append(extCreateFontIndirectW(
                index: index, height: fontHeight, charSet: run.charSet,
                faceName: run.faceName
            ))
            body.append(selectObject(index))
            body.append(extTextOutW(reference: run.reference, string: run.string))
        }

        let eofRecord = eof()
        let recordCount = UInt32(1 + body.count + 1)   // header + body + EOF
        let totalBytes = UInt32(108 + body.reduce(0) { $0 + $1.count } + eofRecord.count)

        var out = header(totalBytes: totalBytes, recordCount: recordCount)
        for record in body { out.append(contentsOf: record) }
        out.append(contentsOf: eofRecord)
        return out
    }

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
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
        /// ColorRef on-disk order Red, Green, Blue, Reserved ([MS-WMF] §2.2.2.8).
        mutating func color(_ c: (r: UInt8, g: UInt8, b: UInt8)) {
            bytes.append(contentsOf: [c.r, c.g, c.b, 0])
        }
        /// UTF-16LE code units, no length prefix (Chars counts them separately).
        mutating func utf16(_ s: String) { for unit in s.utf16 { u16(unit) } }
        mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
        mutating func raw(_ r: [UInt8]) { bytes.append(contentsOf: r) }
    }

    /// Wraps a body (record offsets ≥ 8) as `iType`, `nSize`, body — with the
    /// tail padded to a 4-byte record boundary ([MS-EMF] §2.1, §3.2.1).
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

    // MARK: - Header ([MS-EMF] §2.3.4.2, EmfMetafileHeaderExtension2)

    private static func header(totalBytes: UInt32, recordCount: UInt32) -> [UInt8] {
        var w = LE()
        w.u32(1)                    // 0   iType = EMR_HEADER
        w.u32(108)                  // 4   nSize (extension2 fixed part)
        w.i32(0); w.i32(0)          // 8   rclBounds.left, .top
        w.i32(boundsRight); w.i32(boundsBottom)  // 16  .right, .bottom
        // rclFrame in 0.01mm (§2.2.9): 360×240 px at ~96 DPI ≈ 95.25×63.5 mm.
        w.i32(0); w.i32(0); w.i32(9525); w.i32(6350)   // 24  rclFrame
        w.u32(0x464D_4520)          // 40  RecordSignature " EMF"
        w.u32(0x0001_0000)          // 44  Version
        w.u32(totalBytes)           // 48  Bytes (advisory, set TRUE — no quirk)
        w.u32(recordCount)          // 52  Records (advisory, set TRUE — no quirk)
        w.u16(5)                    // 56  Handles (> max object index 4)
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

    // MARK: - State records

    private static func setMapMode(_ raw: UInt32) -> [UInt8] {
        var b = LE(); b.u32(raw); return record(type: 17, body: b.bytes)
    }
    private static func setBkMode(_ raw: UInt32) -> [UInt8] {
        var b = LE(); b.u32(raw); return record(type: 18, body: b.bytes)
    }
    private static func setTextAlign(_ mask: UInt32) -> [UInt8] {
        var b = LE(); b.u32(mask); return record(type: 22, body: b.bytes)
    }
    private static func setTextColor(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> [UInt8] {
        var b = LE(); b.color(c); return record(type: 24, body: b.bytes)   // §2.3.11.26
    }
    private static func selectObject(_ raw: UInt32) -> [UInt8] {
        var b = LE(); b.u32(raw); return record(type: 37, body: b.bytes)   // §2.3.8.5
    }

    // MARK: - EMR_EXTCREATEFONTINDIRECTW ([MS-EMF] §2.3.7.8, LogFontW §2.2.13)

    private static func extCreateFontIndirectW(
        index: UInt32, height: Int32, charSet: UInt8, faceName: String
    ) -> [UInt8] {
        var b = LE()
        b.u32(index)                                  // ihFonts
        b.i32(height)                                 // +0  Height (signed)
        b.i32(0)                                      // +4  Width
        b.i32(0)                                      // +8  Escapement
        b.i32(0)                                      // +12 Orientation
        b.i32(400)                                    // +16 Weight (normal)
        b.raw([0, 0, 0, charSet])                     // +20 Italic/Underline/StrikeOut/CharSet
        b.raw([0, 0, 0, 0])                           // +24 OutPrec/ClipPrec/Quality/PitchAndFamily
        // +28 FaceName: 32 UTF-16LE code units (64 bytes), NUL-padded (§2.2.13).
        var units = Array(faceName.utf16)
        if units.count > 32 { units = Array(units.prefix(32)) }
        for unit in units { b.u16(unit) }
        b.zeros((32 - units.count) * 2)
        return record(type: 82, body: b.bytes)        // record = 8 + 4 + 92 = 104
    }

    // MARK: - EMR_EXTTEXTOUTW ([MS-EMF] §2.3.5.8, EmrText §2.2.5)

    private static func extTextOutW(reference: (x: Int32, y: Int32), string: String) -> [UInt8] {
        let units = Array(string.utf16)
        let offString = 76                            // fixed EmrText part ends here
        var b = LE()                                  // body starts at record offset 8
        b.i32(0); b.i32(0); b.i32(0); b.i32(0)        // Bounds@8 (ignored on playback)
        b.u32(1)                                      // iGraphicsMode@24 = GM_COMPATIBLE
        b.f32(1); b.f32(1)                            // exScale@28, eyScale@32
        b.i32(reference.x); b.i32(reference.y)        // Reference@36
        b.u32(UInt32(units.count))                    // Chars@44 (UTF-16 code units)
        b.u32(UInt32(offString))                      // offString@48
        b.u32(0)                                      // Options@52 (no ETO flags)
        b.i32(0); b.i32(0); b.i32(0); b.i32(0)        // Rectangle@56
        b.u32(0)                                      // offDx@72 (no Dx array)
        b.utf16(string)                               // String@76, UTF-16LE
        return record(type: 84, body: b.bytes)        // record() 4-aligns the tail
    }

    // MARK: - EMR_EOF ([MS-EMF] §2.3.4.1)

    private static func eof() -> [UInt8] {
        var b = LE()
        b.u32(0)      // nPalEntries
        b.u32(16)     // offPalEntries
        b.u32(20)     // SizeLast
        return record(type: 14, body: b.bytes)   // 20 bytes
    }
}
