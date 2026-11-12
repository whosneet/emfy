import AppKit
import EMFRender
import Foundation
import UniformTypeIdentifiers

/// The in-app macOS Service behind Finder's right-click ▸ Services / Quick Actions ▸
/// "Convert to PDF / PNG / SVG with Emfy" (F4c, route (c) from the F4b spike). It runs
/// in the app process — no extra target — and is registered with `NSApp.servicesProvider`
/// at launch. The three `@objc` entry points differ only by output format; all policy
/// lives in the pure `ConvertServicePlanner`, so this object is only the thin AppKit
/// glue that reads the pasteboard, runs the plan, and reports.
///
/// Build-flavour split (owner call): the unsandboxed GitHub/DMG build writes each output
/// beside its original; the sandboxed App Store build can't, so it routes through an
/// NSSavePanel (one file) or an NSOpenPanel folder choice (several) to gain write access.
/// Conversion reuses the same F1 renderer and Settings (PNG scale + background) the
/// viewer's Batch Convert uses, so there is no second code path and no network.
@MainActor
final class MacConvertService: NSObject {
    static let shared = MacConvertService()

    // MARK: - Service entry points
    //
    // The Services machinery delivers these on the main thread, so the whole object is
    // `@MainActor`; each is the first keyword of its NSMessage selector in Info.plist.

    @objc func convertToPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        handle(pboard, format: .pdf)
    }

    @objc func convertToPNG(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        handle(pboard, format: .png)
    }

    @objc func convertToSVG(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        handle(pboard, format: .svg)
    }

    // MARK: - Dispatch

    /// The running build's flavour, read once per invocation.
    private var flavour: ConvertServicePlanner.Flavour {
        #if EMFY_DMG
        .unsandboxed
        #else
        .sandboxed
        #endif
    }

    /// Reads the pasteboard, plans the run and carries it out. The services menu only
    /// delivers file selections of the declared types (NSSendFileTypes), but the plan
    /// re-filters defensively; an empty or non-metafile selection is a silent no-op.
    @MainActor
    func handle(_ pboard: NSPasteboard, format: BatchOutputFormat) {
        let urls = Self.fileURLs(from: pboard)
        let plan = ConvertServicePlanner.plan(
            inputs: urls, format: format, flavour: flavour,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) })
        switch plan {
        case .nothing:
            return
        case .writeBesideOriginals(let outputs):
            let run = convert(outputs, format: format)
            reveal(run.written)
            report(converted: run.converted, skipped: run.skipped)
        case .savePanel(let input, let directory, let fileName):
            runSavePanel(input: input, directory: directory, fileName: fileName, format: format)
        case .chooseFolder(let inputs, let directory):
            runChooseFolder(inputs: inputs, directory: directory, format: format)
        }
    }

    // MARK: - Pasteboard

    /// The file URLs on the pasteboard, in order. Finder hands the Service a file-URL
    /// selection; `readObjects` reads it as `[URL]`.
    static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let items = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return items
    }

    // MARK: - Conversion

    /// Converts a batch of planned outputs with the current Export settings, writing each
    /// to its claimed URL. Hostile/unreadable inputs and write failures are skipped and
    /// counted, never fatal (§8). Returns the tally plus the URLs actually written.
    @MainActor
    private func convert(_ outputs: [ConvertServicePlanner.Output], format: BatchOutputFormat)
        -> (converted: Int, skipped: Int, written: [URL]) {
        let settings = renderSettings()
        var converted = 0
        var skipped = 0
        var written: [URL] = []
        for output in outputs {
            let (result, url) = convertOne(input: output.input, to: output.output, format: format, settings: settings)
            switch result {
            case .converted:
                converted += 1
                if let url { written.append(url) }
            case .skipped:
                skipped += 1
            }
        }
        return (converted, skipped, written)
    }

    /// Converts one file and writes it to `destination`. Returns the classification and,
    /// on success, the written URL.
    @MainActor
    private func convertOne(
        input: URL, to destination: URL, format: BatchOutputFormat,
        settings: (scale: Int, background: RenderBackground, options: RenderOptions)
    ) -> (ConvertServicePlanner.FileResult, URL?) {
        let outcome = BatchRenderer.produce(
            BatchSource(url: input), format: format,
            pngScale: settings.scale, background: settings.background, options: settings.options)
        var wrote = false
        if case .converted(let data) = outcome {
            do {
                try data.write(to: destination, options: .atomic)
                wrote = true
            } catch {
                wrote = false
            }
        }
        let result = ConvertServicePlanner.classify(outcome, wroteSuccessfully: wrote)
        return (result, result == .converted ? destination : nil)
    }

    /// The Export settings the conversion uses: PNG scale, background, and the render
    /// options — the same the viewer's Batch Convert reads.
    @MainActor
    private func renderSettings() -> (scale: Int, background: RenderBackground, options: RenderOptions) {
        let settings = EmfySettings.shared
        let background: RenderBackground = settings.pngBackground == .transparent ? .transparent : .white
        return (settings.defaultPNGScale.multiplier, background, settings.renderOptions)
    }

    // MARK: - Sandboxed panels

    /// Sandboxed single file: a save panel pre-set to the original's folder and name.
    /// Choosing a destination grants the write; Cancel is a silent no-op.
    @MainActor
    private func runSavePanel(input: URL, directory: URL, fileName: String, format: BatchOutputFormat) {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [utType(for: format)]
        panel.canCreateDirectories = true
        panel.prompt = "Convert"
        panel.message = "Choose where to save the converted \(format.displayName)."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let (result, url) = convertOne(input: input, to: destination, format: format, settings: renderSettings())
        switch result {
        case .converted:
            if let url { reveal([url]) }
            report(converted: 1, skipped: 0)
        case .skipped:
            report(converted: 0, skipped: 1)
        }
    }

    /// Sandboxed several files: an open panel asking for a destination folder, pre-set to
    /// the first original's folder. "Choose" grants folder access; then every input is
    /// converted into it with no-overwrite naming.
    @MainActor
    private func runChooseFolder(inputs: [URL], directory: URL, format: BatchOutputFormat) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "Choose"
        panel.message = "Choose a folder for the converted files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let outputs = ConvertServicePlanner.outputs(
            for: inputs, format: format,
            directory: { _ in folder },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) })
        let run = convert(outputs, format: format)
        reveal(run.written)
        report(converted: run.converted, skipped: run.skipped)
    }

    // MARK: - Reveal & report

    /// Selects the written outputs in Finder, as Quick Actions do when they produce files.
    @MainActor
    private func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Shows one summary alert when any file was skipped; stays silent when every file
    /// converted (the owner's rule: no alert when everything succeeded).
    @MainActor
    private func report(converted: Int, skipped: Int) {
        guard let message = ConvertServicePlanner.summaryMessage(converted: converted, skipped: skipped) else { return }
        let alert = NSAlert()
        alert.alertStyle = converted == 0 ? .warning : .informational
        alert.messageText = message
        alert.informativeText = skipped == 1
            ? "One file wasn’t a drawing Emfy could convert, so it was skipped."
            : "\(skipped) files weren’t drawings Emfy could convert, so they were skipped."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The uniform type for a save panel's allowed content type.
    private func utType(for format: BatchOutputFormat) -> UTType {
        switch format {
        case .png: .png
        case .pdf: .pdf
        case .svg: .svg
        }
    }
}

#if DEBUG
extension MacConvertService {
    /// A no-GUI live check for F4c verification. With
    /// `-EmfyDebugConvertService <path> [-EmfyDebugConvertServiceFormat pdf|png|svg]`
    /// it copies the file into a temp folder, puts that copy's URL on a private
    /// pasteboard, invokes the real Service entry point, then writes the resulting
    /// sibling path (or "FAIL") to `<path>.result` and exits. Meaningful under the
    /// Debug-DMG config, where the plan writes beside the (temp) original without a
    /// panel. Release contains none of this — it is inside `#if DEBUG`.
    @MainActor
    static func runDebugHookIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-EmfyDebugConvertService"),
              flagIndex + 1 < args.count else { return }
        let sourcePath = args[flagIndex + 1]
        let format = debugFormat(from: args)
        let resultPath = sourcePath + ".result"

        func finish(_ line: String) -> Never {
            try? line.write(toFile: resultPath, atomically: true, encoding: .utf8)
            exit(0)
        }

        let source = URL(fileURLWithPath: sourcePath)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyConvertServiceProbe-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else {
            finish("FAIL create temp dir")
        }
        let copy = tempDir.appendingPathComponent(source.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else {
            finish("FAIL copy")
        }

        let pboard = NSPasteboard(name: NSPasteboard.Name("EmfyConvertServiceProbe"))
        pboard.clearContents()
        pboard.writeObjects([copy as NSURL])
        shared.handle(pboard, format: format)

        let sibling = copy.deletingPathExtension().appendingPathExtension(format.pathExtension)
        if FileManager.default.fileExists(atPath: sibling.path) {
            finish("OK \(sibling.path)")
        }
        finish("FAIL no sibling at \(sibling.path)")
    }

    private static func debugFormat(from args: [String]) -> BatchOutputFormat {
        guard let i = args.firstIndex(of: "-EmfyDebugConvertServiceFormat"), i + 1 < args.count else { return .pdf }
        return BatchOutputFormat(rawValue: args[i + 1].lowercased()) ?? .pdf
    }
}
#endif
