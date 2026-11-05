import Foundation
import Testing
import EMFParse
import EMFWrite
import WMFParse

/// Re-emit round-trip over every committed `corpus/*.wmf` / `*.wmz` (and any
/// `corpus-local` WMFs, reported by count only): parse → re-emit → parse yields an
/// EQUAL record stream, every preserved header/placeable field is unchanged, and
/// the recomputed fields (Size, NumberOfObjects, MaxRecord, Checksum) are correct
/// and stable (a second re-emit is byte-identical).
@Suite("WMF re-emit round-trip")
struct WMFReEmitCorpusTests {

    struct RoundTrip {
        var recordsEqual = true
        var headerPreserved = true
        var placeablePreserved = true
        var recomputedCorrect = true
        var idempotent = true
        var byteIdentical = false
        var origBytes = 0
        var reBytes = 0
        var origObjects: UInt16 = 0
        var reObjects: UInt16 = 0
        var origMaxRecord: UInt32 = 0
        var reMaxRecord: UInt32 = 0
        var origChecksumOK = true
        var hadTrailing = false
    }

    /// Opens (inflating a .wmz), parses, re-emits, and re-parses; checks every
    /// invariant and returns the per-file facts for the summary table.
    static func roundTrip(_ wmfBytes: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> RoundTrip {
        let file = try WMFFile.parse(wmfBytes)
        let reemitted = try WMFDocumentWriter.reEmit(file, source: wmfBytes)
        let file2 = try WMFFile.parse(reemitted)

        var r = RoundTrip()
        r.origBytes = wmfBytes.count
        r.reBytes = reemitted.count
        r.byteIdentical = Data(reemitted) == wmfBytes
        r.origObjects = file.header.numberOfObjects
        r.reObjects = file2.header.numberOfObjects
        r.origMaxRecord = file.header.maxRecord
        r.reMaxRecord = file2.header.maxRecord
        r.origChecksumOK = file.placeable?.checksumOK ?? true
        r.hadTrailing = file.diagnostics.contains { if case .trailingBytesAfterEOF = $0 { return true }; return false }

        // 1. Record stream equal (function + size, in order). Passthrough keeps
        //    the bytes, so offsets line up too.
        r.recordsEqual = file.records.count == file2.records.count
            && zip(file.records, file2.records).allSatisfy {
                $0.function == $1.function && $0.sizeWords == $1.sizeWords
            }

        // 2. Preserved META_HEADER fields unchanged.
        r.headerPreserved = file.header.type == file2.header.type
            && file.header.headerSizeWords == file2.header.headerSizeWords
            && file.header.version == file2.header.version
            && file.header.numberOfMembers == file2.header.numberOfMembers

        // 3. Placeable presence + BoundingBox + Inch preserved.
        switch (file.placeable, file2.placeable) {
        case (nil, nil):
            break
        case let (p1?, p2?):
            r.placeablePreserved = p1.boundingBox == p2.boundingBox && p1.inch == p2.inch
            // The re-emitted placeable checksum is recomputed and MUST verify.
            r.recomputedCorrect = r.recomputedCorrect && p2.checksumOK
        default:
            r.placeablePreserved = false
        }

        // 4. Recomputed Size/MaxRecord are self-consistent in the re-emitted file.
        let metaOffset2 = file2.placeable != nil ? 22 : 0
        let metafileBytes2 = file2.bytesWalked - metaOffset2
        let maxRecord2 = file2.records.map { $0.sizeWords }.max() ?? 0
        r.recomputedCorrect = r.recomputedCorrect
            && Int(file2.header.metafileSizeWords) * 2 == metafileBytes2
            && file2.header.maxRecord == maxRecord2

        // 5. Idempotent: a second re-emit changes nothing.
        let reemitted2 = try WMFDocumentWriter.reEmit(file2, source: reemitted)
        r.idempotent = Data(reemitted2) == Data(reemitted)

        return r
    }

    @Test func committedCorpusRoundTrips() throws {
        let names = committedWMFCorpus()
        #expect(!names.isEmpty, "no committed WMF corpus files found")

        var rows: [(String, RoundTrip)] = []
        for name in names {
            let raw = try corpusData(name)
            // .wmz is inflated through the front door; .wmf passes through.
            let opened = try OpenedMetafile.open(raw)
            let r = try Self.roundTrip(opened.data)
            #expect(r.recordsEqual, "\(name): record stream changed")
            #expect(r.headerPreserved, "\(name): a preserved header field changed")
            #expect(r.placeablePreserved, "\(name): placeable BoundingBox/Inch changed")
            #expect(r.recomputedCorrect, "\(name): a recomputed field is inconsistent")
            #expect(r.idempotent, "\(name): re-emit is not idempotent")
            // Every committed WMF over-declares (or exactly declares) its object
            // table, so with the no-lower rule each re-emits byte-identical.
            #expect(r.byteIdentical, "\(name): expected a byte-identical re-emit")
            rows.append((name, r))
        }

        // Summary table (read from the test log for the round-trip report).
        print("=== WMF re-emit round-trip (committed) ===")
        for (name, r) in rows {
            let why: String
            if r.byteIdentical {
                why = "byte-identical"
            } else {
                var diffs: [String] = []
                if r.origObjects != r.reObjects { diffs.append("NumberOfObjects \(r.origObjects)→\(r.reObjects)") }
                if r.origMaxRecord != r.reMaxRecord { diffs.append("MaxRecord \(r.origMaxRecord)→\(r.reMaxRecord)") }
                if !r.origChecksumOK { diffs.append("placeable Checksum corrected") }
                if r.hadTrailing { diffs.append("trailing bytes after EOF dropped") }
                if r.reBytes != r.origBytes { diffs.append("bytes \(r.origBytes)→\(r.reBytes)") }
                why = diffs.isEmpty ? "differs (size/other recomputed)" : diffs.joined(separator: ", ")
            }
            print("  \(name): \(why)")
        }
    }

    @Test func corpusLocalRoundTrips() throws {
        let files = corpusLocalWMFFiles()
        guard !files.isEmpty else {
            print("=== WMF re-emit round-trip (corpus-local): 0 files present ===")
            return
        }
        var parseable = 0, recordEqual = 0, byteIdentical = 0
        for url in files {
            guard let raw = try? Data(contentsOf: url),
                  let opened = try? OpenedMetafile.open(raw),
                  let r = try? Self.roundTrip(opened.data)
            else { continue }
            parseable += 1
            if r.recordsEqual && r.headerPreserved && r.placeablePreserved && r.recomputedCorrect && r.idempotent {
                recordEqual += 1
            }
            if r.byteIdentical { byteIdentical += 1 }
        }
        // Counts only — work-sourced names are confidential.
        print("=== WMF re-emit round-trip (corpus-local) ===")
        print("  present: \(files.count), parseable: \(parseable), all-invariants: \(recordEqual), byte-identical: \(byteIdentical)")
        #expect(recordEqual == parseable, "some corpus-local WMF failed a round-trip invariant")
    }

    @Test func wmzReEmitRoundTrips() throws {
        // Re-emit a committed WMF, gzip it, and confirm the front door inflates it
        // back to the same WMF bytes (WMZ = gzip(WMF), GzipWriter reused).
        let raw = try corpusData("gate-wmf-gdi-p2-star.wmf")
        let file = try WMFFile.parse(raw)
        let reemitted = try WMFDocumentWriter.reEmit(file, source: raw)
        let wmz = try WMFDocumentWriter.reEmitCompressed(file, source: raw)
        let opened = try OpenedMetafile.open(wmz)
        #expect(opened.wasDecompressed, "WMZ was not recognised as gzip")
        #expect(Data(opened.data) == Data(reemitted), "inflated WMZ differs from the re-emitted WMF")
    }
}
