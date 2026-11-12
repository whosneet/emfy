import Foundation
import Testing

// The Finder "Convert … with Emfy" Service planner (F4c). These exercise the pure
// policy — build-flavour routing, no-overwrite naming, skip classification, the summary
// and the pasteboard URL filter — with no AppKit and no disk. ConvertServicePlanner is
// compiled into this logic-test bundle, so it's in-module (no `import Emfy`). macOS and
// iOS simulator both build it.

@Suite(.serialized)
struct ConvertServiceTests {
    private let dirA = URL(fileURLWithPath: "/Users/x/Drawings", isDirectory: true)
    private let dirB = URL(fileURLWithPath: "/Users/x/Other", isDirectory: true)

    private func url(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent(name) }

    // MARK: - DMG beside-originals plan, with no-overwrite

    @Test func dmgPlanWritesBesideEachOriginal() {
        let inputs = [url(dirA, "a.emf"), url(dirB, "b.wmf")]
        let plan = ConvertServicePlanner.plan(
            inputs: inputs, format: .png, flavour: .unsandboxed, fileExists: { _ in false })
        #expect(plan == .writeBesideOriginals([
            .init(input: url(dirA, "a.emf"), output: url(dirA, "a.png")),
            .init(input: url(dirB, "b.wmf"), output: url(dirB, "b.png")),
        ]))
    }

    @Test func dmgPlanAvoidsOverwritingAnExistingOutput() {
        let input = url(dirA, "a.emf")
        let taken = url(dirA, "a.pdf").path.lowercased()
        let plan = ConvertServicePlanner.plan(
            inputs: [input], format: .pdf, flavour: .unsandboxed,
            fileExists: { $0.path.lowercased() == taken })
        #expect(plan == .writeBesideOriginals([
            .init(input: input, output: url(dirA, "a 2.pdf")),
        ]))
    }

    @Test func dmgPlanDeDuplicatesTwoInputsSharingAStemInOneFolder() {
        // "a.emf" and "a.wmf" both want "a.svg" beside them → the second becomes "a 2.svg".
        let inputs = [url(dirA, "a.emf"), url(dirA, "a.wmf")]
        let plan = ConvertServicePlanner.plan(
            inputs: inputs, format: .svg, flavour: .unsandboxed, fileExists: { _ in false })
        #expect(plan == .writeBesideOriginals([
            .init(input: url(dirA, "a.emf"), output: url(dirA, "a.svg")),
            .init(input: url(dirA, "a.wmf"), output: url(dirA, "a 2.svg")),
        ]))
    }

    // MARK: - App Store (sandboxed) routing

    @Test func sandboxedSingleFileAsksForASavePanelPreSet() {
        let input = url(dirA, "poster.emf")
        let plan = ConvertServicePlanner.plan(
            inputs: [input], format: .png, flavour: .sandboxed, fileExists: { _ in false })
        #expect(plan == .savePanel(input: input, directory: dirA, fileName: "poster.png"))
    }

    @Test func sandboxedSeveralFilesAskForADestinationFolder() {
        let inputs = [url(dirA, "one.emf"), url(dirB, "two.wmf")]
        let plan = ConvertServicePlanner.plan(
            inputs: inputs, format: .pdf, flavour: .sandboxed, fileExists: { _ in false })
        // Pre-set to the first original's folder.
        #expect(plan == .chooseFolder(inputs: inputs, directory: dirA))
    }

    // MARK: - Folder naming after the choice

    @Test func outputsIntoAChosenFolderDeDuplicate() {
        let inputs = [url(dirA, "a.emf"), url(dirB, "a.wmf")]  // same stem, different folders
        let folder = URL(fileURLWithPath: "/Users/x/Out", isDirectory: true)
        let outputs = ConvertServicePlanner.outputs(
            for: inputs, format: .png, directory: { _ in folder }, fileExists: { _ in false })
        #expect(outputs == [
            .init(input: url(dirA, "a.emf"), output: url(folder, "a.png")),
            .init(input: url(dirB, "a.wmf"), output: url(folder, "a 2.png")),
        ])
    }

    // MARK: - Skip / report classification

    @Test func classificationMapsOutcomesToConvertedOrSkipped() {
        #expect(ConvertServicePlanner.classify(.converted(Data([1])), wroteSuccessfully: true) == .converted)
        #expect(ConvertServicePlanner.classify(.converted(Data([1])), wroteSuccessfully: false) == .skipped)
        #expect(ConvertServicePlanner.classify(.unparseable(reason: "x"), wroteSuccessfully: false) == .skipped)
        #expect(ConvertServicePlanner.classify(.failed(reason: "x"), wroteSuccessfully: false) == .skipped)
    }

    @Test func summaryIsSilentWhenEverythingConverted() {
        #expect(ConvertServicePlanner.summaryMessage(converted: 4, skipped: 0) == nil)
    }

    @Test func summaryReportsSkips() {
        #expect(ConvertServicePlanner.summaryMessage(converted: 3, skipped: 1) == "Converted 3, skipped 1.")
    }

    // MARK: - Pasteboard URL filtering

    @Test func metafileFilterKeepsOnlyTheFourSupportedTypes() {
        let urls = [
            url(dirA, "a.emf"), url(dirA, "b.EMZ"), url(dirA, "c.wmf"), url(dirA, "d.WMZ"),
            url(dirA, "e.png"), url(dirA, "f.txt"), url(dirA, "g"),
        ]
        let kept = ConvertServicePlanner.metafileURLs(from: urls)
        #expect(kept == [url(dirA, "a.emf"), url(dirA, "b.EMZ"), url(dirA, "c.wmf"), url(dirA, "d.WMZ")])
    }

    @Test func planWithNoMetafilesIsNothing() {
        let plan = ConvertServicePlanner.plan(
            inputs: [url(dirA, "x.png"), url(dirA, "y.txt")],
            format: .png, flavour: .unsandboxed, fileExists: { _ in false })
        #expect(plan == .nothing)
    }
}
