import SwiftUI
import UniformTypeIdentifiers

/// The iOS/iPadOS Batch Convert flow (F1 design call 4). Reached from the recents
/// Select mode's "Convert…" action with a multi-selection. It picks an output format
/// (PNG/PDF/SVG; PNG scale + background come from the Export settings), resolves each
/// selected recent's bytes into a temp input, runs the shared `BatchConvertController`
/// into a temp output folder, then shows a per-file report with a Share button that
/// hands the converted files to the system share sheet (Save to Files, Mail, …).
struct IOSBatchConvertSheet: View {
    let entries: [RecentEntry]
    let store: RecentsStore
    @Environment(EmfySettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var controller = BatchConvertController()
    @State private var phase: Phase = .configure
    @State private var sharePayload: BatchSharePayload?

    private enum Phase: Equatable { case configure, preparing, running, report }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Convert \(entries.count) \(entries.count == 1 ? "File" : "Files")")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { controller.cancel(); dismiss() }
                    }
                }
                .sheet(item: $sharePayload) { payload in
                    ShareSheet(items: payload.urls)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .configure: configureView
        case .preparing, .running: runningView
        case .report: reportView
        }
    }

    // MARK: - Configure

    private var configureView: some View {
        Form {
            Section("Output format") {
                Picker("Format", selection: Binding(
                    get: { controller.format }, set: { controller.format = $0 })
                ) {
                    ForEach(BatchOutputFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if controller.format == .png {
                Section {
                    LabeledContent("PNG scale", value: "\(settings.defaultPNGScale.multiplier)×")
                    LabeledContent("PNG background", value: settings.pngBackground == .transparent ? "Transparent" : "White")
                } footer: {
                    Text("PNG uses your Export settings.")
                }
            }
            Section {
                Button {
                    startRun()
                } label: {
                    Text("Convert \(entries.count) \(entries.count == 1 ? "File" : "Files")")
                        .frame(maxWidth: .infinity)
                }
                .disabled(entries.isEmpty)
            }
        }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(controller.completed), total: Double(max(1, controller.total)))
                .frame(maxWidth: 260)
            Text(phase == .preparing ? "Preparing…" : "Converting \(controller.completed) of \(controller.total)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Report

    @ViewBuilder
    private var reportView: some View {
        if let report = controller.report {
            VStack(spacing: 0) {
                List {
                    Section {
                        HStack(spacing: 24) {
                            summary(report.converted, "Converted", "checkmark.circle.fill", .green)
                            summary(report.skipped, "Skipped", "minus.circle.fill", .orange)
                            summary(report.failed, "Failed", "xmark.circle.fill", .red)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Section {
                        ForEach(report.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                icon(for: entry.outcome)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName).lineLimit(1).truncationMode(.middle)
                                    if let detail = detail(for: entry.outcome) {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
                let outputs = convertedURLs(report)
                if !outputs.isEmpty {
                    Button {
                        sharePayload = BatchSharePayload(urls: outputs)
                    } label: {
                        Label("Share \(outputs.count) \(outputs.count == 1 ? "File" : "Files")…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func summary(_ count: Int, _ label: String, _ image: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Label("\(count)", systemImage: image).foregroundStyle(tint).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
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

    private func convertedURLs(_ report: BatchReport) -> [URL] {
        report.entries.compactMap {
            if case .converted(let url) = $0.outcome { return url }
            return nil
        }
    }

    // MARK: - Run

    private func startRun() {
        phase = .preparing
        Task {
            // Resolve each selected recent's bytes into a temp input file, so the engine
            // (which reads from a file URL) has stable inputs.
            let inputDir = ExportTemp.makeDirectory()
            try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
            var inputs: [URL] = []
            for entry in entries {
                guard let data = try? await store.resolveData(for: entry) else { continue }
                let url = inputDir.appendingPathComponent(MetafileExport.sanitisedFileName(entry.displayName))
                if (try? data.write(to: url, options: .atomic)) != nil { inputs.append(url) }
            }
            controller.add(inputs)
            controller.destinationFolder = ExportTemp.makeDirectory()
            try? FileManager.default.createDirectory(at: controller.destinationFolder!, withIntermediateDirectories: true)
            phase = .running
            controller.run(settings: settings)
            // Await completion (the controller sets `report` when the run finishes).
            for _ in 0..<1200 where controller.report == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            phase = .report
        }
    }
}

/// The converted files for the system share sheet.
private struct BatchSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}
