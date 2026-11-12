import SwiftUI

/// The New Drawing presets sheet (E3a design call 4), shared by the Mac File ▸ New
/// Drawing… command and the iPad library "+". It offers the four page presets with
/// a proportioned preview, defaulting to A4 landscape; Create writes the blank EMF
/// and opens it straight into the editor.
struct NewDrawingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: NewDrawingPreset = .default
    /// Called with the chosen preset when Create is tapped.
    let onCreate: (NewDrawingPreset) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Page size") {
                    ForEach(NewDrawingPreset.allCases) { preset in
                        Button {
                            selection = preset
                        } label: {
                            row(preset)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newDrawingPreset.\(preset.rawValue)")
                    }
                }
            }
            // Grouped style gives the standard inset sheet spacing on macOS (the row
            // content and the section header are no longer flush to the edge) and the
            // familiar inset-grouped list on iPad.
            .formStyle(.grouped)
            .navigationTitle("New Drawing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(selection)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 340, idealHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func row(_ preset: NewDrawingPreset) -> some View {
        HStack(spacing: 14) {
            PageProportionPreview(size: preset.pageSizeMillimetres)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title)
                    .foregroundStyle(.primary)
                Text(Self.dimensionText(preset.pageSizeMillimetres))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selection == preset {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private static func dimensionText(_ mm: CGSize) -> String {
        "\(trimmed(mm.width)) × \(trimmed(mm.height)) mm"
    }

    private static func trimmed(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3g", Double(value))
    }
}

/// A small page proportion thumbnail: a white "paper" rectangle in the preset's
/// aspect ratio, centred in its frame.
private struct PageProportionPreview: View {
    let size: CGSize

    var body: some View {
        GeometryReader { geo in
            let aspect = size.width / max(size.height, 1)
            let box = fittedSize(in: geo.size, aspect: aspect)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 1))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
                .frame(width: box.width, height: box.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        }
    }

    private func fittedSize(in frame: CGSize, aspect: CGFloat) -> CGSize {
        if aspect >= 1 {
            let w = frame.width
            return CGSize(width: w, height: w / aspect)
        }
        let h = frame.height
        return CGSize(width: h * aspect, height: h)
    }
}

/// Wraps the "present the New Drawing sheet" action so it can be a focused value
/// without the closure-comparability warning `@Entry` emits for a bare closure
/// (the same reason `ViewerActions` is a struct, not a closure).
struct NewDrawingCommand {
    var present: () -> Void
}

extension FocusedValues {
    /// The focused library window's New Drawing action, published by every window (so
    /// File ▸ New Drawing works even in an empty window) and read by the Mac File menu.
    /// `nil` only when no window is focused.
    @Entry var newDrawingAction: NewDrawingCommand?
}
