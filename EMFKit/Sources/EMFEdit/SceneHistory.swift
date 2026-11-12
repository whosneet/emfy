import CoreGraphics
import Foundation

/// Undo/redo over a `Scene`, built on the `SceneCommand` layer. A value type: it
/// owns the scene and both direction stacks, and every member is `Sendable`, so a
/// view model (E2) can hold and mutate it on the main actor and register its
/// `undo`/`redo` with `UndoManager`.
///
/// Guarantees:
/// - **Exactness.** `undo()` restores the scene byte-for-byte to the state before
///   the step (and `redo()` byte-for-byte to the state after it), because each
///   step stores the touched elements' prior and posterior values rather than a
///   mathematical inverse (see `SceneChange`).
/// - **Cheap on huge scenes.** A step holds only the elements it touched, so a
///   drag of one element costs two stored element values regardless of scene size;
///   consecutive same-key edits coalesce, so a 60-step drag is one step.
/// - **Failure atomicity.** A command that throws leaves BOTH the scene and the
///   history unchanged (the mutation validates up front; nothing is recorded).
/// - **Revert.** `originalScene` is the scene as opened, so E2 can snap back to it
///   without replaying history (docs/v3-plan §11.1).
public struct SceneHistory: Sendable {

    /// The current scene — the result of every applied, non-undone edit.
    public private(set) var scene: Scene

    /// The scene exactly as opened (before any edit). `revertToOriginal()` snaps
    /// back to it; E2 reads it for "Revert to Opened Version".
    public let originalScene: Scene

    /// The most steps kept on the undo stack (oldest dropped past the limit).
    /// 0 disables undo entirely: edits still apply but nothing is recorded.
    /// Default 100.
    public var undoLimit: Int {
        didSet { undoLimit = Swift.max(0, undoLimit); trimToLimit() }
    }

    private var undoStack: [SceneStep] = []
    private var redoStack: [SceneStep] = []
    private var openGroup: OpenGroup?

    /// A recorded, reversible undo step: one or more changes applied as a unit.
    private struct SceneStep: Sendable, Equatable {
        var name: SceneActionName
        var coalescingKey: SceneCoalescingKey?
        var changes: [SceneChange]
    }

    private struct OpenGroup: Sendable {
        var name: SceneActionName
        var changes: [SceneChange]
    }

    public init(scene: Scene, undoLimit: Int = 100) {
        self.scene = scene
        self.originalScene = scene
        self.undoLimit = Swift.max(0, undoLimit)
    }

    // MARK: - Query

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The name of the step `undo()` would reverse (for an "Undo X" menu item).
    public var undoActionName: SceneActionName? { undoStack.last?.name }
    /// The name of the step `redo()` would re-apply (for a "Redo X" menu item).
    public var redoActionName: SceneActionName? { redoStack.last?.name }

    /// The number of undo / redo steps available (inspection, tests).
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// True while a group is open (between `beginGroup` and `endGroup`).
    public var isGroupOpen: Bool { openGroup != nil }

    // MARK: - Apply

    /// Executes `command`, records its exact inverse as an undo step, and clears
    /// the redo stack. If `command` is refused the scene and history are both left
    /// unchanged and the error is rethrown.
    ///
    /// - Parameters:
    ///   - name: overrides the command's default menu name (e.g. a group's name).
    ///   - key: a coalescing key. When it matches the top undo step's key and the
    ///     same element set, this edit merges into that step instead of pushing a
    ///     new one, so an in-progress drag/scrub is a single undo.
    public mutating func apply(
        _ command: SceneCommand,
        name: SceneActionName? = nil,
        coalescing key: SceneCoalescingKey? = nil
    ) throws(SceneEditError) {
        // Mutates `scene` only on success; throws leave it untouched.
        let change = try scene.perform(command)
        let stepName = name ?? command.actionName

        if var group = openGroup {
            group.changes.append(change)
            openGroup = group
            return
        }

        if let key, let top = undoStack.last, top.coalescingKey == key, Self.canMerge(top, with: change) {
            undoStack[undoStack.count - 1] = Self.merged(top, change, name: stepName, key: key)
        } else {
            pushStep(SceneStep(name: stepName, coalescingKey: key, changes: [change]))
        }
        redoStack.removeAll()
    }

    // MARK: - Groups

    /// Opens a group: subsequent `apply`s accumulate into one undo step until
    /// `endGroup()`. Nested opens continue the current group.
    public mutating func beginGroup(name: SceneActionName) {
        if openGroup == nil { openGroup = OpenGroup(name: name, changes: []) }
    }

    /// Closes the open group, pushing the accumulated changes as one step and
    /// clearing redo. An empty group records nothing.
    public mutating func endGroup() {
        guard let group = openGroup else { return }
        openGroup = nil
        guard !group.changes.isEmpty else { return }
        pushStep(SceneStep(name: group.name, coalescingKey: nil, changes: group.changes))
        redoStack.removeAll()
    }

    /// Discards the open group WITHOUT recording anything, rolling back every change it
    /// applied so far — the brand-new-text cancel path (E3c): inserting a text element
    /// opens a group, and cancelling the popover on it must leave no element and no undo
    /// entry. A no-op when no group is open. Unlike `endGroup`, nothing reaches the undo
    /// stack and the scene returns to the pre-group state; the redo stack is untouched.
    public mutating func abortGroup() {
        guard let group = openGroup else { return }
        for change in group.changes.reversed() { scene.undoChange(change) }
        openGroup = nil
    }

    /// Runs `body` as one atomic undo step. If `body` throws, every change it
    /// applied so far is rolled back, nothing is recorded, and the error is
    /// rethrown — so a multi-command operation is all-or-nothing.
    public mutating func performGroup(
        name: SceneActionName,
        _ body: (inout SceneHistory) throws -> Void
    ) rethrows {
        beginGroup(name: name)
        do {
            try body(&self)
        } catch {
            if let group = openGroup {
                for change in group.changes.reversed() { scene.undoChange(change) }
            }
            openGroup = nil
            throw error
        }
        endGroup()
    }

    // MARK: - Undo / redo

    /// Reverses the top undo step (byte-exact). No-op on an empty stack or while a
    /// group is open.
    public mutating func undo() {
        guard openGroup == nil, let step = undoStack.popLast() else { return }
        for change in step.changes.reversed() { scene.undoChange(change) }
        redoStack.append(step)
    }

    /// Re-applies the top redo step (byte-exact). No-op on an empty stack or while
    /// a group is open.
    public mutating func redo() {
        guard openGroup == nil, let step = redoStack.popLast() else { return }
        for change in step.changes { scene.redoChange(change) }
        undoStack.append(step)
    }

    // MARK: - Revert

    /// Snaps the scene back to the opened version and clears all history.
    public mutating func revertToOriginal() {
        scene = originalScene
        undoStack.removeAll()
        redoStack.removeAll()
        openGroup = nil
    }

    // MARK: - Internals

    private mutating func pushStep(_ step: SceneStep) {
        undoStack.append(step)
        trimToLimit()
    }

    private mutating func trimToLimit() {
        if undoLimit <= 0 {
            undoStack.removeAll()
        } else if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
    }

    /// Two steps coalesce only when both are single in-place edits over the same
    /// element set (a drag/scrub). Structural edits never coalesce.
    private static func canMerge(_ step: SceneStep, with change: SceneChange) -> Bool {
        guard step.changes.count == 1,
              case .edit(let existing) = step.changes[0],
              case .edit(let incoming) = change
        else { return false }
        return Set(existing.map(\.id)) == Set(incoming.map(\.id))
    }

    /// Merges `change` into `step`, keeping each element's ORIGINAL `before` and
    /// taking the NEW `after`, so the coalesced step still inverts to the pre-drag
    /// state in one undo and redoes to the latest state.
    private static func merged(
        _ step: SceneStep, _ change: SceneChange, name: SceneActionName, key: SceneCoalescingKey?
    ) -> SceneStep {
        guard case .edit(let existing) = step.changes[0], case .edit(let incoming) = change else { return step }
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let mergedSnapshots = existing.map { snapshot -> ElementSnapshot in
            if let update = incomingByID[snapshot.id] {
                return ElementSnapshot(id: snapshot.id, before: snapshot.before, after: update.after)
            }
            return snapshot
        }
        return SceneStep(name: name, coalescingKey: key, changes: [.edit(mergedSnapshots)])
    }
}
