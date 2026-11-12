import AppKit
import SwiftUI

/// File ▸ Batch Convert… (F1 design call 4). Add files or folders, pick the output
/// format (PNG / PDF / SVG) and the destination, and run the conversion with bounded
/// concurrency, a progress overlay and Cancel. PNG scale and background come from the
/// Export settings. At the end a per-file report shows converted / skipped / failed.
struct MacBatchConvertSheet: View {
    @Environment(EmfySettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var controller = BatchConvertController()

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Convert")
                .font(.title2.bold())

            sourcesSection

            Picker("Output format", selection: $controller.format) {
                ForEach(BatchOutputFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            destinationSection

            if controller.format == .png {
                Text("PNG uses your Export settings: \(settings.defaultPNGScale.multiplier)× scale, \(settings.pngBackground == .transparent ? "transparent" : "white") background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Convert \(controller.total) \(controller.total == 1 ? "File" : "Files")") {
                    controller.run(settings: settings)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canRun)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
        .overlay {
            if controller.isRunning { runningOverlay }
        }
        .sheet(isPresented: Binding(
            get: { controller.report != nil },
            set: { if !$0 { controller.dismissReport() } })
        ) {
            if let report = controller.report {
                MacBatchReportSheet(report: report) {
                    controller.dismissReport()
                    dismiss()
                }
            }
        }
        #if DEBUG
        // F1 screenshots (b)/(c): pre-fill from temp-copied files, capture the sheet (or,
        // with batchReport, run it and capture the report), then quit. Window capture
        // (cacheDisplay) renders the real segmented Picker and the report List, unlike
        // ImageRenderer.
        .task {
            guard EditorDebugLaunch.batchSheet, let base = EditorDebugLaunch.screenshotBase else { return }
            controller.add(EditorDebugLaunch.safeCopiedBatchFiles())
            controller.destinationFolder = EditorDebugLaunch.batchOutputDirectory()
            try? await Task.sleep(for: .milliseconds(900))
            if EditorDebugLaunch.batchReport {
                controller.run(settings: settings)
                for _ in 0..<100 where controller.report == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(900))
                _ = EditorDebugScreenshot.captureNestedAttachedSheetView(to: base + "-c-batch-report.png")
            } else {
                _ = EditorDebugScreenshot.captureAttachedSheetView(to: base + "-b-batch-sheet.png")
            }
            try? await Task.sleep(for: .milliseconds(200))
            exit(0)
        }
        #endif
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                Button("Add Files…") { addFiles() }
                Button("Add Folder…") { addFolder() }
                if !controller.sources.isEmpty {
                    Button("Clear") { controller.clearSources() }
                }
            }
            Toggle("Include sub-folders when adding a folder", isOn: $controller.recurseFolders)
                .font(.caption)

            if controller.sources.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "doc.badge.plus",
                                       description: Text("Add EMF, WMF, EMZ or WMZ files, or a folder of them."))
                    .frame(height: 140)
            } else {
                List {
                    ForEach(controller.sources) { source in
                        HStack {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            Text(source.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                controller.removeSource(source.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(source.displayName)")
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }

    // MARK: - Destination

    @ViewBuilder
    private var destinationSection: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination")
                .font(.headline)
            Picker("Destination", selection: $controller.destinationMode) {
                Text("Choose a folder").tag(BatchConvertController.DestinationMode.chosenFolder)
                Text("Put files next to originals").tag(BatchConvertController.DestinationMode.nextToOriginals)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if controller.destinationMode == .chosenFolder {
                HStack {
                    Button("Choose Folder…") { chooseDestination() }
                    Text(controller.destinationFolder?.path ?? "No folder chosen")
                        .font(.caption)
                        .foregroundStyle(controller.destinationFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Running overlay

    private var runningOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.85)
            VStack(spacing: 16) {
                ProgressView(value: Double(controller.completed), total: Double(max(1, controller.total)))
                    .frame(width: 240)
                Text("Converting \(controller.completed) of \(controller.total)…")
                    .font(.callout)
                Button("Cancel") { controller.cancel() }
            }
            .padding(28)
        }
    }

    // MARK: - Panels

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MetafileTypes.readableContentTypes
        panel.prompt = "Add"
        if panel.runModal() == .OK { controller.add(panel.urls) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more folders of metafiles to convert."
        if panel.runModal() == .OK { controller.add(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for the converted files."
        if panel.runModal() == .OK { controller.destinationFolder = panel.url }
    }
}

/// The per-file batch report (F1): a converted / skipped / failed summary and a list,
/// each skip or failure carrying its reason. Hostile files appear as skips, never a
/// crash.
struct MacBatchReportSheet: View {
    let report: BatchReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Convert Report")
                .font(.title2.bold())

            HStack(spacing: 20) {
                summaryItem(count: report.converted, label: "Converted", systemImage: "checkmark.circle.fill", tint: .green)
                summaryItem(count: report.skipped, label: "Skipped", systemImage: "minus.circle.fill", tint: .orange)
                summaryItem(count: report.failed, label: "Failed", systemImage: "xmark.circle.fill", tint: .red)
                if report.cancelled > 0 {
                    summaryItem(count: report.cancelled, label: "Cancelled", systemImage: "stop.circle.fill", tint: .secondary)
                }
            }

            List {
                ForEach(report.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(for: entry.outcome)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = detail(for: entry.outcome) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }

    private func summaryItem(count: Int, label: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Label("\(count)", systemImage: systemImage)
                .foregroundStyle(tint)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func icon(for outcome: BatchReport.Outcome) -> some View {
        switch outcome {
        case .converted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func detail(for outcome: BatchReport.Outcome) -> String? {
        switch outcome {
        case .converted(let url): return url.lastPathComponent
        case .skipped(let reason): return "Skipped — \(reason)"
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}
