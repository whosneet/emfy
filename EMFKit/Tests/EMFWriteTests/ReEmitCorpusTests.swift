import CoreGraphics
import Foundation
import Testing
import EMFParse
import EMFRender
import EMFWrite

/// Two parsed files have the same record stream when they have the same record
/// count and order and every record decodes to an equal payload — this covers
/// both typed-encoded records (payload preserved) and passthrough records (raw
/// bytes, hence payload, preserved).
func recordStreamEqual(_ a: EMFFile, _ b: EMFFile) -> Bool {
    guard a.records.count == b.records.count else { return false }
    for i in 0 ..< a.records.count where a.payload(of: a.records[i]) != b.payload(of: b.records[i]) {
        return false
    }
    return true
}

/// The header fields that must survive a re-emit unchanged (everything but the
/// recomputed Bytes/Records/Handles).
func headerPreserved(_ a: EMFFile, _ b: EMFFile) -> Bool {
    a.header.bounds == b.header.bounds
        && a.header.frame == b.header.frame
        && a.header.device == b.header.device
        && a.header.millimeters == b.header.millimeters
        && a.header.description == b.header.description
        && a.header.nDescription == b.header.nDescription
        && a.header.offDescription == b.header.offDescription
        && a.header.nPalEntries == b.header.nPalEntries
        && a.header.recordSignature == b.header.recordSignature
        && a.header.version == b.header.version
        && a.header.variant == b.header.variant
        && a.header.extension1 == b.header.extension1
        && a.header.extension2 == b.header.extension2
}

/// Inflates a `.emz` input; passes a plain `.emf` through unchanged.
private func emfBytes(of raw: Data, isEMZ: Bool) throws -> Data {
    isEMZ ? try OpenedMetafile.open(raw).data : raw
}

@Suite("Re-emit corpus round-trip (parse → write → parse)")
struct ReEmitCorpusTests {

    @Test func committedCorpusRoundTrips() throws {
        var identicalCount = 0
        var total = 0
        for name in committedEMFCorpus() {
            total += 1
            let raw = try corpusData(name)
            let emf = try emfBytes(of: raw, isEMZ: name.hasSuffix(".emz"))
            let file1 = try EMFFile.parse(emf)
            let written = try EMFDocumentWriter.reEmit(file1, source: emf)
            let file2 = try EMFFile.parse(written)

            #expect(recordStreamEqual(file1, file2), "\(name): record stream differs")
            #expect(headerPreserved(file1, file2), "\(name): header field changed")
            // Recomputed fields are now correct for the bytes written.
            #expect(file2.header.bytes == UInt32(written.count), "\(name): Bytes wrong")
            #expect(Int(file2.header.records) == file2.records.count, "\(name): Records wrong")
            #expect(file2.diagnostics.allSatisfy { !isCountMismatch($0) }, "\(name): stale count diagnostic")

            let identical = [UInt8](written) == [UInt8](emf)
            if identical { identicalCount += 1 }
            if let dir = ProcessInfo.processInfo.environment["EMFY_EMZ_DUMP_DIR"] {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
                try? written.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent(name + ".reemit"))
            }
            print("[corpus] \(name): \(identical ? "BYTE-IDENTICAL" : "record-equal")"
                  + " (orig \(emf.count)B → written \(written.count)B, \(file1.records.count) records)")
        }
        print("[corpus] \(identicalCount)/\(total) committed EMF/EMZ files byte-identical end to end")
    }

    /// A proxy for render-equivalence (full pixel comparison is E0d): equal
    /// record streams must drive an equal render log through the real renderer.
    @Test(arguments: ["gate-p2-star.emf", "gate-p3-shapes.emf", "gate-p4-text.emf", "gate-p4-image.emf"])
    func reEmittedRendersIdentically(_ name: String) throws {
        let emf = try corpusData(name)
        let file1 = try EMFFile.parse(emf)
        let written = try EMFDocumentWriter.reEmit(file1, source: emf)
        let file2 = try EMFFile.parse(written)

        let log1 = renderLog(file1)
        let log2 = renderLog(file2)
        #expect(log1 == log2, "\(name): re-emitted render log differs")
    }

    private func renderLog(_ file: EMFFile) -> EMFRenderLog {
        let width = 128, height = 128
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return EMFRenderLog() }
        return EMFRenderer.render(file, into: ctx,
                                  target: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// corpus-local/ is gitignored and may be absent; work-sourced files there
    /// are CONFIDENTIAL. Reported as COUNTS ONLY — no names, no content. Every
    /// file that parses as EMF must round-trip to an equal record stream.
    @Test func corpusLocalRoundTripsCountsOnly() throws {
        let files = corpusLocalFiles()
        var parsed = 0, recordEqual = 0, byteIdentical = 0
        for url in files {
            guard let raw = try? Data(contentsOf: url) else { continue }
            let isEMZ = url.pathExtension.lowercased() == "emz"
            guard let emf = try? emfBytes(of: raw, isEMZ: isEMZ),
                  let file1 = try? EMFFile.parse(emf),
                  let written = try? EMFDocumentWriter.reEmit(file1, source: emf),
                  let file2 = try? EMFFile.parse(written)
            else { continue }
            parsed += 1
            if recordStreamEqual(file1, file2) && headerPreserved(file1, file2) { recordEqual += 1 }
            if [UInt8](written) == [UInt8](emf) { byteIdentical += 1 }
        }
        print("[corpus-local] present: \(files.count), parsed: \(parsed), "
              + "record-equal: \(recordEqual), byte-identical: \(byteIdentical)")
        // Every parseable local EMF must round-trip to an equal record stream.
        #expect(recordEqual == parsed)
    }

    private func isCountMismatch(_ d: EMFDiagnostic) -> Bool {
        switch d {
        case .recordCountMismatch, .byteCountMismatch: return true
        default: return false
        }
    }
}
