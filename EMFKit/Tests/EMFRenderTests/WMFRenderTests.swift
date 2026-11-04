import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// End-to-end WMF playback through `MetafileRenderer`: the embedded-EMF branch
/// vs the WMF-record branch (proven by pixel colour), plus the WMF GDI path and
/// page setup on hand-built and committed files.
@Suite("WMF playback (render)")
struct WMFRenderTests {

    // MARK: - Little-endian byte helpers

    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A placeable WMF header: bbox (0,0,96,96), 96 units/inch → a 96×96 canvas.
    private static func placeableHeader() -> [UInt8] {
        var h: [UInt8] = []
        h += u32(0x9AC6_CDD7)                 // Key
        h += u16(0)                           // HWmf
        h += i16(0); h += i16(0); h += i16(96); h += i16(96)   // BoundingBox
        h += u16(96)                          // Inch
        h += u32(0)                           // Reserved
        h += u16(0)                           // Checksum (advisory)
        return h
    }

    /// An 18-byte META_HEADER with advisory fields zeroed.
    private static func metaHeader() -> [UInt8] {
        var h: [UInt8] = []
        h += u16(1)       // Type MEMORYMETAFILE
        h += u16(9)       // HeaderSize (WORDs)
        h += u16(0x0300)  // Version
        h += u16(0)       // SizeLow
        h += u16(0)       // SizeHigh
        h += u16(0)       // NumberOfObjects
        h += u32(0)       // MaxRecord
        h += u16(0)       // NumberOfMembers
        return h
    }

    private static func record(function: UInt16, body: [UInt8]) -> [UInt8] {
        let sizeWords = UInt32((6 + body.count) / 2)
        return u32(sizeWords) + u16(function) + body
    }

    /// One META_ESCAPE_ENHANCED_METAFILE chunk ([MS-WMF] §2.3.6.25).
    private static func escapeChunk(
        _ chunk: [UInt8],
        recordCount: UInt32,
        remainingBytes: UInt32,
        totalSize: UInt32
    ) -> [UInt8] {
        var body: [UInt8] = []
        body += u16(0x000F)                         // EscapeFunction
        body += u16(UInt16(34 + chunk.count))       // ByteCount
        body += u32(0x4346_4D57)                    // CommentIdentifier "WMFC"
        body += u32(0x0000_0001)                    // CommentType
        body += u32(0x0001_0000)                    // Version
        body += u16(0)                              // Checksum
        body += u32(0)                              // Flags
        body += u32(recordCount)                    // CommentRecordCount
        body += u32(UInt32(chunk.count))            // CurrentRecordSize
        body += u32(remainingBytes)                 // RemainingBytes
        body += u32(totalSize)                      // EnhancedMetafileDataSize
        body += chunk
        return record(function: 0x0626, body: body)
    }

    /// Splits `emf` into `count` even-length consecutive escape chunks. When
    /// `corrupt` is true, the middle chunk's RemainingBytes is falsified so the
    /// reassembly is rejected and the renderer falls back to the WMF records.
    private static func embeddedEscapes(_ emf: [UInt8], count: Int, corrupt: Bool) -> [[UInt8]] {
        let total = UInt32(emf.count)
        var records: [[UInt8]] = []
        let base = ((emf.count / count) + 1) & ~1
        var offset = 0
        var accumulated = 0
        for i in 0 ..< count {
            let end = i == count - 1 ? emf.count : min(emf.count, offset + base)
            let chunk = Array(emf[offset ..< end])
            accumulated += chunk.count
            var remaining = total - UInt32(accumulated)
            if corrupt, i == count / 2 { remaining = remaining &+ 999 }
            records.append(escapeChunk(chunk, recordCount: UInt32(count), remainingBytes: remaining, totalSize: total))
            offset = end
        }
        return records
    }

    /// The WMF GDI records that fill the 96×96 canvas RED.
    private static func redFillRecords() -> [[UInt8]] {
        [
            record(function: 0x020B, body: i16(0) + i16(0)),                 // SETWINDOWORG (Y,X)
            record(function: 0x020C, body: i16(96) + i16(96)),               // SETWINDOWEXT (Y,X)
            record(function: 0x02FC, body: u16(0) + [255, 0, 0, 0] + u16(0)), // CREATEBRUSHINDIRECT solid red → slot 0
            record(function: 0x012D, body: u16(0)),                          // SELECTOBJECT 0
            record(function: 0x041B, body: i16(96) + i16(96) + i16(0) + i16(0)), // RECTANGLE (B,R,T,L)
        ]
    }

    private static func eof() -> [UInt8] { record(function: 0x0000, body: []) }

    /// Assembles a placeable WMF: optional embedded-EMF escapes, then the red
    /// GDI fill, then EOF.
    private static func buildWMF(embedding emf: [UInt8]?, corruptEmbedded: Bool = false) -> Data {
        var bytes = placeableHeader() + metaHeader()
        if let emf {
            for chunk in embeddedEscapes(emf, count: 3, corrupt: corruptEmbedded) {
                bytes += chunk
            }
        }
        for gdi in redFillRecords() { bytes += gdi }
        bytes += eof()
        return Data(bytes)
    }

    /// A standalone EMF that fills its 96×96 canvas BLUE.
    private static func blueEMF() -> Data {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 95, 95)
        fixture.createSolidBrush(index: 1, r: 0, g: 0, b: 255)
        fixture.selectObject(1)
        fixture.rectangle(-5, -5, 100, 100)
        return fixture.data()
    }

    private static func render(_ data: Data) throws -> (RasterizedImage, EMFRenderLog) {
        let opened = try OpenedMetafile.open(data)
        let (image, log) = try #require(MetafileRenderer.makeImage(opened), "makeImage returned nil")
        return (try #require(RasterizedImage(image)), log)
    }

    private static func containsRed(_ raster: RasterizedImage, in rect: (x: Int, y: Int, width: Int, height: Int)) -> Bool {
        raster.contains(in: rect) { $0.r > 160 && $0.g < 120 && $0.b < 120 }
    }

    private static var center: (x: Int, y: Int, width: Int, height: Int) { (40, 40, 16, 16) }

    // MARK: - Branch proof

    @Test("a valid embedded EMF plays instead of the WMF records (blue, not red)")
    func embeddedEMFBranchPlays() throws {
        let wmf = Self.buildWMF(embedding: Array(Self.blueEMF()))
        let (raster, _) = try Self.render(wmf)
        #expect(raster.width == 96 && raster.height == 96)
        #expect(raster.containsBluePixel(in: Self.center), "embedded EMF (blue) should have played")
        #expect(!Self.containsRed(raster, in: Self.center), "the WMF red fill must NOT show")
    }

    @Test("a corrupted embedded EMF falls back to the WMF records (red, not blue)")
    func corruptedEmbeddedEMFFallsBack() throws {
        let wmf = Self.buildWMF(embedding: Array(Self.blueEMF()), corruptEmbedded: true)
        let (raster, log) = try Self.render(wmf)
        #expect(raster.width == 96 && raster.height == 96)
        #expect(Self.containsRed(raster, in: Self.center), "WMF red fill should have played on fallback")
        #expect(!raster.containsBluePixel(in: Self.center), "the embedded blue EMF must NOT show")
        // Proof the WMF branch ran: the three now-skipped META_ESCAPE records
        // (0x0626) are logged (the embedded branch would never translate them).
        #expect(
            log.entries.contains(.unimplementedRecord(type: 0x0626, count: 3)),
            "expected the WMF record branch to log the skipped escape records; got \(log.entries)"
        )
    }

    // MARK: - WMF GDI path and page setup

    @Test("a WMF with no embedded EMF plays its GDI records (red fill, 96×96)")
    func wmfGDIPathPlays() throws {
        let wmf = Self.buildWMF(embedding: nil)
        let (raster, _) = try Self.render(wmf)
        #expect(raster.width == 96 && raster.height == 96)   // placeable bbox 96 / inch 96 × 96 DPI
        #expect(Self.containsRed(raster, in: Self.center))
    }

    @Test("the committed gate WMFs render their embedded EMF to the EMF device size")
    func committedGateWMFRenders() throws {
        // Each LibreOffice export embeds an EMF whose bounds are (0,0,371,271);
        // playing it yields a 372×272 non-blank image.
        for name in ["gate-wmf-p2-star", "gate-wmf-p3-shapes"] {
            let data = try Data(contentsOf: TestPaths.corpusFile("\(name).wmf"))
            let (raster, _) = try Self.render(data)
            #expect(raster.width == 372 && raster.height == 272, "\(name): unexpected canvas")
            #expect(
                raster.containsDarkPixel(in: (0, 0, raster.width, raster.height)),
                "\(name): rendered image is blank"
            )
        }
    }
}
