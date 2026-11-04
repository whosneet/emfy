import Foundation
import Testing
import EMFParse
@testable import WMFParse

/// Parses every committed WMF and the gzip-wrapped `.wmz` through the real
/// parser, asserting the W3 gate: byte offsets account for the whole file, the
/// record inventory is non-empty, and the placeable checksum verifies.
@Suite("WMF corpus")
struct WMFCorpusTests {

    @Test("every corpus WMF parses; byte accounting covers the whole file",
          arguments: WMFCorpus.wmfFiles)
    func corpusWMFParses(_ name: String) throws {
        let data = try WMFCorpus.data(name)
        let file = try WMFFile.parse(data)

        // The walk reached META_EOF and tiled the whole file with no trailing
        // bytes: a clean, fully accounted file.
        #expect(file.records.last?.function == 0x0000, "\(name): last record is not META_EOF")
        #expect(file.bytesWalked == data.count, "\(name): walk did not reach the end")
        #expect(file.diagnostics.isEmpty, "\(name): unexpected diagnostics \(file.diagnostics)")

        // Byte accounting: header + Σ record bytes + trailing == file size.
        let headerBytes = file.headerByteCount
        let recordBytes = file.bytesWalked - file.headerByteCount
        let trailing = data.count - file.bytesWalked
        #expect(headerBytes + recordBytes + trailing == data.count)
        #expect(trailing == 0)

        // The inventory is non-empty, and its total bytes equal the record span.
        let inventory = file.recordInventory()
        #expect(!inventory.isEmpty, "\(name): empty inventory")
        #expect(inventory.reduce(0) { $0 + $1.totalBytes } == recordBytes)
    }

    @Test("every placeable corpus WMF verifies its checksum",
          arguments: WMFCorpus.placeableFiles)
    func placeableChecksumVerifies(_ name: String) throws {
        let data = try WMFCorpus.data(name)
        let file = try WMFFile.parse(data)

        let placeable = try #require(file.placeable, "\(name): expected a placeable header")
        let stored = String(placeable.checksumStored, radix: 16)
        let computed = String(placeable.checksumComputed, radix: 16)
        #expect(placeable.checksumOK, "\(name): checksum mismatch (stored 0x\(stored), computed 0x\(computed))")
        #expect(!file.diagnostics.contains {
            if case .placeableChecksumMismatch = $0 { return true }
            return false
        })
    }

    @Test("the standard (non-placeable) corpus export has no placeable header")
    func standardExportIsNonPlaceable() throws {
        let data = try WMFCorpus.data("gate-wmf-p4-image-standard.wmf")
        let file = try WMFFile.parse(data)
        #expect(file.placeable == nil)
        #expect(file.bytesWalked == data.count)
        #expect(file.records.last?.function == 0x0000)
    }

    /// The `.wmz` opens through the EMFParse front door (gzip unwrap), then
    /// parses as a WMF whose byte accounting covers the inflated bytes and whose
    /// records match the committed `.wmf` it wraps.
    @Test("the .wmz opens through the front door and parses byte-for-byte like its .wmf")
    func wmzOpensAndParses() throws {
        let wmz = try WMFCorpus.data("gate-wmf-p2-star.wmz")
        let opened = try OpenedMetafile.open(wmz)
        #expect(opened.format == .placeableWMF)
        #expect(opened.wasDecompressed)

        let fromWMZ = try WMFFile.parse(opened.data)
        #expect(fromWMZ.bytesWalked == opened.data.count)
        #expect(!fromWMZ.recordInventory().isEmpty)
        #expect(fromWMZ.diagnostics.isEmpty)

        // The inflated payload is the committed .wmf, so the parses agree.
        let direct = try WMFFile.parse(try WMFCorpus.data("gate-wmf-p2-star.wmf"))
        #expect(fromWMZ.records == direct.records)
        #expect(fromWMZ.header == direct.header)
        #expect(fromWMZ.placeable == direct.placeable)
    }
}
