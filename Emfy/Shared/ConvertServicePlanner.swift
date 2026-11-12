import Foundation

/// The pure policy behind Finder's "Convert … with Emfy" Service (F4c, route (c) from
/// the F4b spike). It never touches AppKit, a pasteboard or the disk — it takes the
/// file URLs plus the running build's flavour and returns a plan the thin
/// `MacConvertService` glue carries out. Keeping the policy here makes the no-overwrite
/// naming, the build-flavour split and the end-of-run tally unit-testable without a GUI.
///
/// Foundation only, so it compiles into the logic-test bundle on both platforms.
enum ConvertServicePlanner {
    /// Which app build is handling the Service. The unsandboxed GitHub/DMG build may
    /// write a converted file beside its original; the sandboxed App Store build can't
    /// gain that write access without the user picking the destination, so it routes
    /// through a save panel (one file) or a folder choice (several).
    enum Flavour: Sendable, Equatable {
        /// The GitHub/DMG build (`EMFY_DMG`): no sandbox, writes beside the original.
        case unsandboxed
        /// The App Store build: sandboxed, needs an NSSavePanel / NSOpenPanel grant.
        case sandboxed
    }

    /// One input paired with the non-colliding output URL it will be written to.
    struct Output: Equatable, Sendable {
        let input: URL
        let output: URL
    }

    /// What the glue should do once it has read the pasteboard. Pure data — the glue
    /// converts, writes and presents; it never re-decides the route.
    enum Plan: Equatable, Sendable {
        /// Write each output beside its original (unsandboxed). Names are already
        /// de-duplicated, paired 1:1 with the convertible inputs.
        case writeBesideOriginals([Output])
        /// Sandboxed, exactly one file: present a save panel pre-set to this directory
        /// and file name, then write the one conversion where the user confirms.
        case savePanel(input: URL, directory: URL, fileName: String)
        /// Sandboxed, several files: ask for a destination folder (pre-set here), then
        /// convert every input into it with no-overwrite naming.
        case chooseFolder(inputs: [URL], directory: URL)
        /// Nothing on the pasteboard was a metafile Emfy converts.
        case nothing
    }

    /// The fate of one file in the run, for the summary tally.
    enum FileResult: Equatable, Sendable {
        case converted
        case skipped
    }

    /// The filename extensions the four UTTypes Emfy declares carry — `com.microsoft.emf`
    /// / `.wmf` / `.emz` / `.wmz`, the same set `NSSendFileTypes` advertises to Finder.
    /// Finder already scopes the Service to those types; this is the defensive in-app
    /// check on whatever file URLs actually arrive on the pasteboard.
    static let metafileExtensions: Set<String> = ["emf", "wmf", "emz", "wmz"]

    /// Keeps only the pasteboard URLs that name a metafile Emfy converts, in order.
    static func metafileURLs(from urls: [URL]) -> [URL] {
        urls.filter { metafileExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Builds the plan for the given pasteboard URLs, output format and build flavour.
    /// `fileExists` drives the no-overwrite naming for the beside-originals case and is
    /// injected so the planner stays pure.
    static func plan(
        inputs rawInputs: [URL],
        format: BatchOutputFormat,
        flavour: Flavour,
        fileExists: (URL) -> Bool
    ) -> Plan {
        let inputs = metafileURLs(from: rawInputs)
        guard !inputs.isEmpty else { return .nothing }
        switch flavour {
        case .unsandboxed:
            let planned = outputs(
                for: inputs, format: format,
                directory: { $0.deletingLastPathComponent() },
                fileExists: fileExists)
            return .writeBesideOriginals(planned)
        case .sandboxed:
            if inputs.count == 1 {
                let input = inputs[0]
                return .savePanel(
                    input: input,
                    directory: input.deletingLastPathComponent(),
                    fileName: "\(stem(of: input)).\(format.pathExtension)")
            }
            return .chooseFolder(inputs: inputs, directory: inputs[0].deletingLastPathComponent())
        }
    }

    /// Assigns each input a non-colliding "<stem>.<ext>" output URL under `directory(input)`,
    /// mirroring the F1 batch namer: the first free name is the plain stem, then "<stem> 2",
    /// "<stem> 3", … A name is taken when it is already on disk (`fileExists`) or already
    /// claimed earlier in this run. Used for the beside-originals plan (each original's own
    /// folder) and, after the folder choice, for the chosen folder.
    static func outputs(
        for inputs: [URL],
        format: BatchOutputFormat,
        directory: (URL) -> URL,
        fileExists: (URL) -> Bool
    ) -> [Output] {
        var claimed: Set<String> = []
        var result: [Output] = []
        for input in inputs {
            let dir = directory(input)
            let base = stem(of: input)
            var index = 1
            while true {
                let name = index == 1 ? base : "\(base) \(index)"
                let url = dir.appendingPathComponent("\(name).\(format.pathExtension)")
                let key = url.path.lowercased()
                if !claimed.contains(key), !fileExists(url) {
                    claimed.insert(key)
                    result.append(Output(input: input, output: url))
                    break
                }
                index += 1
            }
        }
        return result
    }

    /// Classifies one file's outcome for the tally: a conversion that also wrote is
    /// `.converted`; a hostile/unreadable input, or a write that failed, is `.skipped`
    /// (§8 log-and-skip — never a crash, never a whole-run failure).
    static func classify(_ outcome: BatchProduceOutcome, wroteSuccessfully: Bool) -> FileResult {
        switch outcome {
        case .converted: return wroteSuccessfully ? .converted : .skipped
        case .unparseable, .failed: return .skipped
        }
    }

    /// The one end-of-run summary ("Converted 3, skipped 1."), or `nil` when nothing was
    /// skipped — in which case the glue shows no alert.
    static func summaryMessage(converted: Int, skipped: Int) -> String? {
        guard skipped > 0 else { return nil }
        return "Converted \(converted), skipped \(skipped)."
    }

    /// The output filename stem — the original name with its extension removed.
    private static func stem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
