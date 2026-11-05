import Foundation
import Testing
import EMFParse
import EMFRender
import EMFWrite

/// The two reassembled EMF+ record streams are equal when they have the same
/// record count and every record matches on Type, Flags and reassembled data —
/// the contract a repackage must preserve (task 6).
func plusStreamEqual(_ a: EMFFile, _ b: EMFFile) -> Bool {
    let ra = a.emfPlusStream().records
    let rb = b.emfPlusStream().records
    guard ra.count == rb.count else { return false }
    for i in ra.indices where ra[i].type != rb[i].type || ra[i].flags != rb[i].flags || ra[i].data != rb[i].data {
        return false
    }
    return true
}

/// The GDI (non-comment) drawing records survive a repackage unchanged: same
/// payloads, in order. Header (type 1) and EOF (type 14) are excluded — their
/// recomputed bytes change but their payloads do not.
func gdiRecordsEqual(_ a: EMFFile, _ b: EMFFile) -> Bool {
    func gdi(_ f: EMFFile) -> [EMFRecordPayload] {
        f.records.filter { $0.type != 70 && $0.type != 1 && $0.type != 14 }.map { f.payload(of: $0) }
    }
    return gdi(a) == gdi(b)
}

@Suite("EMF+ repackage round-trip (parse → repackage → parse)")
struct EMFPlusRepackageTests {

    /// Every committed EMF/EMZ with EMF+ content repackages to an equal EMF+
    /// record stream with the dual flag preserved; files without EMF+ content
    /// repackage byte-identically to passthrough.
    @Test func committedCorpusRepackages() throws {
        var withPlus = 0, withoutPlus = 0
        for name in committedEMFCorpus() {
            let raw = try corpusData(name)
            let emf = name.hasSuffix(".emz") ? try OpenedMetafile.open(raw).data : raw
            let file1 = try EMFFile.parse(emf)
            let repacked = try EMFDocumentWriter.reEmit(file1, source: emf, repackageEMFPlus: true)
            let file2 = try EMFFile.parse(repacked)

            if file1.emfPlusStream().records.isEmpty {
                // No EMF+ — repackage must equal passthrough byte-for-byte.
                let passthrough = try EMFDocumentWriter.reEmit(file1, source: emf)
                #expect([UInt8](repacked) == [UInt8](passthrough), "\(name): no-EMF+ repackage drifted from passthrough")
                withoutPlus += 1
                continue
            }
            withPlus += 1

            #expect(plusStreamEqual(file1, file2), "\(name): EMF+ record stream differs")
            #expect(file1.emfPlusIsDual() == file2.emfPlusIsDual(), "\(name): dual flag changed")
            #expect(gdiRecordsEqual(file1, file2), "\(name): GDI fallback records changed")
            // The re-parsed header accounting is correct for the bytes written.
            #expect(file2.header.bytes == UInt32(repacked.count), "\(name): Bytes wrong")
            #expect(Int(file2.header.records) == file2.records.count, "\(name): Records wrong")
            print("[repackage] \(name): EMF+ stream \(file1.emfPlusStream().records.count) records, "
                  + "dual \(file1.emfPlusIsDual()), \(emf.count)B → \(repacked.count)B")
        }
        #expect(withPlus >= 4, "expected at least the 4 handmade EMF+ files; saw \(withPlus)")
        print("[repackage] committed: \(withPlus) with EMF+, \(withoutPlus) without")
    }

    /// corpus-local/ is gitignored and may be absent; work-sourced files there are
    /// CONFIDENTIAL — reported as COUNTS ONLY (no names, no content). Every local
    /// EMF with EMF+ content must repackage to an equal EMF+ record stream with
    /// the dual flag preserved.
    @Test func corpusLocalRepackagesCountsOnly() throws {
        let files = corpusLocalFiles()
        var parsed = 0, withPlus = 0, streamEqual = 0, dualPreserved = 0
        for url in files {
            guard let raw = try? Data(contentsOf: url) else { continue }
            let isEMZ = url.pathExtension.lowercased() == "emz"
            guard let emf = try? (isEMZ ? OpenedMetafile.open(raw).data : raw),
                  let file1 = try? EMFFile.parse(emf),
                  let repacked = try? EMFDocumentWriter.reEmit(file1, source: emf, repackageEMFPlus: true),
                  let file2 = try? EMFFile.parse(repacked)
            else { continue }
            parsed += 1
            guard !file1.emfPlusStream().records.isEmpty else { continue }
            withPlus += 1
            if plusStreamEqual(file1, file2) { streamEqual += 1 }
            if file1.emfPlusIsDual() == file2.emfPlusIsDual() { dualPreserved += 1 }
        }
        print("[repackage corpus-local] present: \(files.count), parsed: \(parsed), "
              + "with EMF+: \(withPlus), stream-equal: \(streamEqual), dual-preserved: \(dualPreserved)")
        // Every local EMF with EMF+ content must round-trip its EMF+ stream.
        #expect(streamEqual == withPlus)
        #expect(dualPreserved == withPlus)
    }

    /// An EMF+ object larger than one comment is split through the continuation
    /// mechanism and reassembled by EMFParse to the exact same bytes.
    @Test func largeObjectContinuationReassembles() throws {
        // A ~10 KB image object payload.
        let pixels = [UInt8](repeating: 0x7E, count: 10_000)
        let image = EMFPlusImage(
            version: 1,
            content: .bitmap(
                EMFPlusImageBitmapHeader(width: 50, height: 50, stride: 200, pixelFormat: 0x26200A, bitmapDataType: 0),
                data: Data(pixels)))
        let payload = try EMFPlusObjectEncoder.encode(.image(image))

        // Split with a small record cap → many 0x4008 records; pack with a small
        // comment cap → many comments.
        let records = EMFPlusCommentWriter.objectRecords(
            objectID: 3, objectType: .image, payload: payload, maxObjectDataSize: 1024)
        #expect(records.count > 1, "object was not split (got \(records.count) record)")
        var stream: [UInt8] = []
        for record in records { stream.append(contentsOf: record) }
        let comments = EMFPlusCommentWriter.packComments(streamBytes: stream, maxCommentPayload: 2048)

        // Wrap in a minimal EMF and parse.
        var fixture = LE()
        let total = 108 + comments.count + 20
        fixture.raw(LE.header108(records: 3, bytes: UInt32(total)))
        fixture.raw(comments)
        fixture.raw(LE.eof())
        let file = try EMFFile.parse(Data(fixture.bytes))

        let plus = file.emfPlusStream()
        #expect(plus.records.allSatisfy { $0.type == 0x4008 }, "unexpected record types in stream")
        #expect(plus.records.count > 1, "expected several comment-fragmented records")

        let (definitions, diagnostics) = plus.objectDefinitions()
        #expect(definitions.count == 1, "expected one reassembled object, got \(definitions.count)")
        #expect(diagnostics.isEmpty, "continuation diagnostics: \(diagnostics)")
        #expect(definitions.first?.objectID == 3)
        #expect(definitions.first.map { [UInt8]($0.data) } == payload, "reassembled bytes differ from the original payload")
    }

    /// A single-record object (fits one comment) is emitted with the Continuable
    /// flag CLEAR and no TotalObjectSize prefix.
    @Test func smallObjectIsNotContinued() throws {
        let payload: [UInt8] = Array(0 ..< 40)
        let records = EMFPlusCommentWriter.objectRecords(objectID: 7, objectType: .brush, payload: payload)
        #expect(records.count == 1)
        // Flags at offset 2 (u16, little-endian): C clear, type brush (1) << 8, id 7.
        let flags = UInt16(records[0][2]) | (UInt16(records[0][3]) << 8)
        #expect(flags & 0x8000 == 0, "Continuable flag set on a single-record object")
        #expect(flags == (UInt16(EMFPlusObjectType.brush.rawValue) << 8 | 7))
        // DataSize at offset 8 equals the payload length (no 4-byte prefix).
        let dataSize = records[0][8...11].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        #expect(dataSize == UInt32(payload.count))
    }
}
