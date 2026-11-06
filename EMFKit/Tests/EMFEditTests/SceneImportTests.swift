import CoreGraphics
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// E1a import gate over every committed corpus file: the record partition is
/// complete and disjoint, element counts are reported, and no file with drawing
/// lifts to zero editable elements.
struct SceneImportTests {

    @Test func importsEveryCommittedFileWithCompletePartition() throws {
        let files = EditTestPaths.committedMetafiles()
        try #require(!files.isEmpty, "no committed corpus files found — see EditTestPaths anchor")

        var report = "\n=== E1a import table (committed corpus) ===\n"
        for url in files {
            let data = try Data(contentsOf: url)
            let scene: Scene
            do {
                scene = try SceneImporter.import(data: data)
            } catch {
                Issue.record("import failed for \(url.lastPathComponent): \(error)")
                continue
            }

            // Partition: every source record in exactly one bucket.
            #expect(scene.partition.isComplete, "partition incomplete for \(url.lastPathComponent): \(scene.partition)")

            // No file lifts zero editable elements while it has editable drawing
            // records. A file with no drawing (only state) legitimately has none.
            // EMF+ files now lift their drawing records into editable elements too
            // (slice E1a2), so the `drawing` bucket drives this for every engine.
            #expect(!scene.editableElements.isEmpty || scene.partition.drawing.isEmpty,
                    "\(url.lastPathComponent): lifted zero editable elements despite drawing records")

            report += line(for: url.lastPathComponent, scene: scene)
        }
        print(report)
    }

    /// Opening and importing twice yields identical scenes (deterministic lift).
    @Test func importIsDeterministic() throws {
        for url in EditTestPaths.committedMetafiles() {
            let data = try Data(contentsOf: url)
            guard let a = try? SceneImporter.import(data: data),
                  let b = try? SceneImporter.import(data: data) else { continue }
            #expect(a == b, "import not deterministic for \(url.lastPathComponent)")
        }
    }

    private func line(for name: String, scene: Scene) -> String {
        let counts = scene.kindCounts
            .sorted { "\($0.key)" < "\($1.key)" }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let passthrough = scene.elements.filter { $0.kind == .passthrough }
        let reasons = Set(passthrough.compactMap { $0.passthroughReason.map { "\($0)" } })
            .sorted().joined(separator: ",")
        return String(
            format: "%-32@ units=%3d path=%@ editable=%2d passthrough=%2d [%@] {%@}\n",
            name, scene.source.unitCount, "\(scene.source.renderPath)",
            scene.editableElements.count, passthrough.count,
            reasons.isEmpty ? "-" : reasons, counts
        )
    }
}
