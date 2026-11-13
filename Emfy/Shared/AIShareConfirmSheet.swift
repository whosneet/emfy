import SwiftUI

// MARK: - "Send to AI…" confirm sheet (A3b)
//
// The small pre-sheet both platforms show before handing the package to the system
// share sheet: a one-line explanation that Emfy itself sends nothing, and the
// "Include the original file" toggle (default off). On Mac it precedes the
// NSSharingServicePicker; on iOS it precedes the UIActivityViewController.

struct AIShareConfirmSheet: View {
    @Binding var includeOriginal: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(AISharePackage.sheetTitle, systemImage: "sparkles")
                .font(.headline)
            Text(AISharePackage.sheetFootnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(AISharePackage.includeOriginalLabel, isOn: $includeOriginal)
                .accessibilityIdentifier("sendToAIIncludeOriginal")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Share…") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sendToAIConfirm")
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 360)
        #endif
    }
}
