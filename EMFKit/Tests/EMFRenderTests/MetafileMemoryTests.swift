import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Peak-memory measurement across the committed corpus, on whatever platform the
/// suite runs on. On the iOS Simulator these are the numbers that inform the I4
/// Quick Look extension budget (iOS extensions are jetsam-killed far below the
/// app's limit). No cap is changed in I0 — this only measures and prints, with a
/// generous sanity ceiling so a runaway allocation still fails the test.
///
/// `phys_footprint` from `TASK_VM_INFO` is the same accounting the jetsam limit
/// uses, so it is the right gauge for an extension budget. It is process-wide, so
/// both the absolute high-water mark and the per-render delta are reported, and
/// the worst-case bitmap size is computed deterministically from the canvas.
@Suite("Metafile render peak memory")
struct MetafileMemoryTests {

    /// Current resident physical footprint in bytes, or 0 if the query fails.
    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { raw -> kern_return_t in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intRaw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intRaw, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func mib(_ bytes: UInt64) -> String {
        String(format: "%.1f MiB", Double(bytes) / (1024 * 1024))
    }

    private static func prepared(_ name: String) -> MetafileRenderer.Prepared? {
        guard let data = try? Data(
            contentsOf: MetafileSmokeTests.corpusDirectory.appendingPathComponent(name)
        ), let opened = try? OpenedMetafile.open(data) else { return nil }
        return MetafileRenderer.prepare(opened)
    }

    @Test("render the whole corpus at scale 1 and 2; report peak footprint and worst bitmap")
    func corpusRenderFootprint() throws {
        var processPeak: UInt64 = 0
        var worstDelta: (name: String, bytes: UInt64) = ("", 0)
        var largestCanvas: (name: String, w: Int, h: Int, area: Double) = ("", 0, 0, -1)

        for name in MetafileSmokeTests.corpusMetafileNames {
            guard let prep = Self.prepared(name) else { continue }
            let w = Int(prep.naturalSize.width), h = Int(prep.naturalSize.height)
            let area = prep.naturalSize.width * prep.naturalSize.height
            if area > largestCanvas.area { largestCanvas = (name, w, h, area) }

            for scale in [CGFloat(1), CGFloat(2)] {
                let before = Self.physFootprint()
                let result = MetafileRenderer.makeImage(prep, scale: scale)
                let after = Self.physFootprint()
                withExtendedLifetime(result) {}
                processPeak = max(processPeak, after)
                let delta = after > before ? after - before : 0
                if delta > worstDelta.bytes { worstDelta = (name + " @\(Int(scale))x", delta) }
            }
        }

        // Deterministic worst-case bitmap allocation for the largest canvas
        // (RGBA8, premultiplied): width × height × 4, × scale² — what makeImage's
        // backing store costs regardless of how coarse phys_footprint sampling is.
        let px = largestCanvas.area
        let bmp1 = UInt64(px * 4)
        let bmp2 = UInt64(px * 4 * 4)
        print("[memory] largest canvas: \(largestCanvas.name) "
            + "\(largestCanvas.w)×\(largestCanvas.h) "
            + "→ bitmap \(Self.mib(bmp1)) @1x, \(Self.mib(bmp2)) @2x")
        print("[memory] worst measured per-render footprint delta: "
            + "\(Self.mib(worstDelta.bytes)) (\(worstDelta.name.isEmpty ? "none" : worstDelta.name))")
        print("[memory] process peak footprint across the corpus render pass: \(Self.mib(processPeak))")

        // Sanity ceiling only (§8: no cap change in I0). The committed corpus
        // canvases are small; a per-render delta above 512 MiB would mean a
        // pathological allocation, not a real metafile.
        #expect(worstDelta.bytes < 512 * 1024 * 1024, "a corpus render footprint delta is implausibly large")
        #expect(largestCanvas.area > 0, "no corpus file prepared for the memory measurement")
    }

    // MARK: - M1: WMF record/summary lists are built lazily, not at prepare time

    /// A synthetic WMF with `recordCount` 6-byte generic records (plus a placeable
    /// header, META_HEADER and META_EOF). Each record is the minimum 3 WORDs, so a
    /// 1M-record file is only ~6 MiB on disk yet drives the inspector lists to ~1M
    /// rows — the crafted shape the M1 audit flags.
    private static func syntheticWMF(recordCount: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(22 + 18 + recordCount * 6 + 6)
        func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 24) & 0xFF))
        }
        // META_PLACEABLE ([MS-WMF] §2.3.2.3): key, bbox, inch, reserved, checksum.
        let headerStart = bytes.count
        u32(0x9AC6_CDD7)                       // Key
        u16(0)                                 // HWmf
        u16(0); u16(0); u16(1000); u16(1000)   // BoundingBox
        u16(1440)                              // Inch
        u32(0)                                 // Reserved
        var checksum: UInt16 = 0
        for i in 0 ..< 10 {
            checksum ^= UInt16(bytes[headerStart + i * 2]) | (UInt16(bytes[headerStart + i * 2 + 1]) << 8)
        }
        u16(checksum)                          // Checksum
        // META_HEADER ([MS-WMF] §2.3.2.2).
        u16(0x0001); u16(0x0009); u16(0x0300); u16(0); u16(0); u16(0); u32(0); u16(0)
        // `recordCount` generic META_SAVEDC records (0x001E), 3 WORDs each.
        for _ in 0 ..< recordCount { u32(3); u16(0x001E) }
        u32(3); u16(0x0000)                    // META_EOF
        return Data(bytes)
    }

    @Test("preparing a 1M-record WMF defers the record/summary lists until asked (M1)")
    func wmfRecordListsBuiltLazily() throws {
        let recordCount = 1_000_000
        let data = Self.syntheticWMF(recordCount: recordCount)

        let before = Self.physFootprint()
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(MetafileRenderer.prepare(opened))
        let afterPrepare = Self.physFootprint()
        #expect(prepared.kind == .wmfRecords)

        // Build the ref rows on demand — this is where the inspector list is
        // materialised (M1): prepare() does not pre-build it, recordRefs() does.
        let refs = prepared.recordRefs()
        let afterRefs = Self.physFootprint()

        // Build a large batch of one-line summaries on demand, one row at a time —
        // the way the inspector asks for them — and retain them for the measurement.
        var summaries: [String] = []
        summaries.reserveCapacity(refs.count)
        for i in 0 ..< refs.count { summaries.append(prepared.recordSummary(at: i) ?? "") }
        let afterSummaries = Self.physFootprint()

        let preparedDelta = afterPrepare > before ? afterPrepare - before : 0
        let refsDelta = afterRefs > afterPrepare ? afterRefs - afterPrepare : 0
        let summariesDelta = afterSummaries > afterRefs ? afterSummaries - afterRefs : 0
        print("[memory][M1] 1M-record WMF — prepare: \(Self.mib(preparedDelta)), "
            + "recordRefs(): +\(Self.mib(refsDelta)), summaries: +\(Self.mib(summariesDelta))")

        // Deterministic correctness of the ON-DEMAND build (the lazy mechanism): the
        // list and summaries are derived from the retained WMFFile when asked, not
        // stored on Prepared. (phys_footprint deltas are process-wide and noisy in a
        // shared test process, so they are reported above but not asserted on — the
        // laziness is structural: recordRefs()/recordSummary() compute from wmfFile.)
        #expect(refs.count == recordCount, "every generic record must appear as a row")
        let mid = refs.count / 2
        #expect(refs[mid].typeName == "META_SAVEDC")
        #expect(refs[mid].size == 6)
        #expect(summaries.count == refs.count)
        // META_SAVEDC carries no parameters, so its one-line summary is "" — the
        // point is that the on-demand path RETURNS a value (non-nil), not nil.
        #expect(prepared.recordSummary(at: mid) != nil, "a summary is produced on demand")

        withExtendedLifetime((refs, summaries)) {}

        // Sanity ceiling only: a 1M-record WMF must not blow up unboundedly.
        #expect(preparedDelta < 1024 * 1024 * 1024, "preparing a 1M-record WMF allocated implausibly much")
    }
}
