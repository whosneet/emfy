#if os(macOS)
import AppKit
import SwiftUI

/// The Mac find bar (F3b): a search field, the "n of m" status, ‹ › navigation and Done,
/// slid in above the canvas by `MacViewerPane` when Edit ▸ Find ▸ Find… (⌘F) fires. Typing
/// updates the matches live, debounced ~150 ms; Esc (the Done button's shortcut) closes it.
/// The matching, navigation and highlight geometry live in the pure `DrawingFindModel` /
/// `FindHighlightGeometry`; this view is only the chrome.
struct MacFindBar: View {
    @Bindable var model: DrawingFindModel
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $model.query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .frame(minWidth: 180)
                .onSubmit { model.goNext() }

            statusLabel
            readingHint

            HStack(spacing: 2) {
                Button { model.goPrevious() } label: { Image(systemName: "chevron.up") }
                    .help("Find Previous")
                Button { model.goNext() } label: { Image(systemName: "chevron.down") }
                    .help("Find Next")
            }
            .buttonStyle(.borderless)
            .disabled(model.matches.isEmpty)

            Divider().frame(height: 16)

            Button("Done") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 6, y: 3)
        .padding(.top, 10)
        .onChange(of: model.query) { _, _ in scheduleApply() }
        .onAppear {
            fieldFocused = true
            model.applyQuery()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !model.statusText.isEmpty {
            HStack(spacing: 4) {
                Text(model.statusText)
                    .monospacedDigit()
                if model.isCurrentMatchInPicture {
                    Text("in picture")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        } else if !model.query.isEmpty, !model.isReadingPictures {
            Text("Not found")
                .foregroundStyle(.secondary)
        }
    }

    /// A small progress hint shown while the picture-OCR pass is still running (F3c), so a
    /// user searching a scanned drawing knows more matches may still appear.
    @ViewBuilder
    private var readingHint: some View {
        if model.isReadingPictures {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Reading text in pictures…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Debounces the live search ~150 ms so a burst of keystrokes recomputes once.
    private func scheduleApply() {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            model.applyQuery()
        }
    }
}

// MARK: - Highlight drawing

/// Draws the find highlights in a context already in VIEW space (the paper/overlay space
/// the scene is fitted into). Shared by the viewer's paper overlay and the editor overlay
/// so both highlight identically: a translucent systemYellow fill on every match, with the
/// current match a stronger fill and an outline. `onScreenScale` is the magnification, so
/// the current-match outline stays a constant ~1.5 pt on screen at any zoom.
enum FindHighlightPainter {
    static func paint(all: [CGRect], current: CGRect?, into context: CGContext, onScreenScale: CGFloat) {
        let scale = onScreenScale > 0 ? onScreenScale : 1
        context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.35).cgColor)
        for rect in all {
            context.fill(rect.insetBy(dx: -1 / scale, dy: -1 / scale))
        }
        guard let current else { return }
        context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.55).cgColor)
        context.fill(current.insetBy(dx: -1 / scale, dy: -1 / scale))
        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(1.5 / scale)
        context.stroke(current.insetBy(dx: -1 / scale, dy: -1 / scale))
    }
}

/// A transparent overlay above the tiled view (inside the paper document view) that draws
/// the find highlights in the read-only viewer. It sits in the paper's own y-up space, so
/// it rides the scroll view's magnification and scroll exactly like the tiles; it builds
/// the device→paper mapping from the drawing's device bounds, matching the renderer's fit.
final class FindHighlightOverlayView: NSView {
    weak var controller: MacMetafileZoomController?
    private var highlights = FindHighlightSet.empty

    override var isFlipped: Bool { false }   // match the paper + tiled view (y-up)
    override var isOpaque: Bool { false }

    /// Transparent to the pointer, so clicks reach the drawing/scroll view beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setHighlights(_ set: FindHighlightSet) {
        guard set != highlights else { return }
        highlights = set
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !highlights.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              bounds.width > 0, bounds.height > 0 else { return }
        let mapping = EditorCanvasMapping(pageBoundsDevice: highlights.pageBoundsDevice, target: bounds, flipY: true)
        let all = highlights.matchDeviceRects.map { mapping.viewRect(fromDevice: $0) }
        let current = highlights.currentDeviceRect.map { mapping.viewRect(fromDevice: $0) }
        FindHighlightPainter.paint(all: all, current: current, into: context, onScreenScale: controller?.zoom ?? 1)
    }
}
#endif
