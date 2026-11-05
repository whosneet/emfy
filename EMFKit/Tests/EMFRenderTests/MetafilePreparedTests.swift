import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// The `MetafileRenderer.prepare` front door: natural size for WMF placeable /
/// standard / embedded-EMF, the embedded-EMF fate, .emz / .wmz through the open
/// path, PDF export, and gzip-wrapped hostile inputs.
@Suite("MetafileRenderer.prepare (front door)")
struct MetafilePreparedTests {

    // MARK: - Little-endian byte helpers

    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A placeable WMF header: bbox (0,0,`w`,`h`), `inch` units/inch.
    private static func placeable(w: Int16, h: Int16, inch: UInt16) -> [UInt8] {
        u32(0x9AC6_CDD7) + u16(0)
            + i16(0) + i16(0) + i16(w) + i16(h)
            + u16(inch) + u32(0) + u16(0)
    }

    /// An 18-byte META_HEADER with advisory fields zeroed.
    private static func metaHeader() -> [UInt8] {
        u16(1) + u16(9) + u16(0x0300) + u16(0) + u16(0) + u16(0) + u32(0) + u16(0)
    }

    private static func record(_ function: UInt16, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32((6 + body.count) / 2)) + u16(function) + body
    }

    private static func eof() -> [UInt8] { record(0x0000, []) }

    /// The WMF GDI records that fill a canvas RED (window org/ext then a
    /// solid-red brush + rectangle).
    private static func redFill() -> [UInt8] {
        record(0x020B, i16(0) + i16(0))                       // SETWINDOWORG (Y,X)
            + record(0x020C, i16(96) + i16(96))               // SETWINDOWEXT (Y,X)
            + record(0x02FC, u16(0) + [255, 0, 0, 0] + u16(0)) // CREATEBRUSHINDIRECT red → slot 0
            + record(0x012D, u16(0))                          // SELECTOBJECT 0
            + record(0x041B, i16(96) + i16(96) + i16(0) + i16(0)) // RECTANGLE (B,R,T,L)
    }

    /// One META_ESCAPE_ENHANCED_METAFILE "WMFC" chunk ([MS-WMF] §2.3.6.25).
    private static func wmfcChunk(_ chunk: [UInt8], recordCount: UInt32, remaining: UInt32, total: UInt32) -> [UInt8] {
        var body: [UInt8] = []
        body += u16(0x000F)                     // EscapeFunction
        body += u16(UInt16(34 + chunk.count))   // ByteCount
        body += u32(0x4346_4D57)                // "WMFC"
        body += u32(0x0000_0001)                // CommentType
        body += u32(0x0001_0000)                // Version
        body += u16(0)                          // Checksum
        body += u32(0)                          // Flags
        body += u32(recordCount)                // CommentRecordCount
        body += u32(UInt32(chunk.count))        // CurrentRecordSize
        body += u32(remaining)                  // RemainingBytes
        body += u32(total)                      // EnhancedMetafileDataSize
        body += chunk
        return record(0x0626, body)
    }

    // MARK: - Natural size

    @Test("a placeable WMF with no embedded EMF reports its program canvas")
    func placeableNaturalSize() throws {
        let bytes = Self.placeable(w: 96, h: 96, inch: 96) + Self.metaHeader() + Self.redFill() + Self.eof()
        let opened = try OpenedMetafile.open(Data(bytes))
        #expect(opened.format == .placeableWMF)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .wmfRecords)
        #expect(prepared.embeddedEMF == .absent)
        #expect(prepared.naturalSize == CGSize(width: 96, height: 96))   // 96 bbox / 96 inch × 96 DPI
    }

    @Test("a standard WMF sizes its canvas from the first window extent")
    func standardNaturalSize() throws {
        // SETWINDOWORG (0,0), SETWINDOWEXT X=100 Y=50 → a 100×50 canvas.
        let bytes = Self.metaHeader()
            + Self.record(0x020B, Self.i16(0) + Self.i16(0))
            + Self.record(0x020C, Self.i16(50) + Self.i16(100))
            + Self.eof()
        let opened = try OpenedMetafile.open(Data(bytes))
        #expect(opened.format == .wmf)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .wmfRecords)
        #expect(prepared.naturalSize == CGSize(width: 100, height: 50))
    }

    @Test("an EMF reports its header bounds as the natural size")
    func emfNaturalSize() throws {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 199, 149)   // inclusive-inclusive → 200×150
        fixture.rectangle(10, 10, 50, 50)
        let opened = try OpenedMetafile.open(fixture.data())
        #expect(opened.format == .emf)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .emf)
        #expect(prepared.embeddedEMF == .notApplicable)
        #expect(prepared.naturalSize == CGSize(width: 200, height: 150))
    }

    // MARK: - .emz / .wmz through the open path

    @Test(".emz inflates and prepares as an EMF")
    func emzFrontDoor() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("gate-p3-shapes.emz"))
        let opened = try OpenedMetafile.open(data)
        #expect(opened.wasDecompressed)
        #expect(opened.format == .emf)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .emf)
        #expect(prepared.embeddedEMF == .notApplicable)
        let (image, _) = try #require(MetafileRenderer.makeImage(prepared, scale: 2))
        let raster = try #require(RasterizedImage(image))
        #expect(raster.containsDarkPixel(in: (0, 0, raster.width, raster.height)), "the .emz rendered blank")
    }

    @Test(".wmz inflates and prepares, playing its embedded EMF to 372×272")
    func wmzFrontDoor() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("gate-wmf-p2-star.wmz"))
        let opened = try OpenedMetafile.open(data)
        #expect(opened.wasDecompressed)
        #expect(opened.format == .placeableWMF)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        // The LibreOffice placeable export embeds a complete EMF (0,0,371,271).
        #expect(prepared.kind == .emf)
        #expect(prepared.embeddedEMF == .played)
        #expect(prepared.naturalSize == CGSize(width: 372, height: 272))
        let (image, _) = try #require(MetafileRenderer.makeImage(prepared))
        #expect(image.width == 372 && image.height == 272)
    }

    // MARK: - Record inventory (diagnostic report)

    @Test("prepare reports EMF record counts by kind, named")
    func emfRecordKinds() throws {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 0, r: 255, g: 0, b: 0)
        fixture.selectObject(0)
        fixture.rectangle(10, 10, 50, 50)
        fixture.rectangle(20, 20, 60, 60)
        let opened = try OpenedMetafile.open(fixture.data())
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let counts = Dictionary(uniqueKeysWithValues: prepared.recordKinds.map { ($0.name, $0.count) })
        #expect(counts["EMR_HEADER"] == 1)
        #expect(counts["EMR_EOF"] == 1)
        #expect(counts["EMR_RECTANGLE"] == 2)
        #expect(counts["EMR_CREATEBRUSHINDIRECT"] == 1)
        #expect(counts["EMR_SELECTOBJECT"] == 1)
        // The tally is a count of record types only — no payload text leaks in.
        #expect(prepared.recordKinds.allSatisfy { $0.count > 0 })
    }

    @Test("prepare reports WMF record counts by kind for record playback")
    func wmfRecordKinds() throws {
        let bytes = Self.metaHeader()
            + Self.record(0x020B, Self.i16(0) + Self.i16(0))
            + Self.record(0x020C, Self.i16(50) + Self.i16(100))
            + Self.eof()
        let opened = try OpenedMetafile.open(Data(bytes))
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .wmfRecords)
        #expect(!prepared.recordKinds.isEmpty)
        let names = prepared.recordKinds.map(\.name)
        #expect(names.contains("META_SETWINDOWORG"))
    }

    // MARK: - Embedded-EMF fate

    @Test("an inconsistent embedded EMF is rejected and the WMF records play")
    func embeddedEMFRejected() throws {
        // One WMFC chunk declares a 1000-byte total but supplies 10 bytes and
        // ends — an incomplete sequence, rejected ([MS-WMF] §2.3.6.25).
        let chunk: [UInt8] = Array(1 ... 10)
        let bytes = Self.placeable(w: 96, h: 96, inch: 96) + Self.metaHeader()
            + Self.wmfcChunk(chunk, recordCount: 1, remaining: 990, total: 1000)
            + Self.redFill() + Self.eof()
        let opened = try OpenedMetafile.open(Data(bytes))
        let prepared = try #require(MetafileRenderer.prepare(opened))
        #expect(prepared.kind == .wmfRecords)
        #expect(prepared.embeddedEMF == .rejected)
        // Proof the records played: the red fill is on the canvas.
        let (image, _) = try #require(MetafileRenderer.makeImage(prepared))
        let raster = try #require(RasterizedImage(image))
        #expect(raster.contains(in: (40, 40, 16, 16)) { $0.r > 160 && $0.g < 120 && $0.b < 120 })
    }

    // MARK: - PDF export

    @Test("pdfData produces a PDF for both an EMF and a WMF")
    func pdfExport() throws {
        let emf = try Data(contentsOf: TestPaths.corpusFile("gate-p2-star.emf"))
        let emfPrepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(emf)))
        let emfPDF = try #require(MetafileRenderer.pdfData(emfPrepared))
        #expect(emfPDF.starts(with: Array("%PDF".utf8)))

        let wmf = Self.placeable(w: 96, h: 96, inch: 96) + Self.metaHeader() + Self.redFill() + Self.eof()
        let wmfPrepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(Data(wmf))))
        let wmfPDF = try #require(MetafileRenderer.pdfData(wmfPrepared))
        #expect(wmfPDF.starts(with: Array("%PDF".utf8)))
    }

    // MARK: - Hostile gzip through the front door

    @Test("a truncated gzip wrapper throws rather than crashing")
    func truncatedGzipThrows() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("gate-p3-shapes.emz"))
        let truncated = data.prefix(25)
        #expect(throws: MetafileOpenError.self) {
            _ = try OpenedMetafile.open(truncated)
        }
    }

    @Test("an unrecognised input prepares to nil (no blank canvas, no crash)")
    func unknownPreparesToNil() throws {
        let opened = try OpenedMetafile.open(Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))
        #expect(opened.format == .unknown)
        #expect(MetafileRenderer.prepare(opened) == nil)
    }
}
