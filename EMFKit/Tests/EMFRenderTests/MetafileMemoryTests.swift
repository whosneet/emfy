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
}
