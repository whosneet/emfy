import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Deterministic, CI-friendly mutation fuzzing of the whole parse+render
/// surface (primer §6 phase 6, §8). Each committed corpus file is copied and
/// hit with 1–8 random mutations drawn from the operators a hostile or corrupt
/// EMF would exhibit — byte flips, 4-byte stomps with adversarial values,
/// truncation, and header-territory corruption — then run end to end:
///
///   EMFFile.parse → payload(of:) for every record → emfPlusPresence →
///   render(into:target:) into a shared, bounded 256×256 context.
///
/// The PASS criterion is SURVIVAL: no crash, no trap, no hang. Diagnostics and
/// log entries are the expected, correct output on garbage input and are not
/// asserted on. A trap anywhere in the parse or render path crashes the test
/// process — which is exactly the regression this guards against.
///
/// Determinism: a fixed default seed reproduces the same mutant stream every
/// run. `EMFY_FUZZ_SEED` and `EMFY_FUZZ_ITERATIONS` override the seed and the
/// per-file mutant count for extended/CI passes.
@Suite("Mutation fuzz (survival)")
struct FuzzTests {

    /// The 8 committed corpus files (see corpus/README.md). Raw bytes are read
    /// and mutated; these are NOT parsed as corpus inputs here.
    static let corpusFiles = [
        "gate-p2-star.emf",
        "gate-p2-house.emf",
        "gate-p2-triangles.emf",
        "gate-p3-shapes.emf",
        "gate-p3-curves.emf",
        "gate-p4-text.emf",
        "gate-p4-image.emf",
        "handmade-strokes-paths.emf",
    ]

    /// Fixed default seed (SplitMix64's golden-ratio constant). Reproducible
    /// unless `EMFY_FUZZ_SEED` overrides it.
    static let defaultSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// Default mutants per corpus file; `EMFY_FUZZ_ITERATIONS` overrides it.
    /// Kept low so an everyday `swift test` stays fast; the phase-6 gate runs a
    /// deep pass with `EMFY_FUZZ_ITERATIONS=2000` explicitly.
    static let defaultIterations = 50

    static var seed: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["EMFY_FUZZ_SEED"],
           let value = UInt64(raw) {
            return value
        }
        return defaultSeed
    }

    static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["EMFY_FUZZ_ITERATIONS"],
           let value = Int(raw), value > 0 {
            return value
        }
        return defaultIterations
    }

    /// A running tally over one fuzz run, for the audit summary line.
    private struct Tally {
        var mutants = 0
        var parseRejects = 0
        var parsedWithDiagnostics = 0
        var parsedClean = 0
        var rendered = 0
    }

    @Test("every corpus file survives seeded mutation across the full surface")
    func fuzzCorpus() throws {
        // One shared, bounded 256×256 context for every render. makeImage is
        // deliberately NOT used: mutant header bounds are hostile by design and
        // would drive its (capped, but still large) allocation on every mutant.
        let context = try #require(Self.makeSharedContext(), "could not create shared 256×256 context")
        let target = CGRect(x: 0, y: 0, width: 256, height: 256)

        var prng = SplitMix64(seed: Self.seed)
        var tally = Tally()

        for name in Self.corpusFiles {
            let url = TestPaths.corpusFile(name)
            let original = try #require(
                (try? Data(contentsOf: url)).map(Array.init),
                "corpus file not readable at \(url.path) — see TestPaths fragility note"
            )

            for _ in 0 ..< Self.iterations {
                tally.mutants += 1
                let mutated = Self.mutate(original, using: &prng)
                Self.exercise(Data(mutated), into: context, target: target, tally: &tally)
            }
        }

        // Auditable one-liner so a gate run can see coverage at a glance.
        print("""
        [fuzz] seed=\(Self.seed) iterations/file=\(Self.iterations) files=\(Self.corpusFiles.count) \
        mutants=\(tally.mutants) parse-rejects=\(tally.parseRejects) \
        parsed-clean=\(tally.parsedClean) parsed-with-diagnostics=\(tally.parsedWithDiagnostics) \
        rendered=\(tally.rendered)
        """)

        // Reaching here at all is the pass: no mutant trapped or hung. Assert a
        // non-trivial run actually happened so a misconfigured env can't make
        // this vacuously green.
        #expect(tally.mutants == Self.corpusFiles.count * Self.iterations)
        #expect(tally.rendered <= tally.mutants)
    }

    // MARK: - Surface exercise

    /// Runs one mutant through the whole surface. A parse throw is a normal,
    /// correct outcome (a PASS); everything after a successful parse is
    /// exercised so a mutant can reach the payload decoders and the renderer.
    private static func exercise(
        _ data: Data,
        into context: CGContext,
        target: CGRect,
        tally: inout Tally
    ) {
        let file: EMFFile
        do {
            file = try EMFFile.parse(data)
        } catch {
            tally.parseRejects += 1
            return
        }

        if file.diagnostics.isEmpty {
            tally.parsedClean += 1
        } else {
            tally.parsedWithDiagnostics += 1
        }

        // Decode EVERY record's payload — the record-body decoders are a large
        // slice of the hostile-input attack surface.
        for record in file.records {
            _ = file.payload(of: record)
        }

        // EMF+ presence scanner walks comment records — exercise it too.
        _ = file.emfPlusPresence()

        // Full playback into the shared bounded context.
        _ = EMFRenderer.render(file, into: context, target: target)
        tally.rendered += 1
    }

    private static func makeSharedContext() -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: 256,
            height: 256,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Mutation

    /// Adversarial 4-byte stomp values: random, plus the boundary constants
    /// that break naive size/count/offset handling (0, all-ones, INT32_MAX,
    /// INT32_MIN, and a small N).
    private static func stompValue(using prng: inout SplitMix64) -> UInt32 {
        let choices: [UInt32] = [
            UInt32(truncatingIfNeeded: prng.next()),
            0x0000_0000,
            0xFFFF_FFFF,
            0x7FFF_FFFF,
            0x8000_0000,
            UInt32(prng.next() % 16),   // small-N
        ]
        return choices[Int(prng.next() % UInt64(choices.count))]
    }

    /// Applies 1–8 random mutations to a copy of `bytes`. Operators:
    ///  - single byte flip;
    ///  - 4-byte stomp at a random 4-aligned offset (adversarial values);
    ///  - truncation at a random offset;
    ///  - a stomp aimed at offset 0..108 (header territory).
    /// Truncation short-circuits (nothing after it to mutate).
    static func mutate(_ bytes: [UInt8], using prng: inout SplitMix64) -> [UInt8] {
        var out = bytes
        let mutationCount = Int(prng.next() % 8) + 1   // 1..8

        for _ in 0 ..< mutationCount {
            guard !out.isEmpty else { break }
            let op = prng.next() % 4
            switch op {
            case 0:
                // Single byte flip.
                let index = Int(prng.next() % UInt64(out.count))
                out[index] ^= UInt8(truncatingIfNeeded: prng.next() | 1)

            case 1:
                // 4-byte stomp at a random 4-aligned offset.
                guard out.count >= 4 else { continue }
                let maxWord = (out.count - 4) / 4
                let offset = Int(prng.next() % UInt64(maxWord + 1)) * 4
                writeUInt32LE(stompValue(using: &prng), at: offset, in: &out)

            case 2:
                // Truncate at a random offset, then stop (rest is gone).
                let cut = Int(prng.next() % UInt64(out.count))
                out.removeLast(out.count - cut)
                return out

            default:
                // Stomp in header territory (offset 0..108), 4-aligned.
                let ceiling = min(108, out.count - 4)
                guard ceiling >= 0 else { continue }
                let maxWord = ceiling / 4
                let offset = Int(prng.next() % UInt64(maxWord + 1)) * 4
                writeUInt32LE(stompValue(using: &prng), at: offset, in: &out)
            }
        }
        return out
    }

    /// Writes `value` little-endian at `offset`, clamped to the buffer.
    private static func writeUInt32LE(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// SplitMix64: a tiny, fast, well-distributed seedable PRNG. Deterministic for
/// a given seed, so the fuzz mutant stream is reproducible run to run
/// (Steele, Lea & Flood, 2014). Not for cryptographic use — this is a test
/// input generator.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
