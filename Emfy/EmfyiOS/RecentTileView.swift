import SwiftUI

/// One recents grid tile: the white "paper" thumbnail, the file name, then a
/// meta line ("WMF · 20 KB" today, "EMF · 3 Nov" earlier). In selection mode a
/// red remove badge sits on the thumbnail.
struct RecentTileView: View {
    @Environment(RecentsStore.self) private var store
    @Environment(RemovalCoordinator.self) private var removal
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    let entry: RecentEntry
    let isSelecting: Bool

    /// Holds a thumbnail only when the in-memory cache missed and this tile loaded it
    /// off-main (P4). The common path reads the cache in `body` instead, so a
    /// scrolled-away tile redraws instantly with no blank frame, and NSCache stays
    /// free to evict — no per-tile `@State` keeps images alive past eviction.
    @State private var loadedThumbnail: CGImage?

    /// The cache first (synchronous, cheap), then a cache-miss load.
    private var thumbnail: CGImage? {
        store.cachedThumbnail(for: entry) ?? loadedThumbnail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailTile
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    // Big text gets up to three lines before truncating (A7).
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                Text(entry.metaLine())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        // Include the date/size the tile shows, so VoiceOver isn't missing it (A5).
        .accessibilityLabel("\(entry.baseName), \(entry.formatLabel), \(entry.metaSecond())")
        .accessibilityAddTraits(isSelecting ? [] : .isButton)
        // While selecting, expose Remove as a VoiceOver action — the red badge is
        // otherwise hidden by `children: .ignore`.
        .accessibilityActions {
            if isSelecting {
                Button("Remove from Recents", action: remove)
            }
        }
        // Re-fire when the file changes OR the cached image is evicted while the tile
        // is alive (needsLoad flips), so an evicted thumbnail reloads instead of
        // staying blank forever (P4 / review #3). Only touches @State on a miss.
        .task(id: ThumbnailTaskID(name: entry.thumbnailFileName, needsLoad: thumbnail == nil)) {
            guard store.cachedThumbnail(for: entry) == nil else { return }
            loadedThumbnail = await store.loadThumbnail(for: entry)
        }
    }

    private var thumbnailTile: some View {
        ZStack(alignment: .topTrailing) {
            // One white paper surface (white in both appearances); the drawing
            // is drawn directly onto it with inner padding. The thumbnail has a
            // transparent background, so there is no inner card-inside-a-card.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
                .aspectRatio(372.0 / 272.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: displayScale)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)

            if isSelecting {
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityHidden(true)  // reached via the tile's Remove action (A1)
            }
        }
    }

    /// Removes this entry through the shared coordinator, read from the environment —
    /// so the tile carries no per-entry closure that would defeat diffing (P3).
    private func remove() {
        removal.requestRemoval(id: entry.id, store: store, toast: toast)
    }
}
