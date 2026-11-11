import EMFEdit
import Foundation
import os

/// Supporting value types and small services for the editable document host (E2a):
/// the save-format mapping, the autosave debounce, the coordinated file writer, the
/// typed save error, and the WMF save-confirmation payload. Kept out of
/// `DocumentSession` so the session reads as the state machine it is, and so each
/// piece is unit-tested on its own.

// MARK: - Save format

/// Which container a save-in-place writes, preserving the file's own format
/// (design call E2a-4): EMF → EMF, EMZ → gzip EMF, WMF → WMF, WMZ → gzip WMF. The
/// decision is the file's extension first (what the user named it), with the scene's
/// own source container as the fallback when the name has no metafile extension.
enum EditingSaveFormat {
    static func format(fileName: String, source: SceneSource.Format) -> EMFEdit.ExportFormat {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "emf": return .emf
        case "emz": return .emz
        case "wmf": return .wmf
        case "wmz": return .wmz
        default:
            switch source {
            case .emf: return .emf
            case .wmf, .placeableWMF: return .wmf
            }
        }
    }

    /// WMF or WMZ — the containers that need the limitations confirmation before the
    /// first save (design call E2a-5).
    static func isWMFFamily(_ format: EMFEdit.ExportFormat) -> Bool {
        format == .wmf || format == .wmz
    }
}

// MARK: - Save error (typed; never a trap — §8)

/// Why a save failed, surfaced to the user as a toast (design call E2a-9).
enum DocumentSaveError: Error, Equatable, Sendable {
    /// No edit session is active.
    case notEditing
    /// The entry's write destination could not be resolved (dead bookmark).
    case noDestination
    /// `SceneExporter` refused to serialise the scene.
    case exportFailed(String)
    /// The coordinated write to disk failed.
    case writeFailed(String)

    /// A short, plain-language message for the toast.
    var message: String {
        switch self {
        case .notEditing: return "There are no edits to save."
        case .noDestination: return "Emfy couldn’t find where to save this file."
        case .exportFailed: return "Emfy couldn’t prepare this drawing to save."
        case .writeFailed: return "Emfy couldn’t write the file to disk."
        }
    }
}

// MARK: - Saved-with-limitations notice

/// A notice that a non-WMF explicit save lost some fidelity (review #5), surfaced
/// as a toast. Carries the grouped warning categories so the toast can name the
/// affected areas.
struct SaveNotice: Equatable, Sendable {
    let categories: [ExportWarningCategory: Int]
}

// MARK: - Active-editing registry (quit/close flush)

/// Tracks the live document sessions that are in edit mode, so the app can flush and
/// prompt for unsaved edits on quit (and, on iOS, on scene background). Holds weak
/// references, so a closed window's session is dropped automatically (review #7).
@MainActor
final class DocumentEditRegistry {
    static let shared = DocumentEditRegistry()

    private final class Box {
        weak var session: DocumentSession?
        init(_ session: DocumentSession) { self.session = session }
    }
    private var boxes: [ObjectIdentifier: Box] = [:]

    func register(_ session: DocumentSession) {
        boxes[ObjectIdentifier(session)] = Box(session)
    }
    func unregister(_ session: DocumentSession) {
        boxes[ObjectIdentifier(session)] = nil
    }

    /// The still-live registered sessions, pruning any that have been deallocated.
    var activeSessions: [DocumentSession] {
        boxes = boxes.filter { $0.value.session != nil }
        return boxes.values.compactMap(\.session)
    }

    /// Sessions with unsaved edits right now.
    var dirtySessions: [DocumentSession] {
        activeSessions.filter { $0.editing == .editing && $0.isDirty }
    }

    /// Whether quitting/closing must prompt after a flush: a save failed, a WMF
    /// confirmation is pending, or the document is still dirty (review #7). Pure.
    nonisolated static func needsQuitPrompt(saveFailed: Bool, wmfPending: Bool, stillDirty: Bool) -> Bool {
        saveFailed || wmfPending || stillDirty
    }
}

// MARK: - Window-close decision (E2d)

/// The user's choice in a Mac window-close "unsaved changes" sheet.
enum WindowCloseChoice: Equatable, Sendable { case save, dontSave, cancel }

/// What a Mac window close must do after the user's choice resolves (E2d). Pure so
/// the AppKit `windowShouldClose` bridge stays a thin shell over tested logic.
enum WindowCloseAction: Equatable, Sendable {
    /// Close the window now (a clean window, "Don't Save", or a "Save…" that finished
    /// cleanly).
    case closeNow
    /// Keep the window open ("Cancel", or a "Save…" that still needs attention — a
    /// pending WMF confirmation or a failed save).
    case keepOpen
}

/// The pure window-close decision logic (E2d). `needsPromptAfterFlush` reuses
/// `DocumentEditRegistry.needsQuitPrompt` for the single session a Mac library window
/// hosts, and `outcome` maps the sheet choice (and, for Save…, the post-save state)
/// to the window action. Unit-tested; the AppKit flow only wires it to NSWindow.
enum WindowCloseDecision {
    /// Whether closing must raise the sheet after flushing the session's pending save.
    static func needsPromptAfterFlush(saveFailed: Bool, wmfPending: Bool, stillDirty: Bool) -> Bool {
        DocumentEditRegistry.needsQuitPrompt(saveFailed: saveFailed, wmfPending: wmfPending, stillDirty: stillDirty)
    }

    /// The action for a sheet choice. For `.save`, `stillNeedsPromptAfterSave` is the
    /// session's post-save state: a WMF confirmation or a failed save keeps the window
    /// open (the SwiftUI dialog / error toast takes over); a clean save closes it.
    static func outcome(choice: WindowCloseChoice, stillNeedsPromptAfterSave: Bool) -> WindowCloseAction {
        switch choice {
        case .dontSave: return .closeNow
        case .cancel: return .keepOpen
        case .save: return stillNeedsPromptAfterSave ? .keepOpen : .closeNow
        }
    }
}

// MARK: - WMF save confirmation

/// The first-save confirmation state for a WMF/WMZ document (design call E2a-5). It
/// carries the already-exported bytes and the grouped warning categories, so the
/// viewer can list what WMF cannot hold and, on "Save Anyway", write the stashed
/// bytes without re-exporting.
struct WMFSaveConfirmation: Equatable, Sendable {
    let format: EMFEdit.ExportFormat
    let categories: [ExportWarningCategory: Int]
    let data: Data
    let warnings: [ExportWarning]
}

/// Plain-language wording for each export-warning category, used in the WMF
/// limitations confirmation (design call E2a-5). One phrase per category the app
/// shows the user; kept here so the Mac and iOS surfaces read identically.
enum WMFLimitationWording {
    /// The full confirmation message: an intro plus one bullet per warning category
    /// present in a pending WMF save.
    static func message(for confirmation: WMFSaveConfirmation) -> String {
        var lines = ["WMF is an older format and can’t hold everything in this drawing:"]
        for category in ExportWarningCategory.allCases where (confirmation.categories[category] ?? 0) > 0 {
            lines.append("• \(text(for: category))")
        }
        if lines.count == 1 { lines.append("• some modern features may be approximated") }
        return lines.joined(separator: "\n")
    }

    /// A one-line toast summary for any save (WMF or EMF) that lost fidelity (review
    /// #5): "Saved — some features were simplified: transparency, text." Empty
    /// categories give a plain confirmation.
    static func savedSummary(_ categories: [ExportWarningCategory: Int]) -> String {
        let areas = ExportWarningCategory.allCases
            .filter { (categories[$0] ?? 0) > 0 }
            .map { area(for: $0) }
        guard !areas.isEmpty else { return "Saved." }
        return "Saved — some features were simplified: " + areas.joined(separator: ", ") + "."
    }

    /// A short noun for a warning category, for the one-line summary.
    static func area(for category: ExportWarningCategory) -> String {
        switch category {
        case .opacity: return "transparency"
        case .gradient: return "gradients"
        case .text: return "text"
        case .image: return "images"
        case .shapeApproximated: return "shapes"
        case .coordinates: return "scale"
        case .droppedContent: return "dropped content"
        case .rasterized: return "rasterised content"
        case .downlevelStale: return "older-reader fidelity"
        }
    }

    static func text(for category: ExportWarningCategory) -> String {
        switch category {
        case .opacity: return "see-through (transparency) is made solid"
        case .gradient: return "colour gradients become a single colour"
        case .text: return "some text is narrowed or loses its angle"
        case .image: return "rotated images are flattened to a box"
        case .shapeApproximated: return "some shapes are redrawn as outlines"
        case .coordinates: return "the drawing is scaled to fit 16-bit coordinates"
        case .droppedContent: return "some content can’t be kept at all"
        case .rasterized: return "some content is turned into a picture"
        case .downlevelStale: return "an older reader may see the pre-edit drawing"
        }
    }
}

// MARK: - Autosave debounce

/// Collapses a burst of edits into a single autosave that fires after an idle delay
/// (design call E2a-6). `sleep` is injected, so a test drives the debounce with a
/// controllable clock instead of wall-clock time: every `schedule` cancels the
/// pending fire, and only the last one survives to run its action.
@MainActor
final class AutosaveController {
    private var task: Task<Void, Never>?
    let delay: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        delay: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    /// Schedules `action` to run after the idle delay, cancelling any pending fire.
    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = self.delay
        let sleep = self.sleep
        task = Task { @MainActor in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    /// Cancels any pending autosave (e.g. after an explicit save).
    func cancel() {
        task?.cancel()
        task = nil
    }

    #if DEBUG
    /// Awaits the pending fire, so a test observes the debounce result
    /// deterministically.
    func pendingValueForTesting() async {
        await task?.value
    }
    #endif
}

// MARK: - Coordinated write

/// Writes an edited document back to disk through `NSFileCoordinator`, excluding the
/// session's own presenter so our write does not trigger a self-reload (design call
/// E2a-4). On macOS it records an `NSFileVersion` of the current bytes before the
/// overwrite when asked (throttled by the caller, review #4); a location that cannot
/// hold a version is skipped silently.
///
/// The write is **sandbox-safe** (review #3). `Data.write(.atomic)` stages its temp
/// file as a sibling in the destination's parent directory, which a file-only
/// security scope may forbid. Instead, per Apple's "safe save" guidance, it stages
/// into an `.itemReplacementDirectory` (a system-provided temp alongside the volume)
/// and swaps it in with `FileManager.replaceItemAt`, which the scope allows for a
/// user-selected file. A direct non-atomic write is used only as a permission-error
/// fallback, and the path taken is logged.
enum CoordinatedDocumentWriter {
    private static let log = Logger(subsystem: "com.avneetsingh.emfy", category: "save")

    /// How the bytes reached disk, for logging and the test seam.
    enum WriteMethod: String, Sendable { case replacement, directFallback }

    static func write(
        _ data: Data,
        to url: URL,
        presenter: NSFilePresenter?,
        recordVersion: Bool
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            #if os(macOS)
            if recordVersion, FileManager.default.fileExists(atPath: writeURL.path) {
                // Best-effort: a scope or volume that rejects versions is skipped.
                _ = try? NSFileVersion.addOfItem(at: writeURL, withContentsOf: writeURL, options: [])
            }
            #endif
            do {
                let method = try safeWrite(data, to: writeURL)
                log.debug("save wrote via \(method.rawValue, privacy: .public)")
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    /// Stages `data` in an item-replacement directory and swaps it into `url`
    /// (`replaceItemAt`), falling back to a direct non-atomic write only on a
    /// permission error. Returns the method used. Testable with any writable `url`.
    @discardableResult
    static func safeWrite(_ data: Data, to url: URL) throws -> WriteMethod {
        let fm = FileManager.default
        do {
            let tempDir = try fm.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
            )
            defer { try? fm.removeItem(at: tempDir) }
            let tempURL = tempDir.appendingPathComponent(url.lastPathComponent.isEmpty ? "metafile" : url.lastPathComponent)
            try data.write(to: tempURL)   // non-atomic, into our own temp directory
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)   // first write: no existing item to replace
            }
            return .replacement
        } catch {
            // Only a permission failure justifies the direct fallback; anything else
            // (out of space, read-only volume) is a real error the caller must see.
            guard isPermissionError(error) else { throw error }
            try data.write(to: url, options: [])
            return .directFallback
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileWriteNoPermission.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}
