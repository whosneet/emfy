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
        // An actionable toast (Undo, Show in Finder) must not time out under VoiceOver or
        // Switch Control — those users can't reach a control that vanishes in 5 s (WCAG
        // 2.2.1, audit R2A5). It stays until dismissed, or until a newer toast replaces it.
        if actionTitle != nil, Self.assistiveTechnologyRunning {
            dismissTask = nil
            return
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// True while VoiceOver or Switch Control is running — the assistive technologies that
    /// need an actionable toast to persist (R2A5).
    static var assistiveTechnologyRunning: Bool {
        #if os(macOS)
        return NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        #else
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #endif
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
                    .minTouchTarget()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingSurface(in: Capsule())
        // Shadow only pre-26 — glass casts its own, so it would double up (audit G-B).
        .floatingShadow(radius: 8, y: 2, color: .black.opacity(0.12))
        .accessibilityElement(children: .combine)
        // The toast is one combined element, so its trailing button isn't separately
        // focusable; an accessibility action gives VoiceOver / Switch Control a route to it
        // (R2A5), paired with the toast no longer timing out for those users.
        .accessibilityActions {
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
            }
        }
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
                    // Clear the bottom chrome: on iPhone the window-level overlay sits
                    // at the home-indicator edge, but the Recents search field and the
                    // viewer's bottom toolbar live just above it, so lift the toast
                    // clear of a standard bottom bar there; the Mac has no bottom bar
                    // (T1).
                    .padding(.bottom, Self.toastBottomInset)
                    .padding(.horizontal, 16)
                    .transition(center.reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(toast.actionTitle != nil)
            }
        }
    }

    /// The toast's bottom inset above the safe area: enough to clear a bottom
    /// toolbar / search field on iOS, a small margin on macOS (T1).
    private static var toastBottomInset: CGFloat {
        #if os(iOS)
        64
        #else
        24
        #endif
    }
}
