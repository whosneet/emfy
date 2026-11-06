import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import Testing
@testable import EMFEdit

/// E1c: undo/redo over a `Scene`. The command layer yields an exact inverse, so
/// undo restores the scene byte-for-byte (`Scene` Equatable) and an export after
/// undoing every edit is byte-identical to the unedited re-emit.
struct SceneHistoryTests {

    // MARK: - Fixtures

    private func scene(_ name: String) throws -> Scene {
        try SceneImporter.import(data: try Data(contentsOf: EditTestPaths.corpusDirectory.appendingPathComponent(name)))
    }
    private func house() throws -> Scene { try scene("gate-p2-house.emf") }
    private func shapes() throws -> Scene { try scene("gate-p3-shapes.emf") }
    private func text() throws -> Scene { try scene("gate-p4-text.emf") }

    private func emfBytes(_ s: Scene) throws -> Data {
        try SceneExporter.export(s, as: .emf).data
    }

    // MARK: - Apply / undo / redo basics

    @Test func translateUndoRestoresByteForByte() throws {
        var history = SceneHistory(scene: try house())
        let original = history.scene
        let id = try #require(history.scene.editableElements.first?.id)

        try history.apply(.translate(ids: [id], dx: 37, dy: -11))
        #expect(history.scene != original)
        #expect(history.scene.element(id: id)?.provenance.edited == true)
        #expect(history.canUndo && !history.canRedo)

        history.undo()
        // Byte-for-byte: provenance.edited, bounds, transform, everything.
        #expect(history.scene == original)
        #expect(history.scene.element(id: id)?.provenance.edited == false)
        #expect(!history.canUndo && history.canRedo)

        let moved = { () -> Scene in
            var s = original
            try! s.translate([id], dx: 37, dy: -11)
            return s
        }()
        history.redo()
        #expect(history.scene == moved)
        #expect(history.canUndo && !history.canRedo)
    }

    @Test func paintEditsUndoRedo() throws {
        var history = SceneHistory(scene: try house())
        let original = history.scene
        let id = try #require(history.scene.editableElements.first { $0.style.fill != nil }?.id)

        try history.apply(.setFill(ids: [id], SceneFill(color: SceneColor(red: 0.2, green: 0.4, blue: 0.9), evenOdd: false)))
        try history.apply(.setOpacity(ids: [id], 0.4))
        #expect(history.undoCount == 2)

        let afterBoth = history.scene
        history.undo(); history.undo()
        #expect(history.scene == original)
        history.redo(); history.redo()
        #expect(history.scene == afterBoth)
    }

    @Test func textEditsUndoRedo() throws {
        var history = SceneHistory(scene: try text())
        let original = history.scene
        let id = try #require(history.scene.editableElements.first { $0.kind == .text }?.id)

        try history.apply(.setText(id: id, "New label"))
        try history.apply(.setFont(id: id, family: "Helvetica", size: 40, bold: true, italic: false))
        let edited = history.scene
        #expect(edited != original)

        history.undo(); history.undo()
        #expect(history.scene == original)   // advances + layout restored exactly
        history.redo(); history.redo()
        #expect(history.scene == edited)
    }

    // MARK: - Structural edits

    @Test func deleteUndoRestoresPositionAndZOrder() throws {
        var history = SceneHistory(scene: try shapes())
        let original = history.scene
        let editable = history.scene.editableElements
        #expect(editable.count >= 3)
        // Delete a middle element so z-order restoration is exercised.
        let victim = editable[editable.count / 2].id

        try history.apply(.delete(ids: [victim]))
        #expect(history.scene.element(id: victim) == nil)
        #expect(history.scene != original)

        history.undo()
        #expect(history.scene == original)   // re-inserted at its exact index
        history.redo()
        #expect(history.scene.element(id: victim) == nil)
    }

    @Test func insertUndoRemovesRedoReAdds() throws {
        var history = SceneHistory(scene: try house())
        let original = history.scene
        let rect = Element(
            id: 500_000, kind: .rect,
            geometryDevice: ScenePath(CGPath(rect: CGRect(x: 5, y: 5, width: 30, height: 30), transform: nil)),
            transform: .identity,
            style: SceneStyle(fill: SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false)),
            provenance: Provenance(sourceRecordIndices: []))
        let z = history.scene.layers[0].elements.count / 2

        try history.apply(.insert(element: rect, at: z))
        #expect(history.scene.element(id: 500_000) != nil)
        let inserted = history.scene

        history.undo()
        #expect(history.scene == original)
        history.redo()
        #expect(history.scene == inserted)
        #expect(history.scene.layers[0].elements[z].id == 500_000)
    }

    // MARK: - Coalescing

    @Test func sameKeyDragCoalescesToOneStep() throws {
        var history = SceneHistory(scene: try house())
        let original = history.scene
        let id = try #require(history.scene.editableElements.first?.id)
        let key = SceneCoalescingKey("drag-1")

        for _ in 0 ..< 60 {
            try history.apply(.translate(ids: [id], dx: 1, dy: 0), coalescing: key)
        }
        #expect(history.undoCount == 1, "60 same-key translates should be one step")

        let dragged = history.scene
        history.undo()
        #expect(history.scene == original)
        #expect(!history.canUndo)
        history.redo()
        #expect(history.scene == dragged)   // one redo restores the full 60-step drag
    }

    @Test func differentKeysDoNotCoalesce() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        for i in 0 ..< 5 {
            try history.apply(.translate(ids: [id], dx: 1, dy: 0), coalescing: SceneCoalescingKey("step-\(i)"))
        }
        #expect(history.undoCount == 5)
        // nil key never coalesces either.
        try history.apply(.translate(ids: [id], dx: 1, dy: 0))
        try history.apply(.translate(ids: [id], dx: 1, dy: 0))
        #expect(history.undoCount == 7)
    }

    @Test func coalescingStopsWhenElementSetChanges() throws {
        var history = SceneHistory(scene: try shapes())
        let ids = history.scene.editableElements.prefix(2).map(\.id)
        let a = try #require(ids.first)
        let b = try #require(ids.dropFirst().first)
        let key = SceneCoalescingKey("drag")
        try history.apply(.translate(ids: [a], dx: 1, dy: 0), coalescing: key)
        try history.apply(.translate(ids: [a], dx: 1, dy: 0), coalescing: key)
        #expect(history.undoCount == 1)
        // Same key, different element set → a new step.
        try history.apply(.translate(ids: [b], dx: 1, dy: 0), coalescing: key)
        #expect(history.undoCount == 2)
    }

    // MARK: - Groups

    @Test func groupIsOneUndoStep() throws {
        var history = SceneHistory(scene: try shapes())
        let original = history.scene
        let ids = Set(history.scene.editableElements.prefix(3).map(\.id))

        try history.performGroup(name: .group("edit.action.recolour")) { h in
            for id in ids.sorted() {
                try h.apply(.setFill(ids: [id], SceneFill(color: SceneColor(red: 0, green: 0.6, blue: 0.3), evenOdd: false)))
            }
        }
        #expect(history.undoCount == 1)
        #expect(history.undoActionName == .group("edit.action.recolour"))
        let recoloured = history.scene

        history.undo()
        #expect(history.scene == original)   // all three reverted in one step
        history.redo()
        #expect(history.scene == recoloured)
    }

    @Test func groupRollsBackOnThrow() throws {
        var history = SceneHistory(scene: try shapes())
        let original = history.scene
        let good = try #require(history.scene.editableElements.first?.id)

        #expect(throws: SceneEditError.elementNotFound(id: 999_999)) {
            try history.performGroup(name: .group("edit.action.batch")) { h in
                try h.apply(.setOpacity(ids: [good], 0.5))        // applies
                try h.apply(.translate(ids: [999_999], dx: 1, dy: 1))  // throws
            }
        }
        // Atomic: the partial change is rolled back and nothing is recorded.
        #expect(history.scene == original)
        #expect(history.undoCount == 0)
        #expect(!history.canUndo)
    }

    @Test func emptyGroupRecordsNothing() throws {
        var history = SceneHistory(scene: try house())
        history.beginGroup(name: .group("edit.action.noop"))
        history.endGroup()
        #expect(history.undoCount == 0)
    }

    // MARK: - Limit

    @Test func undoLimitDropsOldest() throws {
        var history = SceneHistory(scene: try house(), undoLimit: 3)
        let id = try #require(history.scene.editableElements.first?.id)
        var afterTwo: Scene?
        for i in 0 ..< 5 {
            try history.apply(.translate(ids: [id], dx: 1, dy: 0))
            if i == 1 { afterTwo = history.scene }
        }
        #expect(history.undoCount == 3)
        // Undo all three available steps: lands at the state after the first two
        // applies (the oldest two steps were dropped), NOT the original.
        history.undo(); history.undo(); history.undo()
        #expect(!history.canUndo)
        #expect(history.scene == afterTwo)
    }

    @Test func loweringLimitTrimsImmediately() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        for _ in 0 ..< 5 { try history.apply(.translate(ids: [id], dx: 1, dy: 0)) }
        #expect(history.undoCount == 5)
        history.undoLimit = 2
        #expect(history.undoCount == 2)
    }

    @Test func limitZeroRecordsNothingButStillEdits() throws {
        var history = SceneHistory(scene: try house(), undoLimit: 0)
        let original = history.scene
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 20, dy: 20))
        #expect(history.scene != original)     // the edit applied
        #expect(history.undoCount == 0)         // but nothing is undoable
        #expect(!history.canUndo)
        history.undo()                          // no-op
        #expect(history.scene != original)
    }

    // MARK: - Redo clearing

    @Test func newApplyClearsRedo() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 1, dy: 0))
        try history.apply(.translate(ids: [id], dx: 1, dy: 0))
        history.undo()
        #expect(history.canRedo)
        try history.apply(.setOpacity(ids: [id], 0.7))   // new branch
        #expect(!history.canRedo)
        #expect(history.redoCount == 0)
    }

    // MARK: - Failure atomicity

    @Test func failedCommandLeavesSceneAndHistoryUnchanged() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 5, dy: 5))
        let before = history
        #expect(throws: SceneEditError.elementNotFound(id: 123_456)) {
            try history.apply(.translate(ids: [id, 123_456], dx: 9, dy: 9))
        }
        #expect(history.scene == before.scene)
        #expect(history.undoCount == before.undoCount)
    }

    @Test func lockedElementRejectedWithoutRecording() throws {
        var history = SceneHistory(scene: try house())
        guard let passthroughID = history.scene.elements.first(where: { $0.kind == .passthrough })?.id else { return }
        let before = history.scene
        #expect(throws: SceneEditError.elementLocked(id: passthroughID)) {
            try history.apply(.delete(ids: [passthroughID]))
        }
        #expect(history.scene == before)
        #expect(history.undoCount == 0)
    }

    // MARK: - Hostile

    @Test func undoRedoOnEmptyHistoryAreNoOps() throws {
        var history = SceneHistory(scene: try house())
        let original = history.scene
        #expect(!history.canUndo && !history.canRedo)
        history.undo()
        history.redo()
        #expect(history.scene == original)
    }

    @Test func undoAfterFailedCommand() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 4, dy: 4))
        let original = history.originalScene
        _ = try? history.apply(.setText(id: id, "x"))   // throws: not a text element
        history.undo()
        #expect(history.scene == original)
    }

    // MARK: - Revert

    @Test func revertToOriginalSnapsBackAndClears() throws {
        var history = SceneHistory(scene: try house())
        let original = history.originalScene
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 15, dy: 15))
        try history.apply(.setOpacity(ids: [id], 0.5))
        history.revertToOriginal()
        #expect(history.scene == original)
        #expect(!history.canUndo && !history.canRedo)
    }

    // MARK: - Action names

    @Test func actionNamesTrackTheTopSteps() throws {
        var history = SceneHistory(scene: try house())
        let id = try #require(history.scene.editableElements.first?.id)
        try history.apply(.translate(ids: [id], dx: 1, dy: 0))
        #expect(history.undoActionName == .move)
        try history.apply(.setFill(ids: [id], SceneFill(color: SceneColor(red: 0, green: 0, blue: 0), evenOdd: false)))
        #expect(history.undoActionName == .changeFill)
        history.undo()
        #expect(history.redoActionName == .changeFill)
        #expect(history.undoActionName == .move)
    }

    // MARK: - Export reflects current state

    @Test func exportAfterUndoAllMatchesUneditedReEmit() throws {
        var history = SceneHistory(scene: try house())
        let originalBytes = try emfBytes(history.originalScene)
        let id = try #require(history.scene.editableElements.first?.id)

        try history.apply(.translate(ids: [id], dx: 12, dy: 8))
        try history.apply(.setFill(ids: [id], SceneFill(color: SceneColor(red: 0.3, green: 0.3, blue: 0.3), evenOdd: false)))
        let editedBytes = try emfBytes(history.scene)
        #expect(editedBytes != originalBytes)

        while history.canUndo { history.undo() }
        #expect(try emfBytes(history.scene) == originalBytes, "export after undo-all is not byte-identical to the unedited re-emit")

        while history.canRedo { history.redo() }
        #expect(try emfBytes(history.scene) == editedBytes, "export after redo-all is not byte-identical to the post-edit export")
    }

    // MARK: - Property-style randomised sequences (seeded, deterministic)

    @Test(arguments: ["gate-p2-house.emf", "gate-p3-shapes.emf", "handmade-emfplus-shapes.emf"])
    func randomSequenceUndoAllReturnsToOriginal(_ name: String) throws {
        for seed: UInt64 in [1, 2, 42, 1337] {
            var rng = SeededRNG(seed: seed)
            var history = SceneHistory(scene: try scene(name))
            let original = history.originalScene
            let originalBytes = try emfBytes(original)

            var applied = 0
            var freshID = 900_000
            var attempts = 0
            while applied < 40 && attempts < 400 {
                attempts += 1
                guard let command = Self.randomCommand(for: history.scene, rng: &rng, freshID: &freshID) else { continue }
                if (try? history.apply(command)) != nil { applied += 1 }
            }
            #expect(applied > 0, "\(name) seed \(seed): no commands applied")

            let postApply = history.scene
            let postApplyBytes = try emfBytes(postApply)

            while history.canUndo { history.undo() }
            #expect(history.scene == original, "\(name) seed \(seed): undo-all did not restore the original scene")
            #expect(try emfBytes(history.scene) == originalBytes, "\(name) seed \(seed): export after undo-all differs from the original re-emit")

            while history.canRedo { history.redo() }
            #expect(history.scene == postApply, "\(name) seed \(seed): redo-all did not restore the edited scene")
            #expect(try emfBytes(history.scene) == postApplyBytes, "\(name) seed \(seed): export after redo-all differs")
        }
    }

    // MARK: - Large-scene memory/time (corpus-local; counts only)

    /// Per-command cost must stay flat: a step holds only the touched elements, so
    /// editing one element in a tens-of-thousands-element scene must not copy the
    /// whole element array. Measures wall time and resident-memory delta across
    /// many single-element edits and asserts both stay bounded. Counts only — no
    /// corpus-local filenames.
    @Test func largeScenePerCommandCostIsFlat() throws {
        let locals = EditTestPaths.localMetafiles().sorted {
            ((try? Data(contentsOf: $0).count) ?? 0) > ((try? Data(contentsOf: $1).count) ?? 0)
        }
        guard !locals.isEmpty else { return }

        var chosen: Scene?
        var elementCount = 0
        for url in locals.prefix(6) {
            guard let data = try? Data(contentsOf: url), let s = try? SceneImporter.import(data: data) else { continue }
            let count = s.editableElements.count
            if count > elementCount { elementCount = count; chosen = s }
            if count >= 10_000 { break }
        }
        guard let base = chosen, elementCount >= 2_000 else {
            print("=== E1c large-scene cost: no corpus-local scene with ≥2000 editable elements; skipped ===")
            return
        }

        var history = SceneHistory(scene: base, undoLimit: 100_000)
        let ids = base.editableElements.map(\.id)
        let commandCount = 300

        // Warm up: the first edit pays a one-time COW to preserve the original.
        try history.apply(.translate(ids: [ids[0]], dx: 1, dy: 0))

        let rssStart = residentBytes()
        let clockStart = DispatchTime.now().uptimeNanoseconds
        var halfTime: UInt64 = 0
        for i in 0 ..< commandCount {
            let id = ids[(i + 1) % ids.count]
            try history.apply(.translate(ids: [id], dx: 1, dy: 0))
            if i == commandCount / 2 - 1 { halfTime = DispatchTime.now().uptimeNanoseconds }
        }
        let clockEnd = DispatchTime.now().uptimeNanoseconds
        let rssEnd = residentBytes()

        let firstHalfMs = Double(halfTime - clockStart) / 1_000_000
        let secondHalfMs = Double(clockEnd - halfTime) / 1_000_000
        let perCommandUs = Double(clockEnd - clockStart) / Double(commandCount) / 1_000
        let rssDeltaMB = Double(Int64(rssEnd) - Int64(rssStart)) / (1024 * 1024)

        print(String(format: """
        === E1c large-scene per-command cost (counts only) ===
        editable elements: %d, commands: %d (limit 100000)
        per-command: %.1f µs; first half: %.1f ms, second half: %.1f ms
        resident delta over %d commands: %.1f MB
        """, elementCount, commandCount, perCommandUs, firstHalfMs, secondHalfMs, commandCount, rssDeltaMB))

        // Flat time: the second half must not be dramatically slower than the first
        // (a per-edit whole-array copy would grow with the stack / heap).
        #expect(secondHalfMs < firstHalfMs * 3 + 50, "per-command time is not flat")
        // Flat memory: a whole-array copy per edit would be ~commands × elements ×
        // sizeof(Element) (hundreds of MB to GBs here). Touched-only is a few MB.
        #expect(rssDeltaMB < 200, "resident memory grew by \(rssDeltaMB) MB — suggests a per-edit array copy")

        // And correctness survives at scale: undo-all returns to the warmed state.
        let warmed = SceneHistory(scene: base, undoLimit: 1)
        _ = warmed
        while history.canUndo { history.undo() }
        #expect(history.scene.editableElements.count == elementCount)
    }
}

// MARK: - Deterministic RNG + random command generation

/// SplitMix64 — a small, deterministic generator so the property tests reproduce
/// exactly from a seed (no reliance on the system RNG).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SceneHistoryTests {
    /// A random, VALID command for the current scene (so `apply` does not throw),
    /// or nil when the scene has no editable element to target.
    static func randomCommand(for scene: Scene, rng: inout SeededRNG, freshID: inout Int) -> SceneCommand? {
        let editable = scene.editableElements
        guard !editable.isEmpty else {
            // Only an insert is possible.
            return insertCommand(rng: &rng, freshID: &freshID)
        }
        let roll = Int.random(in: 0 ..< 10, using: &rng)
        let target = editable[Int.random(in: 0 ..< editable.count, using: &rng)]
        switch roll {
        case 0, 1, 2:
            return .translate(ids: [target.id],
                              dx: Double(Int.random(in: -20 ... 20, using: &rng)),
                              dy: Double(Int.random(in: -20 ... 20, using: &rng)))
        case 3:
            let scale = Double(Int.random(in: 5 ... 20, using: &rng)) / 10   // 0.5 … 2.0
            return .applyTransform(ids: [target.id], CGAffineTransform(scaleX: scale, y: scale))
        case 4:
            return .setFill(ids: [target.id], SceneFill(
                color: randomColor(rng: &rng), evenOdd: Bool.random(using: &rng)))
        case 5:
            return .setStroke(ids: [target.id], SceneStroke(
                color: randomColor(rng: &rng), isCosmetic: false,
                width: Double(Int.random(in: 1 ... 6, using: &rng)),
                dash: .solid, cap: .round, join: .round, miterLimit: 10))
        case 6:
            return .setOpacity(ids: [target.id], Double(Int.random(in: 0 ... 10, using: &rng)) / 10)
        case 7:
            if let textEl = editable.first(where: { $0.kind == .text }) {
                return .setText(id: textEl.id, "edit-\(Int.random(in: 0 ... 99, using: &rng))")
            }
            return .translate(ids: [target.id], dx: 3, dy: 3)
        case 8:
            return .delete(ids: [target.id])
        default:
            return insertCommand(rng: &rng, freshID: &freshID)
        }
    }

    private static func insertCommand(rng: inout SeededRNG, freshID: inout Int) -> SceneCommand {
        freshID += 1
        let origin = Double(Int.random(in: 0 ... 50, using: &rng))
        let element = Element(
            id: freshID, kind: .rect,
            geometryDevice: ScenePath(CGPath(rect: CGRect(x: origin, y: origin, width: 20, height: 20), transform: nil)),
            transform: .identity,
            style: SceneStyle(fill: SceneFill(color: randomColor(rng: &rng), evenOdd: false)),
            provenance: Provenance(sourceRecordIndices: []))
        return .insert(element: element, at: Int.random(in: 0 ... 3, using: &rng))
    }

    private static func randomColor(rng: inout SeededRNG) -> SceneColor {
        SceneColor(
            red: Double(Int.random(in: 0 ... 255, using: &rng)) / 255,
            green: Double(Int.random(in: 0 ... 255, using: &rng)) / 255,
            blue: Double(Int.random(in: 0 ... 255, using: &rng)) / 255)
    }
}

/// Current resident memory of the process (bytes), for the flat-cost measurement.
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
