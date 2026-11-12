import EMFRender
import Foundation
import Observation
import SwiftUI

/// Drives a batch-convert run for the UI (F1 design call 4): it holds the chosen
/// sources, output format and destination, kicks off the pure `BatchConvert` engine
/// with the real `BatchRenderer`, tracks progress, supports Cancel, and surfaces the
/// final per-file report. Cross-platform — the Mac sheet and the iOS flow both drive
/// it; only the file/folder picking is platform-specific.
@MainActor
@Observable
final class BatchConvertController {
    /// Where converted files are written.
    enum DestinationMode: String, CaseIterable, Sendable, Identifiable {
        /// A single folder the user chooses.
        case chosenFolder
        /// Beside each original (owner: "Put files next to originals").
        case nextToOriginals
        var id: String { rawValue }
    }

    /// The metafile extensions a folder scan collects.
    static let metafileExtensions: Set<String> = ["emf", "wmf", "emz", "wmz"]

    var sources: [BatchSource] = []
    var format: BatchOutputFormat = .png
    var destinationMode: DestinationMode = .chosenFolder
    var destinationFolder: URL?
    /// Whether adding a folder recurses into sub-folders.
    var recurseFolders = true

    private(set) var isRunning = false
    private(set) var completed = 0
    /// The finished report, presented as the report sheet; `nil` until a run ends.
    var report: BatchReport?

    @ObservationIgnored private var task: Task<Void, Never>?

    var total: Int { sources.count }

    /// Whether a run can start: at least one source, and a destination the engine can
    /// resolve (a chosen folder, or "next to originals").
    var canRun: Bool {
        !sources.isEmpty
            && !isRunning
            && (destinationMode == .nextToOriginals || destinationFolder != nil)
    }

    // MARK: - Sources

    /// Adds files and/or folders, expanding folders into their metafiles (honouring
    /// `recurseFolders`) and de-duplicating by path. Non-metafiles are ignored.
    func add(_ urls: [URL]) {
        let existing = Set(sources.map { $0.url.standardizedFileURL.path })
        var seen = existing
        for source in Self.expand(urls, recurse: recurseFolders) {
            let path = source.url.standardizedFileURL.path
            if seen.insert(path).inserted {
                sources.append(source)
            }
        }
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
    }

    func clearSources() {
        sources.removeAll()
    }

    /// Expands a mix of files and folders into metafile `BatchSource`s.
    static func expand(_ urls: [URL], recurse: Bool) -> [BatchSource] {
        let fm = FileManager.default
        var result: [BatchSource] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                result.append(contentsOf: metafiles(in: url, recurse: recurse, fm: fm))
            } else if isMetafile(url) {
                result.append(BatchSource(url: url))
            }
        }
        return result
    }

    private static func metafiles(in folder: URL, recurse: Bool, fm: FileManager) -> [BatchSource] {
        let options: FileManager.DirectoryEnumerationOptions = recurse ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options) else {
            return []
        }
        var result: [BatchSource] = []
        for case let url as URL in enumerator where isMetafile(url) {
            result.append(BatchSource(url: url))
        }
        return result
    }

    static func isMetafile(_ url: URL) -> Bool {
        metafileExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Run

    /// Starts the run with the Export settings (PNG scale + background) and the
    /// Rendering options. A no-op when a run can't start or is already in flight.
    func run(settings: EmfySettings) {
        guard canRun else { return }
        isRunning = true
        completed = 0
        report = nil

        let sources = self.sources
        let format = self.format
        let pngScale = settings.defaultPNGScale.multiplier
        let background: RenderBackground = settings.pngBackground == .transparent ? .transparent : .white
        let options = settings.renderOptions
        let mode = destinationMode
        let folder = destinationFolder

        task = Task { @MainActor in
            let result = await BatchConvert.run(
                sources: sources,
                format: format,
                destination: { source in
                    switch mode {
                    case .nextToOriginals: return source.url.deletingLastPathComponent()
                    case .chosenFolder: return folder ?? source.url.deletingLastPathComponent()
                    }
                },
                produce: { source, format in
                    BatchRenderer.produce(source, format: format, pngScale: pngScale, background: background, options: options)
                },
                write: { data, url in try data.write(to: url, options: .atomic) },
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                progress: { done in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.completed = max(self.completed, done)
                    }
                })
            self.report = result
            self.isRunning = false
        }
    }

    /// Cancels an in-flight run; files already converted keep their outputs and appear
    /// in the report.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Clears the finished report so the sheet can start a fresh run.
    func dismissReport() {
        report = nil
    }
}

/// A focused scene command the File ▸ Batch Convert… menu item fires to present the
/// Mac batch sheet (mirrors `NewDrawingCommand`).
struct BatchConvertCommand {
    let present: () -> Void
}

extension FocusedValues {
    @Entry var batchConvertAction: BatchConvertCommand?
}
