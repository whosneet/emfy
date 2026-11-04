import Foundation
import Testing
@testable import EMFParse

/// The front door: sniff + one-level gzip unwrap. Covers plain pass-through,
/// .emz round-trips, gzip→WMF, nested-gzip refusal, error propagation, and a
/// mutation-fuzz survival floor over .emz bytes.
@Suite("Metafile front door")
struct MetafileFrontDoorTests {

    private func openError(_ data: Data) -> MetafileOpenError? {
        do {
            _ = try OpenedMetafile.open(data)
            return nil
        } catch {
            return error
        }
    }

    @Test("a plain file opens unchanged, not decompressed", arguments: [
        ("gate-p2-star.emf", MetafileFormat.emf),
        ("gate-p3-curves.emf", .emf),
        ("handmade-wmf-standard.wmf", .wmf),
        ("handmade-wmf-placeable.wmf", .placeableWMF),
    ])
    func plainOpen(_ pair: (name: String, format: MetafileFormat)) throws {
        let data = try MetafileCorpus.data(pair.name)
        let opened = try OpenedMetafile.open(data)
        #expect(opened.format == pair.format)
        #expect(!opened.wasDecompressed)
        #expect(opened.data == data)
    }

    @Test("a .emz opens to its inner EMF, byte-identical", arguments: [
        ("gate-p2-star.emz", "gate-p2-star.emf"),
        ("gate-p3-shapes.emz", "gate-p3-shapes.emf"),
        ("gate-p4-text.emz", "gate-p4-text.emf"),
    ])
    func emzOpensToEmf(_ pair: (emz: String, emf: String)) throws {
        let emz = try MetafileCorpus.data(pair.emz)
        let emf = try MetafileCorpus.data(pair.emf)
        let opened = try OpenedMetafile.open(emz)
        #expect(opened.format == .emf)
        #expect(opened.wasDecompressed)
        #expect(opened.data == emf)
    }

    @Test("a gzip-wrapped WMF opens to the inner WMF")
    func gzipWrappedWMF() throws {
        let wmf = Array(try MetafileCorpus.data("handmade-wmf-placeable.wmf"))
        let wrapped = GzipFixture.make(payload: wmf)
        let opened = try OpenedMetafile.open(wrapped)
        #expect(opened.format == .placeableWMF)
        #expect(opened.wasDecompressed)
        #expect(opened.data == Data(wmf))
    }

    @Test("nested gzip is refused")
    func nestedGzipRefused() throws {
        let emf = Array(try MetafileCorpus.data("gate-p4-text.emf"))
        let inner = Array(GzipFixture.make(payload: emf))     // gzip(emf)
        let outer = GzipFixture.make(payload: inner)          // gzip(gzip(emf))
        #expect(openError(outer) == .nestedGzip)
    }

    @Test("a gzip inflate failure propagates as .gzip(...)")
    func gzipFailurePropagates() {
        var bytes = Array(GzipFixture.make(payload: Array("payload".utf8)))
        bytes[bytes.count - 8] ^= 0xFF   // corrupt the stored CRC
        guard case .gzip = openError(Data(bytes)) else {
            Issue.record("expected a .gzip-wrapped open error")
            return
        }
    }

    @Test("an unrecognised file opens as .unknown without throwing")
    func unknownDoesNotThrow() throws {
        let bytes = (0 ..< 200).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        let opened = try OpenedMetafile.open(Data(bytes))
        #expect(opened.format == .unknown)
        #expect(!opened.wasDecompressed)
    }

    @Test("a placeable WMF with a bad checksum surfaces a sniff diagnostic")
    func placeableChecksumDiagnosticFlows() throws {
        var bytes = Array(try MetafileCorpus.data("handmade-wmf-placeable.wmf"))
        bytes[20] ^= 0xFF
        let opened = try OpenedMetafile.open(Data(bytes))
        #expect(opened.format == .placeableWMF)
        #expect(opened.diagnostics.contains {
            if case .sniff(.placeableChecksumMismatch) = $0 { return true }
            return false
        })
    }

    // MARK: - Fuzz floor (survival)

    /// Mutated .emz bytes fed through the front door must never trap or hang.
    /// A typed throw or a `.unknown` result is the correct, expected outcome on
    /// garbage; the PASS criterion is simply reaching the end (§6/§8).
    @Test("mutated .emz bytes survive the front door")
    func fuzzMutatedEmz() throws {
        var prng = W2PRNG(seed: 0x9E37_79B9_7F4A_7C15)
        let names = ["gate-p2-star.emz", "gate-p3-shapes.emz", "gate-p4-text.emz"]
        let perFile = 200
        var runs = 0
        for name in names {
            let original = Array(try MetafileCorpus.data(name))
            for _ in 0 ..< perFile {
                let mutated = Data(mutate(original, using: &prng))
                if let opened = try? OpenedMetafile.open(mutated),
                   opened.format == .emf {
                    _ = try? EMFFile.parse(opened.data)
                }
                runs += 1
            }
        }
        #expect(runs == names.count * perFile)
    }

    /// 1–6 bounded mutations: byte flip, 4-byte stomp, truncation, small append.
    private func mutate(_ bytes: [UInt8], using prng: inout W2PRNG) -> [UInt8] {
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

/// SplitMix64, local to this suite (the EMFRenderTests copy is in another
/// module). Deterministic for a given seed.
struct W2PRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
