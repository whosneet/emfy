import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - Render performance (primer §6 phase 6)
//
// A wall-clock floor test, not a benchmark harness: it renders the LARGEST
// committed corpus file end to end through `EMFRenderer.makeImage` and asserts
// it finishes well under a generous bound, guarding against a catastrophic
// (e.g. accidentally quadratic) regression. It also REPORTS — without asserting
// — the timings of the four hand-authored EMF+ files so an EMF+ playback
// slowdown is visible in the log. Only committed corpus files are used; the
// large work-sourced stress file is verified separately and never referenced
// here.
@Suite("Render performance")
struct EMFPlusPerfTests {

    /// A generous per-file wall-clock ceiling. The committed corpus tops out at
    /// ~16 KB, so a healthy render is milliseconds; 2 s catches only a gross
    /// regression while staying robust to a cold CoreGraphics start and CI load.
    private static let ceiling: Duration = .seconds(2)

    /// Milliseconds from a `Duration`, for human-readable reporting.
    private static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) * 1e-15
    }

    /// The perf target, pinned BY NAME (audit M19). It used to be chosen
    /// dynamically as the largest committed `.emf` by byte size, so committing any
    /// bigger corpus file would silently change what this test measures.
    /// `gate-p2-house.emf` is the current largest committed corpus file — update
    /// this deliberately (with a fresh timing check) if that ever changes.
    private static let perfTargetFile = "gate-p2-house.emf"

    @Test("the pinned largest corpus file renders under a generous wall-clock bound")
    func pinnedCorpusFileRendersQuickly() throws {
        let file = try parseCorpusFile(Self.perfTargetFile)

        let clock = ContinuousClock()
        var image: CGImage?
        let elapsed = clock.measure {
            image = EMFRenderer.makeImage(file)?.0
        }
        _ = try #require(image, "makeImage returned nil for \(Self.perfTargetFile)")

        print("[perf] pinned corpus target \(Self.perfTargetFile) rendered in "
            + String(format: "%.1f ms", Self.milliseconds(elapsed)))
        #expect(elapsed < Self.ceiling,
                "\(Self.perfTargetFile) took \(Self.milliseconds(elapsed)) ms, over the \(Self.milliseconds(Self.ceiling)) ms ceiling")
    }

    @Test("EMF+ corpus files render (reported, not asserted)")
    func emfPlusFilesRenderTimingsReported() throws {
        let clock = ContinuousClock()
        for name in [
            "handmade-emfplus-shapes.emf",
            "handmade-emfplus-dual.emf",
            "handmade-emfplus-image.emf",
            "handmade-emfplus-text.emf",
        ] {
            let file = try parseCorpusFile(name)
            var image: CGImage?
            let elapsed = clock.measure { image = EMFRenderer.makeImage(file)?.0 }
            #expect(image != nil, "makeImage returned nil for \(name)")
            print("[perf] \(name) rendered in " + String(format: "%.1f ms", Self.milliseconds(elapsed)))
        }
    }

    // MARK: - Scaling proxy (audit M19)

    private static let scalingPlusVersion: UInt32 = 0xDBC0_1002

    /// An EMF+ file of `count` direct-colour FillRects records (one rect each),
    /// built with the shared `RenderFixture` — the scaling proxy input.
    private static func makeFillRectsFile(count: Int) throws -> EMFFile {
        func le(_ build: (inout RenderFixture.LE) -> Void) -> [UInt8] {
            var writer = RenderFixture.LE(); build(&writer); return writer.bytes
        }
        func plusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8]) -> [UInt8] {
            le { $0.u16(type); $0.u16(flags); $0.u32(UInt32(12 + data.count)); $0.u32(UInt32(data.count)); $0.raw(data) }
        }
        let header = plusRecord(0x4001, 0x0001, le { $0.u32(scalingPlusVersion); $0.u32(0); $0.u32(96); $0.u32(96) })
        var stream = header
        stream.reserveCapacity(header.count + count * 36)
        for index in 0 ..< count {
            let x = Float(index % 80) + 5
            stream += plusRecord(0x400A, 0x8000, le { writer in
                writer.u32(0xFF00_0000 | UInt32(index & 0x00FF_FFFF))   // opaque, varied colour
                writer.u32(1)
                writer.f32(x); writer.f32(5); writer.f32(4); writer.f32(4)
            })
        }
        var fixture = RenderFixture()
        fixture.plusComment(stream)
        return try fixture.parsed()
    }

    @Test("render time scales sub-quadratically with EMF+ record count", .serialized)
    func fillRectsScalingSubQuadratic() throws {
        let small = try Self.makeFillRectsFile(count: 1000)
        let large = try Self.makeFillRectsFile(count: 8000)   // 8× the records
        let clock = ContinuousClock()
        _ = EMFRenderer.makeImage(small)?.0                    // warmup (cold CoreGraphics start)
        let tSmall = clock.measure { _ = EMFRenderer.makeImage(small)?.0 }
        let tLarge = clock.measure { _ = EMFRenderer.makeImage(large)?.0 }
        // 8× the records: linear predicts t(8N) ≈ 8×t(N); quadratic ≈ 64×. The
        // bound 24×max(t(N), 5ms) sits well above linear yet far below quadratic;
        // the 5 ms floor keeps a tiny t(N) from making the bound brittle under jitter.
        let baseline = max(tSmall, .milliseconds(5))
        let bound = baseline * 24
        print("[perf] scaling t(1000)=" + String(format: "%.1f", Self.milliseconds(tSmall))
            + "ms t(8000)=" + String(format: "%.1f", Self.milliseconds(tLarge))
            + "ms bound=" + String(format: "%.1f", Self.milliseconds(bound)) + "ms")
        #expect(tLarge < bound,
                "t(8000)=\(Self.milliseconds(tLarge))ms exceeded 24×max(t(1000),5ms)=\(Self.milliseconds(bound))ms — super-linear regression?")
    }
}

private extension RenderFixture {
    /// Wraps an EMF+ record stream in an EMR_COMMENT_EMFPLUS ([MS-EMF] §2.3.3.4).
    mutating func plusComment(_ stream: [UInt8]) {
        var payload = LE()
        payload.u32(UInt32(4 + stream.count))
        payload.u32(0x2B46_4D45)   // "EMF+"
        payload.raw(stream)
        append(type: 70, payload: payload.bytes)
    }
}
