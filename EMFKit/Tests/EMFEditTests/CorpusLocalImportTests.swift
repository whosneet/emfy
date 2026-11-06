import Foundation
import Testing
@testable import EMFEdit

/// Imports every parseable `corpus-local/` file (gitignored; may be absent),
/// asserting the record partition and measuring time and memory. Work-sourced
/// files are confidential: this reports COUNTS and TIMINGS only — never a name,
/// never any content.
struct CorpusLocalImportTests {

    @Test func importsLocalCorpusWithinBudget() throws {
        let files = EditTestPaths.localMetafiles()
        guard !files.isEmpty else {
            print("\n=== E1a corpus-local: absent (0 files) ===")
            return
        }

        var parsed = 0
        var failed = 0
        var totalElements = 0
        var totalPassthrough = 0
        var emfPlusFiles = 0
        var emfPlusWithEditable = 0
        var maxMicros: Double = 0
        var sumMicros: Double = 0
        let startResident = residentBytes()
        var peakResident = startResident
        let clock = ContinuousClock()

        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let start = clock.now
            let scene: Scene?
            do {
                scene = try SceneImporter.import(data: data)
            } catch {
                failed += 1
                continue
            }
            let micros = Double((clock.now - start).components.attoseconds) / 1e12
                + Double((clock.now - start).components.seconds) * 1e6
            guard let scene else { failed += 1; continue }

            // Partition must be complete for every parseable file.
            #expect(scene.partition.isComplete, "corpus-local partition incomplete (file index \(parsed))")
            parsed += 1
            totalElements += scene.elements.count
            totalPassthrough += scene.elements.filter { $0.kind == .passthrough }.count
            if scene.source.renderPath == .emfPlus {
                emfPlusFiles += 1
                if !scene.editableElements.isEmpty { emfPlusWithEditable += 1 }
            }
            maxMicros = max(maxMicros, micros)
            sumMicros += micros
            peakResident = max(peakResident, residentBytes())
        }

        let peakDeltaMB = Double(peakResident &- startResident) / (1024 * 1024)
        let passthroughShare = totalElements > 0 ? Double(totalPassthrough) / Double(totalElements) * 100 : 0
        print("""

        === E1a corpus-local import (counts only) ===
        files found:      \(files.count)
        parsed:           \(parsed)
        failed to parse:  \(failed)
        EMF+ files:       \(emfPlusFiles) (with editable elements: \(emfPlusWithEditable))
        total elements:   \(totalElements)
        passthrough:      \(totalPassthrough) (\(String(format: "%.1f", passthroughShare))% of elements)
        import time:      max \(String(format: "%.1f", maxMicros / 1000)) ms, total \(String(format: "%.0f", sumMicros / 1000)) ms
        peak resident Δ:  \(String(format: "%.0f", peakDeltaMB)) MB over the batch
        """)
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
