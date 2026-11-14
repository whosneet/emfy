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
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            explanation
            actions
        }
        .padding(20)
        .frame(width: 360)
        #else
        // Scroll the explanation and pin the actions so Share stays reachable at large
        // accessibility text sizes and on the compact detent (C5e L3/A2).
        ScrollView {
            explanation
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
        #endif
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(AISharePackage.sheetTitle, systemImage: "sparkles")
                .font(.headline)
            Text(AISharePackage.sheetFootnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(AISharePackage.includeOriginalLabel, isOn: $includeOriginal)
                .accessibilityIdentifier("sendToAIIncludeOriginal")
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Share…") { onConfirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sendToAIConfirm")
        }
        // Single-line labels that shrink rather than wrap at the largest AX sizes (C5e A3 review).
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
