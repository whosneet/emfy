import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - WMF render performance (primer §6 phase 6, plan §3 W6)
//
// Wall-clock FLOORS, not a benchmark harness (the EMFPlusPerfTests pattern):
// time the committed WMF family end to end through the exact prepare+makeImage
// path the app and Quick Look run, assert each finishes well under a generous
// 2 s ceiling, and check WMF record playback scales roughly linearly. The three
// worst-case paths (a cap-sized region clip, a near-cap embedded-EMF
// reassembly, a large gzip inflate lives in GzipInflateTests) are REPORTED with
// a generous guard rather than a silently-raised tight bound.
@Suite("WMF render performance")
struct WMFPerfTests {

    private static let ceiling: Duration = .seconds(2)

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) * 1e-15
    }

    // Little-endian byte helpers.
    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func record(_ function: UInt16, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32((6 + body.count) / 2)) + u16(function) + body
    }
    private static func metaHeader() -> [UInt8] {
        u16(1) + u16(9) + u16(0x0300) + u16(0) + u16(0) + u16(0) + u32(0) + u16(0)
    }
    private static func placeableHeader() -> [UInt8] {
        u32(0x9AC6_CDD7) + u16(0) + i16(0) + i16(0) + i16(96) + i16(96) + u16(96) + u32(0) + u16(0)
    }

    // MARK: - Corpus timing

    /// Every committed WMF, .wmz and .emz, warm-timed through the exact entry the
    /// app and Quick Look call.
    static let corpusFiles = [
        "gate-wmf-p2-house.wmf", "gate-wmf-p2-star.wmf", "gate-wmf-p2-triangles.wmf",
        "gate-wmf-p3-curves.wmf", "gate-wmf-p3-shapes.wmf",
        "gate-wmf-p4-image.wmf", "gate-wmf-p4-text.wmf", "gate-wmf-p4-image-standard.wmf",
        "gate-wmf-gdi-p2-house.wmf", "gate-wmf-gdi-p2-star.wmf", "gate-wmf-gdi-p2-triangles.wmf",
        "gate-wmf-gdi-p3-curves.wmf", "gate-wmf-gdi-p3-shapes.wmf",
        "gate-wmf-gdi-p4-image.wmf", "gate-wmf-gdi-p4-text.wmf",
        "gate-wmf-p2-star.wmz", "gate-p2-star.emz", "gate-p3-shapes.emz", "gate-p4-text.emz",
    ]

    @Test("every committed WMF/WMZ/EMZ prepares + renders under the ceiling (warm)")
    func corpusRendersQuickly() throws {
        let clock = ContinuousClock()
        var slowest = (name: "<none>", ms: 0.0)
        for name in Self.corpusFiles {
            guard let data = try? Data(contentsOf: TestPaths.corpusFile(name)) else { continue }
            let opened = try OpenedMetafile.open(data)
            let prepared = try #require(MetafileRenderer.prepare(opened), "prepare nil for \(name)")
            _ = MetafileRenderer.makeImage(prepared)   // warm (cold CoreGraphics start)
            let elapsed = clock.measure { _ = MetafileRenderer.makeImage(prepared) }
            let milli = Self.ms(elapsed)
            if milli > slowest.ms { slowest = (name, milli) }
            #expect(elapsed < Self.ceiling, "\(name) took \(milli) ms, over the 2000 ms ceiling")
        }
        print("[wmf-perf] slowest committed file: \(slowest.name) at " + String(format: "%.1f ms", slowest.ms)
            + " (ceiling 2000 ms)")
    }

    // MARK: - Scaling proxy (mixed geometry + text)

    /// A font body ([MS-WMF] §2.2.1.2): 18 fixed bytes + 32-byte NUL-padded facename.
    private static func fontBody() -> [UInt8] {
        var b = i16(-16) + i16(0) + i16(0) + i16(0) + i16(400)
        b += [0, 0, 0, 0, 0, 0, 0, 0]   // italic/underline/strikeout/charset + 4 reserved
        var name = Array("Arial".utf8); name.append(0)
        while name.count < 32 { name.append(0) }
        return b + name
    }

    /// A standard WMF of `count` mixed records: cycling MOVETO, LINETO, RECTANGLE
    /// and a short TEXTOUT, after a font + colour preamble — the shape of real
    /// drawing content, for a scaling proxy.
    private static func mixedWMF(count: Int) -> Data {
        var records: [[UInt8]] = [
            record(0x020B, i16(0) + i16(0)),                 // SETWINDOWORG
            record(0x020C, i16(256) + i16(256)),             // SETWINDOWEXT
            record(0x02FB, fontBody()),                      // CREATEFONTINDIRECT → slot 0
            record(0x012D, u16(0)),                          // SELECTOBJECT 0
            record(0x0209, [0, 0, 0, 0]),                    // SETTEXTCOLOR black
        ]
        records.reserveCapacity(count + 6)
        for i in 0 ..< count {
            let x = Int16(i % 240) + 4
            let y = Int16((i * 7) % 240) + 4
            switch i % 4 {
            case 0: records.append(record(0x0214, i16(y) + i16(x)))                     // MOVETO (Y,X)
            case 1: records.append(record(0x0213, i16(y) + i16(x)))                     // LINETO (Y,X)
            case 2: records.append(record(0x041B, i16(y + 8) + i16(x + 8) + i16(y) + i16(x)))  // RECTANGLE
            default:
                records.append(record(0x0521, u16(2) + Array("Ab".utf8) + i16(y) + i16(x)))    // TEXTOUT "Ab"
            }
        }
        var bytes = metaHeader()
        for r in records { bytes += r }
        bytes += record(0x0000, [])   // EOF
        return Data(bytes)
    }

    @Test("WMF record playback scales sub-quadratically with record count")
    func mixedRecordScaling() throws {
        let small = try OpenedMetafile.open(Self.mixedWMF(count: 1000))
        let large = try OpenedMetafile.open(Self.mixedWMF(count: 8000))
        let sPrepared = try #require(MetafileRenderer.prepare(small))
        let lPrepared = try #require(MetafileRenderer.prepare(large))
        let clock = ContinuousClock()
        _ = MetafileRenderer.makeImage(sPrepared)   // warmup
        let tSmall = clock.measure { _ = MetafileRenderer.makeImage(sPrepared) }
        let tLarge = clock.measure { _ = MetafileRenderer.makeImage(lPrepared) }
        // 8× the records: linear predicts ~8×, quadratic ~64×. 24×max(t(N),5ms)
        // sits well above linear yet far below quadratic (the EMFPlusPerfTests bound).
        let bound = max(tSmall, .milliseconds(5)) * 24
        print("[wmf-perf] scaling t(1000)=" + String(format: "%.1f", Self.ms(tSmall))
            + "ms t(8000)=" + String(format: "%.1f", Self.ms(tLarge))
            + "ms bound=" + String(format: "%.1f", Self.ms(bound)) + "ms")
        #expect(tLarge < bound,
                "t(8000)=\(Self.ms(tLarge))ms exceeded 24×max(t(1000),5ms)=\(Self.ms(bound))ms — super-linear regression?")
    }

    // MARK: - Worst cases (reported with a generous guard)

    /// A META_CREATEREGION whose single scan declares 16384 x-coords → 8192
    /// rectangles, exactly the `regionRectCap` (§8). Clipping to it then filling
    /// is the worst-case region-clip path.
    @Test("a cap-sized (8192-rect) region clip prepares + renders under the ceiling")
    func maxRegionClip() throws {
        let rectCount = 8192
        let pairs = rectCount            // one (left,right) pair per rect
        var region: [UInt8] = []
        region += Self.i16(0)                                 // nextInChain
        region += Self.i16(6)                                 // ObjectType 6
        region += Self.u32(0)                                 // ObjectCount
        region += Self.i16(0)                                 // RegionSize (advisory)
        region += Self.i16(1)                                 // ScanCount = 1
        region += Self.i16(Int16(truncatingIfNeeded: pairs * 2))   // maxScan (advisory)
        region += Self.i16(0)                                 // bounds Left
        region += Self.i16(0)                                 // bounds Top
        region += Self.i16(256)                               // bounds Right
        region += Self.i16(256)                               // bounds Bottom
        // One scan: Count, Top, Bottom, then Count x-coords, then Count2.
        region += Self.u16(UInt16(pairs * 2))                 // Count (x-coords in this scan)
        region += Self.u16(0)                                 // scan Top
        region += Self.u16(255)                               // scan Bottom
        for i in 0 ..< pairs {
            let left = UInt16(i % 255)
            region += Self.u16(left)
            region += Self.u16(left + 1)
        }
        region += Self.u16(UInt16(pairs * 2))                 // Count2

        var bytes = Self.placeableHeader() + Self.metaHeader()
        bytes += Self.record(0x06FF, region)                                 // CREATEREGION → slot 0
        bytes += Self.record(0x012C, Self.u16(0))                            // SELECTCLIPREGION 0
        bytes += Self.record(0x041B, Self.i16(96) + Self.i16(96) + Self.i16(0) + Self.i16(0))  // RECTANGLE
        bytes += Self.record(0x0000, [])

        let clock = ContinuousClock()
        let opened = try OpenedMetafile.open(Data(bytes))
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let elapsed = clock.measure { _ = MetafileRenderer.makeImage(prepared) }
        print("[wmf-perf] cap-sized region clip (\(rectCount) rects) rendered in "
            + String(format: "%.1f ms", Self.ms(elapsed)))
        #expect(elapsed < Self.ceiling, "a cap-sized region clip took \(Self.ms(elapsed)) ms")
    }

    /// A placeable WMF whose embedded EMF is ~16 MiB, split into 8192-byte WMFC
    /// chunks — the worst-case reassembly-buffer growth below the 64 MiB cap. The
    /// payload is not a valid EMF, so it reassembles then falls back to the WMF
    /// records; the measured cost is the reassembly + validation.
    @Test("a near-cap embedded-EMF reassembly prepares under the ceiling")
    func maxEmbeddedReassembly() throws {
        let total = 16 * 1024 * 1024
        let chunkBytes = 8192
        let chunkCount = (total + chunkBytes - 1) / chunkBytes
        var bytes = Self.placeableHeader() + Self.metaHeader()
        bytes.reserveCapacity(total + chunkCount * 44 + 64)
        var remaining = total
        let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
        for _ in 0 ..< chunkCount {
            let thisChunk = min(chunkBytes, remaining)
            let payload = thisChunk == chunkBytes ? chunk : Array(chunk[0 ..< thisChunk])
            remaining -= thisChunk
            var body = Self.u16(0x000F) + Self.u16(UInt16(truncatingIfNeeded: 34 + thisChunk))
            body += Self.u32(0x4346_4D57) + Self.u32(0x0000_0001) + Self.u32(0x0001_0000)
            body += Self.u16(0) + Self.u32(0)
            body += Self.u32(UInt32(chunkCount))         // CommentRecordCount
            body += Self.u32(UInt32(thisChunk))          // CurrentRecordSize
            body += Self.u32(UInt32(remaining))          // RemainingBytes
            body += Self.u32(UInt32(total))              // EnhancedMetafileDataSize
            body += payload
            bytes += Self.record(0x0626, body)
        }
        bytes += Self.record(0x0000, [])

        let clock = ContinuousClock()
        var prepared: MetafileRenderer.Prepared?
        let elapsed = clock.measure {
            if let opened = try? OpenedMetafile.open(Data(bytes)) {
                prepared = MetafileRenderer.prepare(opened)
            }
        }
        let p = try #require(prepared)
        // The payload is not a valid EMF, so the reassembly is rejected at parse
        // and the WMF records play — the point here is the bounded reassembly cost.
        #expect(p.embeddedEMF == .rejected)
        print("[wmf-perf] ~16 MiB embedded-EMF reassembly (\(chunkCount) chunks) prepared in "
            + String(format: "%.1f ms", Self.ms(elapsed)))
        #expect(elapsed < Self.ceiling, "a near-cap embedded reassembly took \(Self.ms(elapsed)) ms")
    }
}
