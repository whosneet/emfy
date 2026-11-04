import Foundation
import Testing
import EMFParse
@testable import WMFParse

/// A mutation-fuzz survival floor over the corpus WMFs, the same style as W2's
/// `.emz` fuzz. Mutated bytes fed to the parser (and to the front door for the
/// `.wmz`) must never trap or hang: a typed throw, a diagnostic-laden partial
/// parse, or a clean parse are all acceptable — the PASS criterion is simply
/// reaching the end for every iteration (§6/§8).
@Suite("WMF mutation fuzz (survival)")
struct WMFFuzzTests {

    @Test("mutated corpus WMF bytes survive WMFFile.parse")
    func fuzzMutatedWMF() throws {
        var prng = WMFPRNG(seed: 0xD1B5_4A32_D192_ED03)
        let perFile = 200
        var runs = 0
        for name in WMFCorpus.wmfFiles {
            let original = Array(try WMFCorpus.data(name))
            for _ in 0 ..< perFile {
                let mutated = Data(mutate(original, using: &prng))
                // A throw or a partial parse is fine; the point is survival.
                _ = try? WMFFile.parse(mutated)
                runs += 1
            }
        }
        #expect(runs == WMFCorpus.wmfFiles.count * perFile)
    }

    @Test("mutated .wmz bytes survive the front door and the WMF parser")
    func fuzzMutatedWMZ() throws {
        var prng = WMFPRNG(seed: 0x51E7_7C19_B0A4_33DD)
        let original = Array(try WMFCorpus.data("gate-wmf-p2-star.wmz"))
        var runs = 0
        for _ in 0 ..< 400 {
            let mutated = Data(mutate(original, using: &prng))
            if let opened = try? OpenedMetafile.open(mutated),
               opened.format == .placeableWMF || opened.format == .wmf {
                _ = try? WMFFile.parse(opened.data)
            }
            runs += 1
        }
        #expect(runs == 400)
    }

    @Test("mutated corpus WMF bytes survive the translator and embedded-EMF reassembly")
    func fuzzMutatedTranslation() throws {
        var prng = WMFPRNG(seed: 0x7A3C_1F08_55B2_90E1)
        let perFile = 200
        var runs = 0
        // Traversal floor (plan §3 W6): mutants whose translation produced at least
        // one record payload BEYOND the 5-payload page-setup preamble (i.e. that
        // actually reached WMF record translation, not merely a header parse).
        var reachedRecordTranslation = 0
        for name in WMFCorpus.wmfFiles {
            let original = Array(try WMFCorpus.data(name))
            for _ in 0 ..< perFile {
                let mutated = Data(mutate(original, using: &prng))
                if let file = try? WMFFile.parse(mutated) {
                    // The translation and reassembly paths must never trap or
                    // hang on a hostile WMF (§8) — bounded work, any result.
                    let program = WMFTranslator.translate(file)
                    if program.payloads.count > 5 { reachedRecordTranslation += 1 }
                    _ = WMFEmbeddedEMF.reassemble(file)
                }
                runs += 1
            }
        }
        #expect(runs == WMFCorpus.wmfFiles.count * perFile)
        // A zero here means every mutant stopped at the header — the record
        // translation surface went dark (well below the observed count).
        #expect(reachedRecordTranslation >= 100,
                "too few mutants reached WMF record translation: \(reachedRecordTranslation)")
    }

    @Test("mutated GDI-variant WMFs survive translation of the W4b decoders")
    func fuzzMutatedGDIVariants() throws {
        var prng = WMFPRNG(seed: 0x2C9F_18A7_44E1_6B0D)
        let perFile = 200
        var runs = 0
        var reachedRecordTranslation = 0
        for name in WMFCorpus.gdiVariantFiles {
            // The p4 pair is uncommitted until the gate is accepted; skip if absent.
            guard let original = try? WMFCorpus.data(name) else { continue }
            let bytes = Array(original)
            for _ in 0 ..< perFile {
                let mutated = Data(mutate(bytes, using: &prng))
                if let file = try? WMFFile.parse(mutated) {
                    // Text, bitmap, region and pattern-brush decoders must never
                    // trap or hang on a hostile WMF (§8) — bounded work, any result.
                    let program = WMFTranslator.translate(file)
                    if program.payloads.count > 5 { reachedRecordTranslation += 1 }
                }
                runs += 1
            }
        }
        // Traversal floor (plan §3 W6): the GDI variants carry only records (no
        // embedded EMF), so a healthy share of mutants must reach record
        // translation — a zero would mean the W4b decoder surface went dark.
        #expect(reachedRecordTranslation >= 100,
                "too few GDI-variant mutants reached record translation: \(reachedRecordTranslation)")
    }

    @Test("mutated hand-built content records survive the new decoders")
    func fuzzHandBuiltContentRecords() throws {
        var prng = WMFPRNG(seed: 0x9D41_77C2_5EA0_3B16)
        // A standard WMF carrying one of each new record kind (text, DIB blits,
        // DDB, region, pattern brush), each mutated and translated.
        let records: [[UInt8]] = [
            // CREATEFONTINDIRECT (18-byte fixed + 32-byte facename).
            WMFFixtureBuilder.record(function: 0x02FB, payload: [UInt8](repeating: 0x41, count: 50)),
            WMFFixtureBuilder.record(function: 0x012D, payload: [0, 0]),                 // SELECTOBJECT 0
            // TEXTOUT: StringLength 4, "test", YStart, XStart.
            WMFFixtureBuilder.record(function: 0x0521, payload: [4, 0] + Array("test".utf8) + [0, 0, 0, 0]),
            // EXTTEXTOUT: Y, X, len=2, fwOpts=ETO_CLIPPED, rect, "ab", dx.
            WMFFixtureBuilder.record(function: 0x0A32, payload: [0, 0, 0, 0, 2, 0, 4, 0, 1, 0, 2, 0, 3, 0, 4, 0] + Array("ab".utf8) + [9, 0, 8, 0]),
            // STRETCHDIB with a 1×1 24-bit DIB.
            WMFFixtureBuilder.record(function: 0x0F43, payload: [0x20, 0, 0xCC, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0]
                + Self.bitmapInfoHeader24(1, 1) + [0, 0, 255, 0]),
            // BITBLT carrying a 1-bpp mono Bitmap16.
            WMFFixtureBuilder.record(function: 0x0922, payload: [0x20, 0, 0xCC, 0, 0, 0, 0, 0, 1, 0, 8, 0, 0, 0, 0, 0]
                + [0, 0, 8, 0, 1, 0, 2, 0, 1, 1, 0xAA, 0]),
            // CREATEREGION with one scan.
            WMFFixtureBuilder.record(function: 0x06FF, payload: [0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 0, 0, 50, 0, 50, 0, 2, 0, 0, 0, 30, 0, 0, 0, 40, 0, 2, 0]),
            WMFFixtureBuilder.record(function: 0x012C, payload: [1, 0]),                 // SELECTCLIPREGION 1
            WMFFixtureBuilder.record(function: 0x0228, payload: [1, 0, 0, 0]),           // FILLREGION
            WMFFixtureBuilder.record(function: 0x0142, payload: [5, 0, 0, 0] + Self.bitmapInfoHeader24(1, 1) + [0, 0, 0, 0]),   // DIBCREATEPATTERNBRUSH
        ]
        let base = Array(WMFFixtureBuilder.file(
            header: WMFFixtureBuilder.metaHeader(),
            records: records + [WMFFixtureBuilder.eof()]
        ))
        var runs = 0
        for _ in 0 ..< 3000 {
            let mutated = Data(mutate(base, using: &prng))
            if let file = try? WMFFile.parse(mutated) {
                _ = WMFTranslator.translate(file)
                _ = WMFEmbeddedEMF.reassemble(file)
            }
            runs += 1
        }
        #expect(runs == 3000)
    }

    /// A 40-byte BitmapInfoHeader for a tiny BI_RGB DIB fixture.
    private static func bitmapInfoHeader24(_ width: Int32, _ height: Int32) -> [UInt8] {
        var b = WMFFixtureBuilder()
        b.appendUInt32(40)
        b.appendUInt32(UInt32(bitPattern: width))
        b.appendUInt32(UInt32(bitPattern: height))
        b.appendUInt16(1); b.appendUInt16(24)
        b.appendUInt32(0)
        b.appendUInt32(0); b.appendUInt32(0); b.appendUInt32(0)
        b.appendUInt32(0); b.appendUInt32(0)
        return b.bytes
    }

    /// 1–6 bounded mutations: byte flip, 4-byte stomp, truncation, small append.
    private func mutate(_ bytes: [UInt8], using prng: inout WMFPRNG) -> [UInt8] {
        var out = bytes
        let count = Int(prng.next() % 6) + 1
        for _ in 0 ..< count {
            guard !out.isEmpty else { break }
            switch prng.next() % 4 {
            case 0:
                let i = Int(prng.next() % UInt64(out.count))
                out[i] ^= UInt8(truncatingIfNeeded: prng.next() | 1)
            case 1:
                guard out.count >= 4 else { continue }
                let i = Int(prng.next() % UInt64(out.count - 3))
                for k in 0 ..< 4 { out[i + k] = UInt8(truncatingIfNeeded: prng.next()) }
            case 2:
                let cut = Int(prng.next() % UInt64(out.count))
                out.removeLast(out.count - cut)
                return out
            default:
                let extra = Int(prng.next() % 32) + 1
                for _ in 0 ..< extra { out.append(UInt8(truncatingIfNeeded: prng.next())) }
            }
        }
        return out
    }
}
