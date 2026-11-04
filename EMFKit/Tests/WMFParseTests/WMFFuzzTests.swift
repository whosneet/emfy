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
        for name in WMFCorpus.wmfFiles {
            let original = Array(try WMFCorpus.data(name))
            for _ in 0 ..< perFile {
                let mutated = Data(mutate(original, using: &prng))
                if let file = try? WMFFile.parse(mutated) {
                    // The translation and reassembly paths must never trap or
                    // hang on a hostile WMF (§8) — bounded work, any result.
                    _ = WMFTranslator.translate(file)
                    _ = WMFEmbeddedEMF.reassemble(file)
                }
                runs += 1
            }
        }
        #expect(runs == WMFCorpus.wmfFiles.count * perFile)
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
