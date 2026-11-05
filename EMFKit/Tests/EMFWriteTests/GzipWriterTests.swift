import Foundation
import Testing
import EMFParse
import EMFWrite

/// The EMZ/WMZ writer: an RFC 1952 gzip member whose raw DEFLATE body, CRC-32
/// and ISIZE EMFParse's own inflater reads back. `OpenedMetafile.open` is the
/// public read-side that both detects the gzip wrapper and verifies the CRC, so
/// a successful round-trip through it proves header, body and checksum.
@Suite("Gzip (EMZ) writer")
struct GzipWriterTests {

    /// A tiny valid EMF to wrap.
    private func sampleEMF() throws -> Data {
        let builder = EMFDocumentBuilder(
            bounds: RectL(left: 0, top: 0, right: 40, bottom: 40),
            frame: RectL(left: 0, top: 0, right: 800, bottom: 800),
            device: SizeL(cx: 40, cy: 40),
            millimeters: SizeL(cx: 8, cy: 8),
            description: "gz sample"
        )
        try builder.append(.rectangle(box: RectL(left: 5, top: 5, right: 35, bottom: 35)))
        return try builder.finish()
    }

    @Test func gzipRoundTripsThroughOpen() throws {
        let emf = try sampleEMF()
        let gz = GzipWriter.compress(emf)

        // RFC 1952 member header: ID1/ID2/CM.
        #expect(gz.count >= 18)
        #expect(gz[gz.startIndex] == 0x1F)
        #expect(gz[gz.startIndex + 1] == 0x8B)
        #expect(gz[gz.startIndex + 2] == 0x08)

        let opened = try OpenedMetafile.open(gz)
        #expect(opened.format == .emf)
        #expect(opened.wasDecompressed)
        #expect(opened.data == emf)   // CRC verified inside inflate
    }

    @Test func gzipOfCorpusFileRoundTrips() throws {
        let emf = try corpusData("gate-p2-star.emf")
        let gz = GzipWriter.compress(emf)
        let opened = try OpenedMetafile.open(gz)
        #expect(opened.data == emf)
        // Compression actually shrinks this file.
        #expect(gz.count < emf.count)
    }

    @Test func arbitraryBytesRoundTrip() throws {
        // Non-metafile payload: still a valid gzip that inflates exactly.
        let payload = Data((0 ..< 5000).map { UInt8($0 & 0xFF) })
        let gz = GzipWriter.compress(payload)
        let opened = try OpenedMetafile.open(gz)
        #expect(opened.data == payload)
    }

    @Test func emptyInputRoundTrips() throws {
        let gz = GzipWriter.compress(Data())
        let opened = try OpenedMetafile.open(gz)
        #expect(opened.data.isEmpty)
    }

    @Test func filenameFieldIsWritten() throws {
        let gz = GzipWriter.compress(Data([1, 2, 3, 4]), filename: "drawing.emf")
        // FLG bit 3 (FNAME) set.
        #expect(gz[gz.startIndex + 3] & 0x08 != 0)
        let opened = try OpenedMetafile.open(gz)
        #expect(opened.data == Data([1, 2, 3, 4]))
    }

    /// Writes one .emz to disk when EMFY_EMZ_DUMP_DIR is set, so the gzip can be
    /// independently validated with `gunzip -t` (E0a report). A no-op otherwise.
    @Test func dumpForManualGunzipCheck() throws {
        guard let dir = ProcessInfo.processInfo.environment["EMFY_EMZ_DUMP_DIR"] else { return }
        let emf = try sampleEMF()
        let gz = GzipWriter.compress(emf)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("emfwrite-sample.emz")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        try gz.write(to: url)
    }
}
