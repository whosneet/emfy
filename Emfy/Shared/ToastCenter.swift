import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one shared toast surface (C4a H6/A2, M3, H3): a brief capsule at the bottom
/// of the window for "Image copied", "Saved to Photos", "Exported", and the single-
/// removal Undo. One per library window, injected through the environment so the
/// sidebar, the viewer and the inspector all post to the same surface.
///
/// The capsule uses a material background now; C4b swaps in the shared glass helper
/// (G1). Reduce Motion is honoured — no slide, a plain cross-fade — and an optional
/// action button (Undo, Show in Finder) is shown trailing. Posting a new toast
/// replaces any current one; the accessibility announcement is left to the caller,
/// which already posts it (and queues rather than interrupts).
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var systemImage: String?
        var actionTitle: String?
        var duration: Double

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Toast?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Mirrors the environment's Reduce Motion so transitions honour it.
    var reduceMotion = false

    /// Shows a toast, replacing any current one. `action`/`actionTitle` add a trailing
    /// button (e.g. Undo, Show in Finder).
    func show(
        _ message: String,
        systemImage: String? = nil,
        duration: Double = 2,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        dismissTask?.cancel()
        self.action = action
        let toast = Toast(message: message, systemImage: systemImage, actionTitle: actionTitle, duration: duration)
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            current = toast
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// Runs the toast's action and dismisses it.
    func performAction() {
        let action = self.action
        dismiss()
        action?()
    }

    /// Dismisses the current toast (any id).
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        action = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            current = nil
        }
    }

    /// Dismisses only if `id` is still the current toast, so a stale auto-dismiss
    /// timer can't close a newer toast.
    private func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }
}

/// The capsule itself. Material background now; C4b adds the glass (G1).
struct ToastView: View {
    let toast: ToastCenter.Toast
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = toast.actionTitle {
                Divider()
                    .frame(height: 20)
                Button(actionTitle, action: onAction)
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        // The one place a toast announces itself to VoiceOver — queued, not
        // interrupting (H6/A2, A17). The callers no longer post their own.
        .onAppear { announce(toast.message) }
    }

    private func announce(_ message: String) {
        #if os(macOS)
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        #else
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

extension View {
    /// Hosts a `ToastCenter`'s current toast as a bottom overlay. Applied once per
    /// window, over the whole library window so it covers both columns.
    @ViewBuilder
    func toastOverlay(_ center: ToastCenter) -> some View {
        self.overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastView(toast: toast) { center.performAction() }
                    .padding(.bottom, 24)
                    .padding(.horizontal, 16)
                    .transition(center.reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(toast.actionTitle != nil)
            }
        }
    }
}
