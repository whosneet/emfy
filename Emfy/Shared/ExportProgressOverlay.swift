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
/// progress isn't readable, so it shouldn't nag. The card is the shared floating
/// surface — Liquid Glass on 26, a material below (G1) — except the instance shown
/// inside the iPhone inspector sheet (`prefersGlass: false`), which stays material
/// to avoid glass over the sheet's own glass.
struct ExportProgressOverlay: View {
    /// Glass on 26 for the full-screen overlays; material for the one inside the
    /// iPhone inspector sheet (G1). Declared before `onCancel` so the trailing-closure
    /// call sites keep compiling.
    var prefersGlass: Bool = true
    /// Cancels the in-flight render.
    let onCancel: () -> Void

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
            card
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing export")
        .accessibilityAddTraits(.isModal)
        .onAppear { announcePreparing() }
    }

    @ViewBuilder
    private var card: some View {
        let content = VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(24)

        if prefersGlass {
            content.floatingSurface(in: cardShape)
        } else {
            content
                .background(.regularMaterial, in: cardShape)
                .overlay(cardShape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
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

/// Posts a VoiceOver announcement on both platforms (C5e A6). AI results and failures are
/// otherwise silent to VoiceOver, which only tracks focus changes.
enum VoiceOverAnnouncement {
    static func post(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

extension View {
    /// The one floating-surface background shared by the zoom pill, the
    /// partial-support banner, the toast, and the export card (C4b G1): Liquid Glass
    /// on iOS/macOS 26+, a `.regularMaterial` plus a 0.5 pt hairline below. Deployed
    /// at iOS 17 / macOS 14, so every call site reads the same on every OS.
    @ViewBuilder
    func floatingSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// A drop shadow applied ONLY below iOS/macOS 26 (audit G-B). On 26 the shared
    /// `floatingSurface` uses Liquid Glass, which casts its own shadow, so an explicit
    /// shadow on top of it doubles up; below 26 the material surface still needs one.
    @ViewBuilder
    func floatingShadow(radius: CGFloat, y: CGFloat, color: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
        } else if let color {
            self.shadow(color: color, radius: radius, y: y)
        } else {
            self.shadow(radius: radius, y: y)
        }
    }

    /// Guarantees at least a 44×44 pt hit area on iOS (the HIG touch-target minimum) without
    /// changing the glyph size; on macOS it only sets the content shape, where a pointer
    /// handles the existing smaller controls (C5e A5).
    @ViewBuilder
    func minTouchTarget() -> some View {
        #if os(iOS)
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self.contentShape(Rectangle())
        #endif
    }

    /// A minimum frame that applies on macOS only (C5e L1/L2). The metafile sheets size a
    /// window there; on iOS the same minimum would force the content wider than an iPhone
    /// and clip, so it is dropped and the sheet tracks its presentation detent instead.
    @ViewBuilder
    func macSheetMinFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}
