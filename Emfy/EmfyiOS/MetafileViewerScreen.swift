import CoreGraphics
import SwiftUI

/// The I1 basic viewer: the rendered drawing on a white "paper" card over the
/// system background, aspect-fit, with the file name as the nav title and the
/// format + size as its subtitle. The paper stays white in dark mode because a
/// metafile assumes a white page.
///
/// Zoom, chrome-hiding, the inspector, the partial-support banner, and live
/// Share / Fit / Info are I2/I3 — here those three sit in the bottom bar as
/// disabled placeholders.
struct MetafileViewerScreen: View {
    @Environment(RecentsStore.self) private var store
    let entryID: UUID

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(SendableImage, CGSize)
        case unrenderable
        case failed
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            pageContent
        }
        .navigationTitle(entry?.baseName ?? "Metafile")
        .navigationBarTitleDisplayMode(.inline)
        .metafileNavigationSubtitle(subtitle)
        .toolbar { bottomPlaceholders }
        .task(id: entryID) { await load() }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .loaded(let rendered, let size):
            paper(rendered.cgImage, naturalSize: size)
        case .unrenderable:
            message("This drawing couldn’t be rendered.")
        case .failed:
            message("Emfy couldn’t open this file. It may have been moved, deleted, or changed.")
        }
    }

    private func paper(_ image: CGImage, naturalSize: CGSize) -> some View {
        let aspect = naturalSize.width / max(naturalSize.height, 1)
        return Rectangle()
            .fill(.white)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            .padding(20)
            .accessibilityElement()
            .accessibilityLabel("\(entry?.baseName ?? "Metafile") drawing")
    }

    private func message(_ text: String) -> some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        }
    }

    // MARK: - Bottom placeholders (wired in I2 / I3)

    @ToolbarContentBuilder
    private var bottomPlaceholders: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
            Spacer()
            Button { } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(true)
            Spacer()
            Button { } label: {
                Label("Info", systemImage: "info.circle")
            }
            .disabled(true)
        }
    }

    // MARK: - Loading

    private var entry: RecentEntry? {
        store.entry(id: entryID)
    }

    private var subtitle: String {
        guard let entry else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
        return "\(entry.fullFormatName) · \(size)"
    }

    private func load() async {
        phase = .loading
        guard let entry else {
            phase = .failed
            return
        }
        do {
            let data = try await store.resolveData(for: entry)
            let loaded = try await Task.detached(priority: .userInitiated) {
                try MetafileLoader.load(data)
            }.value
            if let image = loaded.image {
                phase = .loaded(SendableImage(cgImage: image), loaded.naturalSize)
            } else {
                phase = .unrenderable
            }
        } catch {
            phase = .failed
        }
    }
}

extension View {
    /// Applies `navigationSubtitle` on iOS 26+, where it exists; a no-op below.
    @ViewBuilder
    func metafileNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}
