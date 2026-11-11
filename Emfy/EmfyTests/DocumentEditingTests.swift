import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import Testing

// E2a unit tests for the editable document host: the save-format and WMF-limitation
// mapping, the autosave debounce, the revert-snapshot store, and the `DocumentSession`
// editing layer (begin/apply/undo bridge/save/snapshot/revert/external-change). Like
// DocumentHostTests these compile the shared sources into a hostless logic bundle and
// inject `resolve`/`writeBytes`, so no window or real file-coordination is needed.

// MARK: - Fixtures

/// A valid EMF carrying one fillable rectangle, so `SceneImporter` lifts exactly one
/// editable element. Header (88-byte base) + EMR_RECTANGLE (43) + EMR_EOF (14).
private func editableEMF() -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    // EMR_HEADER
    u32(1); u32(88)
    i32(0); i32(0); i32(99); i32(99)          // rclBounds
    i32(0); i32(0); i32(2117); i32(2117)      // rclFrame
    u32(0x464D4520)                           // " EMF"
    u32(0x0001_0000)                          // nVersion
    u32(88 + 24 + 20)                         // nBytes
    u32(3)                                    // nRecords
    u16(1); u16(0)                            // nHandles, sReserved
    u32(0); u32(0)                            // nDescription, offDescription
    u32(0)                                    // nPalEntries
    i32(1920); i32(1080)                      // szlDevice
    i32(508); i32(286)                        // szlMillimeters
    // EMR_RECTANGLE (type 43, size 24): rclBox left/top/right/bottom
    u32(43); u32(24); i32(10); i32(10); i32(90); i32(90)
    // EMR_EOF
    u32(14); u32(20); u32(0); u32(16); u32(20)
    return d
}

/// Captures the bytes a save wrote, so a test asserts what reached disk.
private final class WriteBox: @unchecked Sendable {
    var data: Data?
    var count = 0
}

/// A sleep that never returns during a test run, so an injected autosave controller
/// stays armed but never fires (the explicit-save tests then control every write).
private let nonFiringSleep: @Sendable (Duration) async -> Void = { _ in
    try? await Task.sleep(for: .seconds(86_400))
}

@MainActor
private func makeEditingSession(
    bytes: Data,
    fileName: String = "drawing.emf",
    snapshotDir: URL? = nil,
    keepSnapshot: Bool = true,
    writeBox: WriteBox,
    autosave: AutosaveController? = nil
) -> DocumentSession {
    DocumentSession(
        entryID: UUID(),
        resolve: { _ in bytes },
        writeBytes: { data, _, _ in writeBox.data = data; writeBox.count += 1 },
        snapshotStore: snapshotDir.map { RevertSnapshotStore(directory: $0) },
        keepRevertSnapshot: { keepSnapshot },
        documentFileName: { fileName },
        autosave: autosave ?? AutosaveController(sleep: nonFiringSleep)
    )
}

private func redFill() -> SceneCommand {
    .setFill(ids: [0], SceneFill(color: SceneColor(red: 1, green: 0, blue: 0), evenOdd: false))
}

/// A session whose scene import is injected directly, so the empty-scene editing
/// rule (E3a design call 2) is tested without hand-building EMF bytes. The resolve
/// succeeds so `beginEditing` reaches the injected import.
@MainActor
private func makeSceneSession(scene: Scene?) -> DocumentSession {
    DocumentSession(
        entryID: UUID(),
        resolve: { _ in Data([0x01]) },
        importScene: { _ in scene },
        documentFileName: { "drawing.emf" },
        autosave: AutosaveController(sleep: nonFiringSleep)
    )
}

/// A scene with one passthrough (verbatim, non-editable) element and no editable
/// elements — content Emfy can view but not edit.
private func passthroughOnlyScene() -> Scene {
    let element = Element(
        id: 0, kind: .passthrough, geometryDevice: ScenePath(), transform: .identity,
        provenance: Provenance(sourceRecordIndices: [1]), locked: true, passthroughReason: .comment
    )
    let layer = Layer(id: 0, name: "Imported", elements: [element])
    let partition = ScenePartition(structural: [0, 2], state: [], drawing: [], passthrough: [1], unitCount: 3)
    let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 3)
    return Scene(
        pageBoundsDevice: CGRect(x: 0, y: 0, width: 100, height: 100),
        layers: [layer], partition: partition, source: source
    )
}

// MARK: - Pure support types

@Suite struct EditingSupportTests {

    @Test func saveFormatFollowsTheFileExtension() {
        #expect(EditingSaveFormat.format(fileName: "a.emf", source: .emf) == .emf)
        #expect(EditingSaveFormat.format(fileName: "a.emz", source: .emf) == .emz)
        #expect(EditingSaveFormat.format(fileName: "a.wmf", source: .wmf) == .wmf)
        #expect(EditingSaveFormat.format(fileName: "a.wmz", source: .placeableWMF) == .wmz)
        // No usable extension: fall back to the scene's own container.
        #expect(EditingSaveFormat.format(fileName: "noext", source: .emf) == .emf)
        #expect(EditingSaveFormat.format(fileName: "noext", source: .placeableWMF) == .wmf)
    }

    @Test func wmfFamilyDetection() {
        #expect(EditingSaveFormat.isWMFFamily(.wmf))
        #expect(EditingSaveFormat.isWMFFamily(.wmz))
        #expect(!EditingSaveFormat.isWMFFamily(.emf))
        #expect(!EditingSaveFormat.isWMFFamily(.emz))
    }

    @Test func wmfLimitationMessageListsPresentCategories() {
        let confirmation = WMFSaveConfirmation(
            format: .wmf,
            categories: [.opacity: 2, .gradient: 1],
            data: Data(),
            warnings: []
        )
        let message = WMFLimitationWording.message(for: confirmation)
        #expect(message.contains(WMFLimitationWording.text(for: .opacity)))
        #expect(message.contains(WMFLimitationWording.text(for: .gradient)))
        #expect(!message.contains(WMFLimitationWording.text(for: .image)))
    }

    @Test func wmfLimitationMessageAlwaysHasABullet() {
        let confirmation = WMFSaveConfirmation(format: .wmf, categories: [:], data: Data(), warnings: [])
        #expect(WMFLimitationWording.message(for: confirmation).contains("•"))
    }

    @Test func externalChangeShowsBannerOnlyWhileDirty() {
        #expect(DocumentSession.externalChangeShowsBanner(isEditing: true, isDirty: true))
        #expect(!DocumentSession.externalChangeShowsBanner(isEditing: true, isDirty: false))
        #expect(!DocumentSession.externalChangeShowsBanner(isEditing: false, isDirty: true))
    }

    @Test func versionIsRecordedOnExplicitSaveAndThrottledForAutosave() {
        let base = Date(timeIntervalSinceReferenceDate: 100_000)
        // Explicit saves always record.
        #expect(DocumentSession.shouldRecordVersion(isAutosave: false, lastVersionDate: nil, now: base))
        #expect(DocumentSession.shouldRecordVersion(isAutosave: false, lastVersionDate: base, now: base))
        // Autosave: first time records; then only after the throttle (1 h) elapses.
        #expect(DocumentSession.shouldRecordVersion(isAutosave: true, lastVersionDate: nil, now: base))
        #expect(!DocumentSession.shouldRecordVersion(isAutosave: true, lastVersionDate: base, now: base.addingTimeInterval(1800)))
        #expect(DocumentSession.shouldRecordVersion(isAutosave: true, lastVersionDate: base, now: base.addingTimeInterval(7200)))
    }

    @Test func saveNoticeOnlyForExplicitSaveWithWarnings() {
        let warnings: [ExportWarning] = [.contentRasterized(elementID: 1), .coordinatesScaled]
        #expect(DocumentSession.saveNotice(isAutosave: false, warnings: warnings) != nil)
        #expect(DocumentSession.saveNotice(isAutosave: true, warnings: warnings) == nil)
        #expect(DocumentSession.saveNotice(isAutosave: false, warnings: []) == nil)
    }

    @Test func savedSummaryNamesTheAffectedAreas() {
        let summary = WMFLimitationWording.savedSummary([.opacity: 1, .text: 2])
        #expect(summary.contains("transparency"))
        #expect(summary.contains("text"))
        #expect(WMFLimitationWording.savedSummary([:]) == "Saved.")
    }

    @Test func needsQuitPromptWhenASaveCannotComplete() {
        #expect(!DocumentEditRegistry.needsQuitPrompt(saveFailed: false, wmfPending: false, stillDirty: false))
        #expect(DocumentEditRegistry.needsQuitPrompt(saveFailed: true, wmfPending: false, stillDirty: false))
        #expect(DocumentEditRegistry.needsQuitPrompt(saveFailed: false, wmfPending: true, stillDirty: false))
        #expect(DocumentEditRegistry.needsQuitPrompt(saveFailed: false, wmfPending: false, stillDirty: true))
    }

    // E2d: the window-close decision reuses needsQuitPrompt after the flush.
    @Test func windowCloseNeedsPromptMatchesTheQuitCheck() {
        #expect(!WindowCloseDecision.needsPromptAfterFlush(saveFailed: false, wmfPending: false, stillDirty: false))
        #expect(WindowCloseDecision.needsPromptAfterFlush(saveFailed: false, wmfPending: false, stillDirty: true))
        #expect(WindowCloseDecision.needsPromptAfterFlush(saveFailed: true, wmfPending: false, stillDirty: false))
        #expect(WindowCloseDecision.needsPromptAfterFlush(saveFailed: false, wmfPending: true, stillDirty: false))
    }

    // E2d: Don't Save always closes; Cancel always keeps open; Save closes only when the
    // save finished cleanly, and keeps the window open while anything still needs attention.
    @Test func windowCloseOutcomeMapsEachChoice() {
        #expect(WindowCloseDecision.outcome(choice: .dontSave, stillNeedsPromptAfterSave: true) == .closeNow)
        #expect(WindowCloseDecision.outcome(choice: .dontSave, stillNeedsPromptAfterSave: false) == .closeNow)
        #expect(WindowCloseDecision.outcome(choice: .cancel, stillNeedsPromptAfterSave: false) == .keepOpen)
        #expect(WindowCloseDecision.outcome(choice: .cancel, stillNeedsPromptAfterSave: true) == .keepOpen)
        #expect(WindowCloseDecision.outcome(choice: .save, stillNeedsPromptAfterSave: false) == .closeNow)
        #expect(WindowCloseDecision.outcome(choice: .save, stillNeedsPromptAfterSave: true) == .keepOpen)
    }
}

// MARK: - Sandbox-safe writer

@Suite struct CoordinatedWriterTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmfyWrite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func safeWriteCreatesANewFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("new.emf")
        let method = try CoordinatedDocumentWriter.safeWrite(Data([1, 2, 3]), to: url)
        #expect(method == .replacement)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func safeWriteReplacesAnExistingFileAndLeavesNoSibling() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.emf")
        try Data([0]).write(to: url)
        _ = try CoordinatedDocumentWriter.safeWrite(Data([9, 9, 9, 9]), to: url)
        #expect(try Data(contentsOf: url) == Data([9, 9, 9, 9]))
        // No stray replacement temp left beside the destination.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings == ["doc.emf"])
    }
}

// MARK: - Revert snapshot store

@Suite struct RevertSnapshotStoreTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfySnap-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test func writesOnceAndReadsBack() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RevertSnapshotStore(directory: dir)
        let id = UUID()
        #expect(!store.hasSnapshot(for: id))
        #expect(store.writeIfAbsent(entryID: id, data: Data([1, 2, 3]), originalFileName: "a.emf"))
        #expect(store.hasSnapshot(for: id))
        let read = store.read(for: id)
        #expect(read?.data == Data([1, 2, 3]))
        #expect(read?.originalFileName == "a.emf")
    }

    @Test func secondWriteDoesNotReplace() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RevertSnapshotStore(directory: dir)
        let id = UUID()
        #expect(store.writeIfAbsent(entryID: id, data: Data([1]), originalFileName: "a.emf"))
        #expect(!store.writeIfAbsent(entryID: id, data: Data([9, 9]), originalFileName: "b.emf"))
        #expect(store.read(for: id)?.data == Data([1]))   // the first snapshot survives
    }

    @Test func pruneDeletesTheSnapshot() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = RevertSnapshotStore(directory: dir)
        let id = UUID()
        store.writeIfAbsent(entryID: id, data: Data([1]), originalFileName: "a.emf")
        store.prune(entryID: id)
        #expect(!store.hasSnapshot(for: id))
    }
}

// MARK: - Autosave debounce (injected clock)

@MainActor
@Suite struct AutosaveControllerTests {

    /// The injected clock for the debounce: every scheduled fire parks in `wait()`
    /// until the test releases them all, so timing is deterministic. `waiterCount`
    /// lets the test release only once every scheduled task has parked (otherwise a
    /// task that parks after the release would hang).
    private final class Gate: @unchecked Sendable {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let lock = NSLock()
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock(); waiters.append(continuation); lock.unlock()
            }
        }
        func waiterCount() -> Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
        func releaseAll() {
            lock.lock(); let pending = waiters; waiters.removeAll(); lock.unlock()
            for continuation in pending { continuation.resume() }
        }
    }

    /// Spins the main actor until `gate` has at least `n` parked fires.
    private func awaitWaiters(_ gate: Gate, atLeast n: Int) async {
        while gate.waiterCount() < n { await Task.yield() }
    }

    @Test func burstOfSchedulesCollapsesToOneFire() async {
        let gate = Gate()
        let controller = AutosaveController(sleep: { _ in await gate.wait() })
        let fires = Counter()
        controller.schedule { fires.bump() }
        controller.schedule { fires.bump() }
        controller.schedule { fires.bump() }   // only this survives; the earlier two cancel
        // All three tasks park; the two cancelled ones return without firing on release.
        await awaitWaiters(gate, atLeast: 3)
        gate.releaseAll()
        await controller.pendingValueForTesting()
        #expect(fires.value == 1)
    }

    @Test func cancelStopsThePendingFire() async {
        let gate = Gate()
        let controller = AutosaveController(sleep: { _ in await gate.wait() })
        let fires = Counter()
        controller.schedule { fires.bump() }
        controller.cancel()
        await awaitWaiters(gate, atLeast: 1)   // the cancelled task still parks
        gate.releaseAll()                       // …and returns without firing
        await Task.yield()
        #expect(fires.value == 0)
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

// MARK: - DocumentSession editing layer

@MainActor
@Suite struct DocumentEditingTests {

    @Test func beginEditingImportsAnEditableScene() async {
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        #expect(session.editing == .notEditing)
        await session.beginEditing()
        #expect(session.editing == .editing)
        #expect(session.history != nil)
        #expect(!session.isDirty)
    }

    // E3a design call 2: a truly empty scene (0 elements) — a new/blank document —
    // is editable; only a scene with content but NONE of it editable opens read-only.

    @Test func emptySceneIsEditable() async {
        // A real blank document imports to a scene with zero elements.
        let scene = try? SceneImporter.import(data: SceneFactory.blankDocument(pageSizeMillimetres: CGSize(width: 297, height: 210)))
        let session = makeSceneSession(scene: scene)
        await session.beginEditing()
        #expect(session.editing == .editing)
        #expect(session.history?.scene.elements.isEmpty == true)
    }

    @Test func contentButNoneEditableOpensReadOnly() async {
        // A scene with content, all of it passthrough (verbatim, non-editable): the
        // viewer shows it, but there is nothing to edit, so editing is unavailable.
        let session = makeSceneSession(scene: passthroughOnlyScene())
        await session.beginEditing()
        #expect(session.editing == .unavailable)
    }

    @Test func importFailureOpensReadOnly() async {
        // An unliftable file (import returns nil) stays read-only.
        let session = makeSceneSession(scene: nil)
        await session.beginEditing()
        #expect(session.editing == .unavailable)
    }

    @Test func applyMakesTheDocumentDirty() async {
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        session.apply(redFill())
        #expect(session.isDirty)
        #expect(session.editVersion > 0)
    }

    // E2d: the window-close "Don't Save" path drops edits and leaves edit mode WITHOUT
    // writing — nothing reaches the write path.
    @Test func discardEditsAndStopEditingWritesNothing() async {
        let writeBox = WriteBox()
        let session = makeEditingSession(bytes: editableEMF(), writeBox: writeBox)
        await session.beginEditing()
        session.apply(redFill())
        #expect(session.isDirty)

        session.discardEditsAndStopEditing()
        #expect(session.editing == .notEditing)
        #expect(!session.isDirty)
        #expect(session.editingScene == nil)
        #expect(writeBox.count == 0)   // no bytes written on discard
    }

    @Test func undoViaUndoManagerRestoresSceneAndClearsDirty() async {
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        let original = session.history!.scene
        session.apply(redFill())
        #expect(session.isDirty)
        #expect(session.undoManager.canUndo)

        session.undoManager.undo()
        #expect(session.history!.scene == original)   // byte-exact restore
        #expect(!session.isDirty)

        session.undoManager.redo()
        #expect(session.history!.scene != original)
        #expect(session.isDirty)
    }

    @Test func coalescedCommandsAreOneUndoEntry() async {
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        let original = session.history!.scene
        let key = SceneCoalescingKey("drag")
        session.apply(.setOpacity(ids: [0], 0.9), coalescing: key)
        session.apply(.setOpacity(ids: [0], 0.7), coalescing: key)
        session.apply(.setOpacity(ids: [0], 0.5), coalescing: key)

        session.undoManager.undo()
        #expect(session.history!.scene == original)      // one undo reverses the whole drag
        #expect(!session.undoManager.canUndo)
        #expect(!session.isDirty)
    }

    @Test func saveWritesBytesThatReimportToAnEquivalentScene() async {
        let box = WriteBox()
        let session = makeEditingSession(bytes: editableEMF(), writeBox: box)
        await session.beginEditing()
        let editableBefore = session.history!.scene.editableElements.count
        session.apply(redFill())
        await session.save()

        let written = try! #require(box.data)
        let reimported = try! SceneImporter.import(data: written)
        #expect(reimported.editableElements.count == editableBefore)
        #expect(!session.isDirty)   // clean after save
    }

    @Test func editThenUndoKeepsTheOriginalBytesVerbatim() async {
        let original = editableEMF()
        let session = makeEditingSession(bytes: original, writeBox: WriteBox())
        await session.beginEditing()
        session.apply(redFill())
        session.undoManager.undo()
        #expect(!session.isDirty)
        // Re-exporting the undone (unchanged) scene re-emits the source verbatim.
        #expect(session.sceneExportData(as: .emf) == original)
    }

    @Test func wmfSavePathSurfacesTheConfirmationState() async {
        let box = WriteBox()
        // The .wmf file name routes the save through the WMF container (cross-container).
        let session = makeEditingSession(bytes: editableEMF(), fileName: "drawing.wmf", writeBox: box)
        await session.beginEditing()
        session.apply(redFill())
        await session.save()
        // First WMF save does not write — it raises the limitations confirmation.
        #expect(session.pendingWMFConfirmation != nil)
        #expect(session.pendingWMFConfirmation?.format == .wmf)
        #expect(box.count == 0)

        await session.confirmPendingWMFSave()
        #expect(session.pendingWMFConfirmation == nil)
        #expect(box.count == 1)   // Save Anyway wrote the stashed bytes
    }

    @Test func firstSaveSnapshotsOnceAndRevertRestores() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmfyE2a-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = WriteBox()
        let original = editableEMF()
        let session = makeEditingSession(bytes: original, snapshotDir: dir, writeBox: box)
        await session.beginEditing()
        let snapshots = RevertSnapshotStore(directory: dir)
        let id = session.entryID

        session.apply(redFill())
        await session.save()
        #expect(snapshots.hasSnapshot(for: id))
        #expect(snapshots.read(for: id)?.data == original)   // the opened bytes

        // A second save must not replace the snapshot.
        session.apply(.setOpacity(ids: [0], 0.5))
        await session.save()
        #expect(snapshots.read(for: id)?.data == original)

        await session.revertToOpenedVersion()
        #expect(box.data == original)                        // original bytes written back
        #expect(session.editing == .notEditing)
        #expect(!session.undoManager.canUndo)                // undo cleared
    }

    @Test func snapshotIsSkippedWhenTheSettingIsOff() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmfyE2a-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = makeEditingSession(bytes: editableEMF(), snapshotDir: dir, keepSnapshot: false, writeBox: WriteBox())
        await session.beginEditing()
        session.apply(redFill())
        await session.save()
        #expect(!RevertSnapshotStore(directory: dir).hasSnapshot(for: session.entryID))
    }

    @Test func externalChangeWhileDirtyRaisesBannerAndDoesNotReload() async {
        // A REAL content change while dirty (no save yet, so no written fingerprint;
        // the loaded fingerprint differs) raises the banner, never a reload.
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        session.apply(redFill())
        let installsBefore = session.modelInstallCount
        await session.handleExternalChange()
        #expect(session.showsExternalChangeBanner)
        #expect(session.modelInstallCount == installsBefore)   // no reload
    }

    @Test func ourOwnSaveDoesNotRaiseTheChangedOnDiskBanner() async {
        // E2b item 2: the presenter event our own coordinated write triggers must not
        // raise the banner — the on-disk bytes match what we just wrote.
        let box = WriteBox()
        let session = DocumentSession(
            entryID: UUID(),
            resolve: { _ in box.data ?? editableEMF() },   // after a save, resolves the written bytes
            writeBytes: { data, _, _ in box.data = data; box.count += 1 },
            documentFileName: { "drawing.emf" },
            autosave: AutosaveController(sleep: nonFiringSleep)
        )
        await session.beginEditing()
        session.apply(redFill())
        await session.save()
        #expect(box.data != nil)
        await session.handleExternalChange()   // the presenter event our write triggered
        #expect(!session.showsExternalChangeBanner)
        #expect(session.editing == .editing)   // edit mode survives our own save
    }

    @Test func sameContentChangeKeepsEditModeAndRaisesNoBanner() async {
        // E2b item 2: a spurious / attribute-only change (identical content) keeps edit
        // mode — only a genuine content change ends it.
        let data = editableEMF()
        let session = DocumentSession(
            entryID: UUID(),
            resolve: { _ in data },
            documentFileName: { "drawing.emf" },
            autosave: AutosaveController(sleep: nonFiringSleep)
        )
        await session.load()           // sets the loaded-content fingerprint
        await session.beginEditing()
        #expect(session.editing == .editing)
        await session.handleExternalChange()   // resolves identical bytes → ignored
        #expect(session.editing == .editing)
        #expect(!session.showsExternalChangeBanner)
    }

    @Test func editedSceneSurvivesASave() async {
        // Review #1: after a save the document is clean, but the viewer must keep
        // drawing the edited scene rather than falling back to the original.
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        #expect(session.editedScene == nil)   // unedited: tiled path
        session.apply(redFill())
        await session.save()
        #expect(!session.isDirty)
        #expect(session.editedScene != nil)   // still showing the edits
        // Undoing all the way back to the opened scene returns to the tiled path.
        session.undoManager.undo()
        #expect(session.editedScene == nil)
    }

    @Test func externalChangeWhileEditingButCleanDropsStaleEditState() async {
        // Review #2: an external change while editing-and-clean must not keep stale
        // history/openedBytes around for the next edit to clobber.
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        #expect(session.editing == .editing)
        #expect(!session.isDirty)
        await session.handleExternalChange()
        #expect(session.editing == .notEditing)
        #expect(session.history == nil)
        #expect(!session.showsExternalChangeBanner)
    }

    @Test func registryTracksDirtyEditingSessions() async {
        let session = makeEditingSession(bytes: editableEMF(), writeBox: WriteBox())
        await session.beginEditing()
        session.apply(redFill())
        #expect(DocumentEditRegistry.shared.dirtySessions.contains { $0 === session })
        DocumentEditRegistry.shared.unregister(session)
        #expect(!DocumentEditRegistry.shared.activeSessions.contains { $0 === session })
    }

    @Test func autosaveFiresAfterAnEdit() async {
        let box = WriteBox()
        let autosave = AutosaveController(sleep: { _ in })   // immediate
        let session = makeEditingSession(bytes: editableEMF(), writeBox: box, autosave: autosave)
        await session.beginEditing()
        session.apply(redFill())
        await autosave.pendingValueForTesting()
        #expect(box.count >= 1)
        #expect(!session.isDirty)
    }
}

// MARK: - Store pruning + real-file round trip

@MainActor
@Suite struct DocumentEditingStoreTests {

    private func makeStore() -> (RecentsStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyE2aStore-\(UUID().uuidString)", isDirectory: true)
        let store = RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        ))
        return (store, dir)
    }

    @Test func removingARecentsEntryPrunesItsSnapshot() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("doc.emf")
        try editableEMF().write(to: src)
        let id = try #require(await store.handleOpenedURL(src))

        let snapshots = RevertSnapshotStore(directory: store.locations.snapshotsDirectory)
        snapshots.writeIfAbsent(entryID: id, data: editableEMF(), originalFileName: "doc.emf")
        #expect(snapshots.hasSnapshot(for: id))

        store.remove(id)
        store.commitPendingRemoval()   // side files are deleted on commit
        #expect(!snapshots.hasSnapshot(for: id))
    }

    @Test func corpusEMFRoundTripReparsesCleanly() async throws {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/gate-p2-star.emf")
        let original = try Data(contentsOf: corpus)
        let originalRecords = try EMFFile.parse(original).records.count

        let box = WriteBox()
        let session = makeEditingSession(bytes: original, fileName: "star.emf", writeBox: box)
        await session.beginEditing()
        guard session.editing == .editing, let firstID = session.history?.scene.editableElements.first?.id else {
            Issue.record("corpus EMF produced no editable element")
            return
        }
        session.apply(.setFill(ids: [firstID], SceneFill(color: SceneColor(red: 0.2, green: 0.4, blue: 0.9), evenOdd: false)))
        await session.save()

        let saved = try #require(box.data)
        let savedFile = try EMFFile.parse(saved)   // throws on a malformed stream
        // Report-only figures (surfaced in the handback): sizes and record counts.
        #expect(savedFile.records.count >= 2)   // at least HEADER … EOF
        #expect(saved.count > 0)
        // Round trip is an overlay: unedited records are kept verbatim and the
        // recoloured element is re-synthesised, so the saved stream is a small
        // superset of the original (observed: 6592→6784 B, 297→310 records) and
        // re-parses without error.
        #expect(savedFile.records.count >= originalRecords)
    }
}
