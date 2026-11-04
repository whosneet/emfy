import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Mutation-fuzz SURVIVAL floors for the two W6 render paths Quick Look drives on
/// untrusted input (primer §8, plan §3 W6): the WMF record-playback path and the
/// gzip (.emz/.wmz) front door inflating into a render. The v2 EMF+ fuzz
/// (EMFRenderTests.FuzzTests) is the pattern — each committed seed file is copied,
/// hit with 1–8 deterministic mutations (reusing `FuzzTests.mutate`), and run end
/// to end:
///
///   OpenedMetafile.open → MetafileRenderer.prepare → MetafileRenderer.render
///
/// into ONE shared, bounded 256×256 context (never `makeImage`, whose mutant-
/// driven canvas would reallocate every iteration). PASS = SURVIVAL: no trap, no
/// hang. Beyond survival, each test asserts a TRAVERSAL FLOOR — a minimum count of
/// mutants that actually reached playback, not merely parse — so a regression that
/// silently empties the surface (every mutant rejected before playback) fails
/// instead of passing vacuously.
///
/// Determinism: fixed per-test seeds. `EMFY_WMF_FUZZ_ITERATIONS` overrides the
/// per-file mutant count for the gated DEEP run (reported, not in the default
/// suite); the default stays fast.
@Suite("Metafile fuzz floor (survival + traversal)")
struct MetafileFuzzFloorTests {

    /// Committed WMF seeds: the placeable gate exports (which embed an EMF), the
    /// escape-stripped GDI variants (pure record path), and the W2 hand-built
    /// headers ([MS-WMF] §2.3). Absent files are skipped.
    static let wmfSeeds = [
        "gate-wmf-p2-house.wmf", "gate-wmf-p2-star.wmf", "gate-wmf-p2-triangles.wmf",
        "gate-wmf-p3-curves.wmf", "gate-wmf-p3-shapes.wmf",
        "gate-wmf-p4-image.wmf", "gate-wmf-p4-text.wmf", "gate-wmf-p4-image-standard.wmf",
        "gate-wmf-gdi-p2-house.wmf", "gate-wmf-gdi-p2-star.wmf", "gate-wmf-gdi-p2-triangles.wmf",
        "gate-wmf-gdi-p3-curves.wmf", "gate-wmf-gdi-p3-shapes.wmf",
        "gate-wmf-gdi-p4-image.wmf", "gate-wmf-gdi-p4-text.wmf",
        "handmade-wmf-placeable.wmf", "handmade-wmf-standard.wmf",
    ]

    /// Committed gzip seeds (.wmz / .emz).
    static let gzipSeeds = [
        "gate-wmf-p2-star.wmz", "gate-p2-star.emz", "gate-p3-shapes.emz", "gate-p4-text.emz",
    ]

    /// Default per-file mutant count. Kept low so an everyday `swift test` stays
    /// fast; the deep run overrides it via the environment.
    static let defaultIterations = 300

    static func iterations(_ fallback: Int) -> Int {
        if let raw = ProcessInfo.processInfo.environment["EMFY_WMF_FUZZ_ITERATIONS"],
           let value = Int(raw), value > 0 {
            return value
        }
        return fallback
    }

    private static func sharedContext() -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static let target = CGRect(x: 0, y: 0, width: 256, height: 256)

    // MARK: - WMF record-playback floor

    @Test("mutated WMF seeds survive the full render path and a floor reaches record playback")
    func wmfRecordPlaybackFloor() throws {
        let context = try #require(Self.sharedContext())
        var prng = SplitMix64(seed: 0xB5AD_4ECE_DA1A_5B81)
        let perFile = Self.iterations(Self.defaultIterations)

        var mutants = 0, parseRejects = 0, wmfRecordRenders = 0, embeddedEMFRenders = 0

        // Crash-site marker (as in FuzzTests): a trap unwinds through this defer,
        // printing the exact seed/file/iteration so the mutant is replayable.
        var currentFile = "<none>", currentIteration = -1, completed = false
        defer {
            if !completed {
                fputs("[wmf-fuzz] CRASH SITE file=\(currentFile) iteration=\(currentIteration)\n", stderr)
            }
        }

        for name in Self.wmfSeeds {
            guard let data = try? Data(contentsOf: TestPaths.corpusFile(name)) else { continue }
            let original = Array(data)
            currentFile = name
            for i in 0 ..< perFile {
                currentIteration = i
                mutants += 1
                let mutated = Data(FuzzTests.mutate(original, using: &prng))
                guard let opened = try? OpenedMetafile.open(mutated),
                      let prepared = MetafileRenderer.prepare(opened) else {
                    parseRejects += 1
                    continue
                }
                _ = MetafileRenderer.render(prepared, into: context, target: Self.target)
                switch prepared.kind {
                case .wmfRecords: wmfRecordRenders += 1
                case .emf: embeddedEMFRenders += 1
                }
            }
        }
        completed = true

        print("[wmf-fuzz] seed=0xB5AD4ECEDA1A5B81 perFile=\(perFile) mutants=\(mutants) "
            + "parse-rejects=\(parseRejects) wmf-record-renders=\(wmfRecordRenders) "
            + "embedded-emf-renders=\(embeddedEMFRenders)")

        #expect(mutants > 0)
        // Floors (conservative, well below observed): the GDI-variant seeds carry
        // no escapes, so most of their mutants that still parse reach WMF record
        // playback; the placeable seeds' corrupted-escape mutants fall back to it
        // too. A zero here means the record-playback surface went dark.
        #expect(wmfRecordRenders >= 200, "too few mutants reached WMF record playback: \(wmfRecordRenders)")
        // Some placeable-seed mutants keep a consistent embedded EMF and play it,
        // so the embedded-EMF render path is exercised as well.
        #expect(embeddedEMFRenders >= 50, "too few mutants reached embedded-EMF playback: \(embeddedEMFRenders)")
    }

    // MARK: - Gzip front-door floor

    @Test("mutated gzip seeds survive the front door and a floor inflates into a render")
    func gzipFrontDoorPlaybackFloor() throws {
        let context = try #require(Self.sharedContext())
        var prng = SplitMix64(seed: 0x2F6E_C1A0_77B3_49DD)
        // Gzip mutants mostly corrupt the DEFLATE/CRC and fail to inflate, so this
        // path needs more iterations than the WMF one to seat a traversal floor.
        let perFile = Self.iterations(600)

        var mutants = 0, openRejects = 0, inflatedRenders = 0

        var currentFile = "<none>", currentIteration = -1, completed = false
        defer {
            if !completed {
                fputs("[gzip-fuzz] CRASH SITE file=\(currentFile) iteration=\(currentIteration)\n", stderr)
            }
        }

        for name in Self.gzipSeeds {
            guard let data = try? Data(contentsOf: TestPaths.corpusFile(name)) else { continue }
            let original = Array(data)
            currentFile = name
            for i in 0 ..< perFile {
                currentIteration = i
                mutants += 1
                let mutated = Data(FuzzTests.mutate(original, using: &prng))
                guard let opened = try? OpenedMetafile.open(mutated) else {
                    openRejects += 1   // a typed gzip failure is the correct outcome on a corrupt member
                    continue
                }
                // Only count mutants that actually inflated (the gzip path ran) AND
                // prepared into a renderable metafile.
                guard opened.wasDecompressed, let prepared = MetafileRenderer.prepare(opened) else { continue }
                _ = MetafileRenderer.render(prepared, into: context, target: Self.target)
                inflatedRenders += 1
            }
        }
        completed = true

        print("[gzip-fuzz] seed=0x2F6EC1A077B349DD perFile=\(perFile) mutants=\(mutants) "
            + "open-rejects=\(openRejects) inflated-into-render=\(inflatedRenders)")

        #expect(mutants > 0)
        // Floor: a non-trivial share of mutants mutate only the advisory header
        // (MTIME/XFL/OS), the ISIZE, or trailing/appended bytes, leaving the member
        // inflatable; those must inflate and reach a render. Zero means the gzip
        // front door stopped feeding the renderer.
        #expect(inflatedRenders >= 5, "too few mutants inflated into a render: \(inflatedRenders)")
    }
}
