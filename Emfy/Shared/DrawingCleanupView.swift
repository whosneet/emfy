import SwiftUI
import UniformTypeIdentifiers

// MARK: - The "Clean up & compatibility" sheet (X1b item 2)
//
// Shows the clean-up report (redundant records with counts and estimated bytes saved),
// the size before/after, and two save-a-copy actions: "Save Optimised Copy…" (redundant
// records removed) and "Save Compatible Copy…" (plain EMF, no EMF+, for Office/
// LibreOffice). Each is offered only when the copy is produced AND render-equivalent to
// the original; otherwise the reason is shown. A compatibility note lists what plain EMF
// cannot hold. Cross-platform.

struct DrawingCleanupView: View {
    @Bindable var model: DrawingCleanupModel
    /// A base file name for the saved copies.
    let fileName: String
    let onClose: () -> Void

    @State private var exportDocument = MetafileCopyDocument(data: Data())
    @State private var exportName = "Copy.emf"
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.phase {
            case .idle, .analysing:
                analysing
            case .failed(let message):
                ContentUnavailableView("Couldn’t analyse", systemImage: "exclamationmark.triangle", description: Text(message))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                content
            }
        }
        .frame(minWidth: 460, minHeight: 440)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .data, defaultFilename: exportName) { _ in }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up & compatibility").font(.headline)
                Text("Save a tidier or more compatible copy — the original is never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose).keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var analysing: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Analysing the drawing…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                reportSection
                Divider()
                optimisedSection
                Divider()
                compatibleSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Report

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Emfy found").font(.subheadline.weight(.semibold))
            if model.items.isEmpty {
                Label("No redundant records found — this file is already tidy.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.items) { item in
                    HStack {
                        Text(DrawingCleanupModel.label(for: item.kind))
                        Spacer()
                        Text("\(item.count) · \(DrawingCleanupModel.sizeString(item.bytes))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Optimised

    private var optimisedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optimised copy").font(.subheadline.weight(.semibold))
            sizeRow(before: model.originalByteCount, after: model.optimisedByteCount)
            if model.optimisedReady {
                Button {
                    offer(bytes: model.optimisedCopyBytes(), suffix: "optimised")
                } label: {
                    Label("Save Optimised Copy…", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("saveOptimisedCopy")
                equivalenceNote
            } else if let reason = model.optimisedBlockedReason {
                blocked(reason)
            } else {
                Text("Nothing to optimise — this file has no redundant records.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Compatible

    private var compatibleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compatible copy (plain EMF)").font(.subheadline.weight(.semibold))
            if model.hasEMFPlus {
                sizeRow(before: model.originalByteCount, after: model.compatibleByteCount)
                compatibilityNote
                if model.compatibleReady {
                    Button {
                        offer(bytes: model.compatibleCopyBytes(), suffix: "compatible")
                    } label: {
                        Label("Save Compatible Copy…", systemImage: "doc.badge.gearshape")
                    }
                    .accessibilityIdentifier("saveCompatibleCopy")
                    equivalenceNote
                } else if let reason = model.compatibleBlockedReason {
                    blocked(reason)
                    if !model.isDual {
                        Text("This file stores its drawing only as EMF+, with no GDI fallback, so a plain-EMF copy would be blank.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Label("This file is already plain EMF — no EMF+ to remove.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compatibilityNote: some View {
        Text("Plain EMF is read everywhere (Word, PowerPoint, LibreOffice). It can’t hold EMF+ extras such as transparency, gradients and anti-aliased effects; those are flattened to the GDI drawing.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pieces

    private func sizeRow(before: Int, after: Int) -> some View {
        let saved = max(0, before - after)
        return HStack(spacing: 8) {
            Text(DrawingCleanupModel.sizeString(before))
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(DrawingCleanupModel.sizeString(after)).fontWeight(.semibold)
            if saved > 0 {
                Text("saved \(DrawingCleanupModel.sizeString(saved))")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .font(.callout.monospacedDigit())
    }

    private var equivalenceNote: some View {
        Label("Checked: this copy looks identical to the original.", systemImage: "checkmark.circle")
            .font(.caption).foregroundStyle(.green)
    }

    private func blocked(_ reason: String) -> some View {
        Label(reason, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Export

    private func offer(bytes: Data?, suffix: String) {
        guard let bytes else { return }
        exportDocument = MetafileCopyDocument(data: bytes)
        exportName = Self.copyName(from: fileName, suffix: suffix)
        exporting = true
    }

    /// "Diagram.emf" + "optimised" → "Diagram-optimised.emf".
    static func copyName(from fileName: String, suffix: String) -> String {
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let safeBase = base.isEmpty ? "Drawing" : base
        let safeExt = ext.isEmpty ? "emf" : ext
        return "\(safeBase)-\(suffix).\(safeExt)"
    }
}
