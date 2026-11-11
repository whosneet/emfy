import EMFEdit
import Foundation

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
/// overwrite, so the system versions browser works; a location that cannot hold a
/// version (a sandbox scope, a network volume) is skipped silently (design call
/// E2a-6). The write is atomic.
enum CoordinatedDocumentWriter {
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
                try data.write(to: writeURL, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }
}
