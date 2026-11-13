import EMFEdit
import SwiftUI

// MARK: - The "Compare two versions" view (X1b item 1)
//
// Shown as a sheet from the Check segment. Three modes over the two rendered versions —
// side-by-side, overlay (onion-skin slider) and highlight differences (changed regions
// tinted) — plus a list of element changes. Selecting a change tints its region on the
// canvas. Cross-platform; the host presents it and feeds the model the two scenes.

struct DrawingCompareView: View {
    @Bindable var model: DrawingCompareModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.phase {
            case .idle, .comparing:
                comparing
            case .failed(let message):
                failed(message)
            case .ready:
                ready
            }
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare versions").font(.headline)
                Text("\(model.baselineLabel) → \(model.currentLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .ready {
                Picker("Mode", selection: $model.mode) {
                    ForEach(DrawingCompareModel.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button("Done", action: onClose).keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var comparing: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Comparing the two versions…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView("Couldn’t compare", systemImage: "exclamationmark.triangle", description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Ready

    private var ready: some View {
        HStack(spacing: 0) {
            canvasArea
                .frame(minWidth: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(canvasBackground)
            Divider()
            changeList
                .frame(width: 230)
        }
    }

    private var canvasBackground: Color {
        Color.gray.opacity(0.14)
    }

    @ViewBuilder
    private var canvasArea: some View {
        switch model.mode {
        case .sideBySide: sideBySide
        case .overlay: overlay
        case .highlight: highlight
        }
    }

    // MARK: Side by side

    private var sideBySide: some View {
        HStack(spacing: 10) {
            labelledImage(model.baselineImage, title: model.baselineLabel, highlightSelected: true)
            labelledImage(model.currentImage, title: model.currentLabel, highlightSelected: true)
        }
        .padding(12)
    }

    private func labelledImage(_ image: CGImage?, title: String, highlightSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            fittedImage(image) { displayRect in
                if highlightSelected, let bounds = model.selectedChangeBounds {
                    selectionOverlay(bounds: bounds, in: displayRect)
                }
            }
        }
    }

    // MARK: Overlay (onion-skin)

    private var overlay: some View {
        VStack(spacing: 8) {
            ZStack {
                fittedImage(model.baselineImage) { _ in EmptyView() }
                fittedImage(model.currentImage) { displayRect in
                    if let bounds = model.selectedChangeBounds {
                        selectionOverlay(bounds: bounds, in: displayRect)
                    }
                }
                .opacity(model.onionValue)
            }
            HStack(spacing: 8) {
                Text(model.baselineLabel).font(.caption2).foregroundStyle(.secondary)
                Slider(value: $model.onionValue, in: 0...1)
                Text(model.currentLabel).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .padding(12)
    }

    // MARK: Highlight differences

    private var highlight: some View {
        VStack(spacing: 6) {
            fittedImage(model.currentImage) { displayRect in
                // Changed-pixel regions tinted, with the selected element change on top.
                ForEach(Array(model.pixelRegions.enumerated()), id: \.offset) { _, region in
                    let r = model.displayRect(forPixel: region, in: displayRect)
                    Rectangle()
                        .fill(Color.orange.opacity(0.22))
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                if let bounds = model.selectedChangeBounds {
                    selectionOverlay(bounds: bounds, in: displayRect)
                }
            }
            if model.changedFraction > 0 {
                Text(String(format: "%.1f%% of pixels differ", model.changedFraction * 100))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: Fitted image with an overlay in its display rect

    private func fittedImage<Overlay: View>(_ image: CGImage?, @ViewBuilder overlay: @escaping (CGRect) -> Overlay) -> some View {
        GeometryReader { geo in
            if let image {
                let display = Self.fitRect(imageSize: CGSize(width: image.width, height: image.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                        .shadow(radius: 1)
                    overlay(display)
                }
            } else {
                Color.clear
            }
        }
    }

    private func selectionOverlay(bounds: CGRect, in displayRect: CGRect) -> some View {
        let r = model.displayRect(forDevice: bounds, in: displayRect)
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2))
            .frame(width: r.width + 8, height: r.height + 8)
            .position(x: r.midX, y: r.midY)
    }

    /// Aspect-fits an image of `imageSize` inside `container`, centred.
    private static func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    // MARK: Change list

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            if model.changes.isEmpty {
                ContentUnavailableView("No differences", systemImage: "equal.circle", description: Text("The two versions match."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedChangeID }, set: { model.select(changeID: $0) })) {
                    ForEach(model.changes) { change in
                        changeRow(change).tag(change.id)
                    }
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                #else
                .listStyle(.plain)
                #endif
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            countBadge(model.addedCount, "plus.circle.fill", .green, "added")
            countBadge(model.changedCount, "pencil.circle.fill", .orange, "changed")
            countBadge(model.removedCount, "minus.circle.fill", .red, "removed")
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func countBadge(_ count: Int, _ icon: String, _ colour: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(colour)
            Text("\(count)").font(.callout.monospacedDigit())
        }
        .accessibilityLabel("\(count) \(label)")
    }

    private func changeRow(_ change: DrawingComparison.ElementChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: change.kind))
                .foregroundStyle(colour(for: change.kind))
            Text(change.summary)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func icon(for kind: DrawingComparison.ChangeKind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .changed: return "pencil.circle.fill"
        }
    }

    private func colour(for kind: DrawingComparison.ChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }
}
