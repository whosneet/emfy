import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one shared "preparing export" overlay (C4a A1/L2): a dimmed, tap-blocking
/// cover with a spinner, a label, and a Cancel button, shown while a PNG/PDF render
/// runs past ~0.3 s. It replaces the two near-identical copies (`ExportSpinnerOverlay`,
/// `RenderingOverlay`).
///
/// VoiceOver treats it as one modal element ("Preparing export") so focus stays on
/// it, and it announces itself on appear. `.updatesFrequently` is dropped — the
/// progress isn't readable, so it shouldn't nag. The card uses a material background
/// now; C4b adds the glass (G1), except the iPhone-inspector instance stays material.
struct ExportProgressOverlay: View {
    /// Cancels the in-flight render.
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing export")
        .accessibilityAddTraits(.isModal)
        .onAppear { announcePreparing() }
    }

    private func announcePreparing() {
        #if os(macOS)
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Preparing export", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        #else
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: "Preparing export")
        #endif
    }
}
