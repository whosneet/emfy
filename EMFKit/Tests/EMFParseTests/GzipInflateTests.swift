import Foundation
import Testing
@testable import EMFParse

/// Streaming gzip inflate: real round-trips, every malformed-header and
/// malformed-trailer path as a typed failure, advisory diagnostics, and the
/// decompression-bomb ceiling. Quick Look feeds this hostile .emz/.wmz files
/// automatically (§8), so each bad case must fail typed and never trap.
@Suite("Gzip inflate")
struct GzipInflateTests {

    /// 512 low-compressibility bytes, so the DEFLATE stream is long enough to
    /// truncate meaningfully.
    static let payload: [UInt8] = {
        var bytes = [UInt8]()
        for i in 0 ..< 512 { bytes.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        return bytes
    }()

    private func inflateError(
        _ data: Data,
        ceiling: Int = GzipInflate.defaultOutputCeiling
    ) -> GzipError? {
        do {
            _ = try GzipInflate.inflate(data, ceiling: ceiling)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Real round-trips

    @Test("real .emz inflates byte-identical to its source .emf", arguments: [
        ("gate-p2-star.emz", "gate-p2-star.emf"),
        ("gate-p3-shapes.emz", "gate-p3-shapes.emf"),
        ("gate-p4-text.emz", "gate-p4-text.emf"),
    ])
    func realEmzRoundTrip(_ pair: (emz: String, emf: String)) throws {
        let emz = try MetafileCorpus.data(pair.emz)
        let emf = try MetafileCorpus.data(pair.emf)
        let result = try GzipInflate.inflate(emz)
        #expect(result.data == emf)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a synthetic member with every optional header field round-trips")
    func allOptionalHeaderFields() throws {
        let member = GzipFixture.make(
            payload: Self.payload,
            extra: [0x01, 0x02, 0x03],
            name: Array("picture.emf".utf8),
            comment: Array("made by a test".utf8),
            fhcrc: true
        )
        let result = try GzipInflate.inflate(member)
        #expect(result.data == Data(Self.payload))
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Malformed header → typed failure

    @Test("input shorter than a header + trailer is .tooShort")
    func tooShort() {
        #expect(inflateError(Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0])) == .tooShort)
    }

    @Test("bad magic is rejected")
    func badMagic() {
        var bytes = Array(GzipFixture.make(payload: Self.payload))
        bytes[0] = 0x1E
        #expect(inflateError(Data(bytes)) == .badMagic(id1: 0x1E, id2: 0x8B))
    }

    @Test("a non-DEFLATE compression method is rejected")
    func unsupportedMethod() {
        var bytes = Array(GzipFixture.make(payload: Self.payload))
        bytes[2] = 0x09
        #expect(inflateError(Data(bytes)) == .unsupportedMethod(cm: 0x09))
    }

    @Test("a reserved FLG bit is rejected")
    func reservedFlagsSet() {
        var bytes = Array(GzipFixture.make(payload: Self.payload))
        bytes[3] |= 0x20
        #expect(inflateError(Data(bytes)) == .reservedFlagsSet(flags: 0x20))
    }

    @Test("an FEXTRA XLEN past the buffer is .truncatedHeader")
    func extraFieldPastEnd() {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0x00, 0xFF]
        bytes += [0xFF, 0xFF]   // XLEN = 65535, far past the data
        bytes += [0x01, 0x02]   // two actual extra bytes
        while bytes.count < 20 { bytes.append(0x00) }
        #expect(inflateError(Data(bytes)) == .truncatedHeader)
    }

    @Test("an unterminated FNAME is .truncatedHeader")
    func unterminatedName() {
        var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0x00, 0xFF]
        bytes += Array("nameneverterminated".utf8)   // no NUL, runs off the end
        #expect(inflateError(Data(bytes)) == .truncatedHeader)
    }

    // MARK: - Malformed DEFLATE / trailer → typed failure

    @Test("a truncated DEFLATE stream is .inflateFailed")
    func truncatedDeflate() {
        let deflated = GzipFixture.deflate(Self.payload)
        let member = GzipFixture.make(payload: Self.payload, deflateOverride: deflated)
        // Keep the header and the front half of the DEFLATE stream only.
        let keep = max(18, 10 + deflated.count / 2)
        let truncated = Data(member.prefix(keep))
        #expect(inflateError(truncated)?.isInflateFailed == true)
    }

    @Test("a member with its trailer removed fails (surfaces as CRC mismatch)")
    func missingTrailer() {
        let member = GzipFixture.make(payload: Self.payload)
        let noTrailer = Data(member.dropLast(8))
        #expect(inflateError(noTrailer)?.isCRCMismatch == true)
    }

    @Test("a corrupt stored CRC is .crcMismatch")
    func crcMismatch() {
        var bytes = Array(GzipFixture.make(payload: Self.payload))
        bytes[bytes.count - 8] ^= 0xFF   // flip a CRC byte
        #expect(inflateError(Data(bytes))?.isCRCMismatch == true)
    }

    // MARK: - Advisory diagnostics (success)

    @Test("a corrupt ISIZE is an advisory diagnostic, not a failure")
    func isizeMismatchIsDiagnostic() throws {
        let member = GzipFixture.make(
            payload: Self.payload,
            isizeOverride: UInt32(Self.payload.count) ^ 0x00FF_0000
        )
        let result = try GzipInflate.inflate(member)
        #expect(result.data == Data(Self.payload))
        #expect(result.diagnostics.contains {
            if case .isizeMismatch = $0 { return true }
            return false
        })
    }

    @Test("bytes after the first member are an advisory diagnostic, not a failure")
    func trailingBytesIsDiagnostic() throws {
        let trailing: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]
        let member = GzipFixture.make(payload: Self.payload, trailing: trailing)
        let result = try GzipInflate.inflate(member)
        #expect(result.data == Data(Self.payload))
        #expect(result.diagnostics.contains {
            if case .trailingBytesAfterMember(let count) = $0 { return count == trailing.count }
            return false
        })
    }

    // MARK: - Decompression bomb

    @Test("output past the ceiling is .outputTooLarge without inflating the whole bomb")
    func decompressionBomb() {
        // 4 MiB of zeros deflates to a few KB; inflating under a 1 MiB ceiling
        // must stop with a typed failure.
        let zeros = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        let bomb = GzipFixture.make(payload: zeros)
        #expect(bomb.count < 64 * 1024, "the bomb fixture itself must stay tiny")
        let ceiling = 1 * 1024 * 1024
        #expect(inflateError(bomb, ceiling: ceiling) == .outputTooLarge(ceiling: ceiling))
    }

    // (The real 64 MiB default ceiling is tripped END TO END through the front
    // door in MetafileFrontDoorTests.gzipBombPastDefaultCeilingThroughDoor, which
    // exercises this same ceiling plus the open path — not duplicated here.)

    // MARK: - Performance (worst-case inflate near the cap)

    /// A near-cap (~48 MiB) successful inflate, REPORTED with a generous guard —
    /// the perf worst-case for the .emz/.wmz path (plan §3 W6). The payload is a
    /// repeating block so it deflates small (no big wire fixture) yet drives real
    /// match-copy work inflating back to ~48 MiB.
    @Test("a ~48 MiB inflate finishes well under a generous bound (reported)")
    func largeInflateTiming() throws {
        let blockSize = 4096
        let blocks = (48 * 1024 * 1024) / blockSize
        var block = [UInt8](repeating: 0, count: blockSize)
        for i in 0 ..< blockSize { block[i] = UInt8(truncatingIfNeeded: i &* 131 &+ 17) }
        var payload = [UInt8](); payload.reserveCapacity(blocks * blockSize)
        for _ in 0 ..< blocks { payload.append(contentsOf: block) }
        let member = GzipFixture.make(payload: payload)

        let clock = ContinuousClock()
        var result: GzipInflate.Result?
        // Use the macOS ceiling explicitly so the 48 MiB payload inflates on every
        // platform (the iOS default ceiling is 24 MiB) — this test measures inflate
        // throughput, not the platform cap.
        let elapsed = clock.measure { result = try? GzipInflate.inflate(member, ceiling: GzipInflate.macOSOutputCeiling) }
        let r = try #require(result, "the near-cap member should inflate")
        #expect(r.data.count == payload.count)
        let milli = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) * 1e-15
        print("[gzip-perf] ~48 MiB inflate (\(member.count)-byte member) in " + String(format: "%.1f ms", milli))
        #expect(elapsed < .seconds(5), "a ~48 MiB inflate took \(milli) ms")
    }
}

private extension GzipError {
    var isInflateFailed: Bool {
        if case .inflateFailed = self { return true }
        return false
    }

    var isCRCMismatch: Bool {
        if case .crcMismatch = self { return true }
        return false
    }
}
