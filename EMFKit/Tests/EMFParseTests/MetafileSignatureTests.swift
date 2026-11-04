import Foundation
import Testing
@testable import EMFParse

/// Signature detection over every committed corpus file plus hostile short
/// inputs. Detection reads only a short prefix, never the body, and never
/// throws.
@Suite("Metafile signature detection")
struct MetafileSignatureTests {

    @Test("every corpus file sniffs to its expected format", arguments: [
        ("gate-p2-star.emf", MetafileFormat.emf),
        ("gate-p2-house.emf", .emf),
        ("gate-p2-triangles.emf", .emf),
        ("gate-p3-shapes.emf", .emf),
        ("gate-p3-curves.emf", .emf),
        ("gate-p4-text.emf", .emf),
        ("gate-p4-image.emf", .emf),
        ("handmade-strokes-paths.emf", .emf),
        ("handmade-cjk-text.emf", .emf),
        ("handmade-emfplus-dual.emf", .emf),
        ("handmade-emfplus-image.emf", .emf),
        ("handmade-emfplus-shapes.emf", .emf),
        ("handmade-emfplus-text.emf", .emf),
        ("gate-p2-star.emz", .gzip),
        ("gate-p3-shapes.emz", .gzip),
        ("gate-p4-text.emz", .gzip),
        ("handmade-wmf-standard.wmf", .wmf),
        ("handmade-wmf-placeable.wmf", .placeableWMF),
    ])
    func corpusFormats(_ expectation: (name: String, format: MetafileFormat)) throws {
        let data = try MetafileCorpus.data(expectation.name)
        let signature = MetafileSignature.detect(data)
        #expect(signature.format == expectation.format)
    }

    @Test("a clean placeable WMF raises no checksum diagnostic")
    func placeableChecksumClean() throws {
        let data = try MetafileCorpus.data("handmade-wmf-placeable.wmf")
        let signature = MetafileSignature.detect(data)
        #expect(signature.format == .placeableWMF)
        #expect(signature.diagnostics.isEmpty)
    }

    @Test("a wrong placeable checksum is a diagnostic, not a rejection")
    func placeableChecksumMismatch() throws {
        var bytes = Array(try MetafileCorpus.data("handmade-wmf-placeable.wmf"))
        // Corrupt the stored Checksum WORD at offset 20 ([MS-WMF] §2.3.2.3).
        bytes[20] ^= 0xFF
        let signature = MetafileSignature.detect(Data(bytes))
        #expect(signature.format == .placeableWMF, "a bad checksum must not change the format")
        #expect(signature.diagnostics.contains {
            if case .placeableChecksumMismatch = $0 { return true }
            return false
        })
    }

    @Test("gzip magic sniffs to .gzip")
    func gzipMagic() {
        #expect(MetafileSignature.detect(Data([0x1F, 0x8B, 0x08, 0x00, 0x00])).format == .gzip)
    }

    @Test("a non-DEFLATE gzip CM is not advertised as gzip")
    func gzipNonDeflate() {
        // ID1/ID2 match but CM is not 8 — not an inflatable member.
        #expect(MetafileSignature.detect(Data([0x1F, 0x8B, 0x09, 0x00, 0x00])).format == .unknown)
    }

    @Test("short and truncated prefixes are .unknown and never crash", arguments: [0, 1, 2, 3, 8, 20, 40, 43])
    func shortPrefixes(_ length: Int) throws {
        // A prefix of a real EMF shorter than the 44 bytes the EMF sniff needs
        // must fall through to .unknown rather than mis-detect or trap.
        let emf = Array(try MetafileCorpus.data("gate-p2-star.emf"))
        let prefix = Data(emf.prefix(length))
        #expect(MetafileSignature.detect(prefix).format == .unknown)
    }

    @Test("empty input is .unknown")
    func emptyInput() {
        #expect(MetafileSignature.detect(Data()).format == .unknown)
    }

    @Test("arbitrary garbage is .unknown")
    func garbage() {
        let bytes = (0 ..< 128).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        #expect(MetafileSignature.detect(Data(bytes)).format == .unknown)
    }

    @Test("the placeable key with an implausible META_HEADER is not placeable")
    func placeableKeyWithoutHeader() {
        // Key present, but the following 22-byte region has no plausible
        // META_HEADER — must not be reported as placeable WMF.
        var bytes: [UInt8] = [0xD7, 0xCD, 0xC6, 0x9A]   // 0x9AC6CDD7 LE
        bytes += [UInt8](repeating: 0x00, count: 40)    // zeros, not a META_HEADER
        #expect(MetafileSignature.detect(Data(bytes)).format == .unknown)
    }
}
