#if os(iOS)
import SwiftUI
import UIKit

/// The iOS find bar (F3b): a search field, "n of m", ‹ › navigation and Done, shown by
/// `MetafileViewerScreen` when the Find button (or ⌘F) fires. Typing updates the matches
/// live, debounced ~150 ms. Mirrors the Mac find bar; the matching, navigation and
/// highlight geometry live in the shared `DrawingFindModel` / `FindHighlightGeometry`.
struct IOSFindBar: View {
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
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { model.goNext() }
                .frame(minWidth: 120)

            statusLabel
            readingHint

            HStack(spacing: 4) {
                Button { model.goPrevious() } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Find Previous")
                Button { model.goNext() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Find Next")
            }
            .disabled(model.matches.isEmpty)

            Button("Done") { onClose() }
                .fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    /// A small progress hint shown while the picture-OCR pass is still running (F3c).
    @ViewBuilder
    private var readingHint: some View {
        if model.isReadingPictures {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Reading pictures…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleApply() {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            model.applyQuery()
        }
    }
}

// MARK: - Screen integration

/// Hangs the find bar, its live-runs task and the scroll-to-match reaction off the viewer
/// in ONE modifier, so `MetafileViewerScreen.body` stays type-checkable (its body is already
/// at the solver's limit). The screen owns the runs/scroll logic; this only sequences it.
private struct MetafileFindBarModifier: ViewModifier {
    @Bindable var model: DrawingFindModel
    let runsKey: String
    let refreshRuns: () async -> Void
    let onCurrentChange: () -> Void
    /// The live "Recognise text in pictures" setting (F3c), observed here so the giant screen
    /// body gains no modifier.
    let ocrEnabled: Bool
    let onOCRToggle: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if model.isPresented {
                    IOSFindBar(model: model) { withAnimation(.easeOut(duration: 0.2)) { model.dismiss() } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task(id: runsKey) { await refreshRuns() }
            .onChange(of: model.current) { _, _ in onCurrentChange() }
            .onChange(of: ocrEnabled) { _, enabled in onOCRToggle(enabled) }
    }
}

extension View {
    /// Attaches the F3b find bar, its live-runs task, the scroll-to-match reaction, and the
    /// F3c OCR-toggle reaction.
    func metafileFindBar(
        model: DrawingFindModel,
        runsKey: String,
        refreshRuns: @escaping () async -> Void,
        onCurrentChange: @escaping () -> Void,
        ocrEnabled: Bool,
        onOCRToggle: @escaping (Bool) -> Void
    ) -> some View {
        modifier(MetafileFindBarModifier(
            model: model, runsKey: runsKey, refreshRuns: refreshRuns, onCurrentChange: onCurrentChange,
            ocrEnabled: ocrEnabled, onOCRToggle: onOCRToggle))
    }
}

// MARK: - Highlight drawing

/// Draws the find highlights in a context already in VIEW space (the tiled view / editor
/// overlay's own y-down space). Shared by the viewer overlay and the editor overlay so both
/// highlight identically: a translucent systemYellow fill on every match, the current match
/// a stronger fill and an outline. `onScreenScale` is the zoom, so the outline stays ~1.5 pt.
enum IOSFindHighlightPainter {
    static func paint(all: [CGRect], current: CGRect?, into context: CGContext, onScreenScale: CGFloat) {
        let scale = onScreenScale > 0 ? onScreenScale : 1
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
        for rect in all {
            context.fill(rect.insetBy(dx: -1 / scale, dy: -1 / scale))
        }
        guard let current else { return }
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.55).cgColor)
        context.fill(current.insetBy(dx: -1 / scale, dy: -1 / scale))
        context.setStrokeColor(UIColor.systemOrange.cgColor)
        context.setLineWidth(1.5 / scale)
        context.stroke(current.insetBy(dx: -1 / scale, dy: -1 / scale))
    }
}

/// A transparent overlay above the tiled view (its subview) that draws the find highlights
/// in the read-only iOS viewer. It rides the scroll view's zoom with the tiles and maps the
/// matches' device rects to the tiled view's y-down space (no y-flip — the EMF device space
/// is y-down, exactly like the overlay), matching where the tiled view draws the ink.
final class IOSFindHighlightView: UIView {
    weak var controller: MetafileZoomController?
    private var highlights = FindHighlightSet.empty

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false   // taps reach the drawing/scroll view beneath
        contentMode = .redraw
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHighlights(_ set: FindHighlightSet) {
        guard set != highlights else { return }
        highlights = set
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !highlights.isEmpty, let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0, bounds.height > 0 else { return }
        let mapping = EditorCanvasMapping(pageBoundsDevice: highlights.pageBoundsDevice, target: bounds, flipY: false)
        let all = highlights.matchDeviceRects.map { mapping.viewRect(fromDevice: $0) }
        let current = highlights.currentDeviceRect.map { mapping.viewRect(fromDevice: $0) }
        IOSFindHighlightPainter.paint(all: all, current: current, into: context, onScreenScale: controller?.zoom ?? 1)
    }
}
#endif
