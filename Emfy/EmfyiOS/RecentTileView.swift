import SwiftUI

/// One recents grid tile: the white "paper" thumbnail, the file name, then a
/// meta line ("WMF · 20 KB" today, "EMF · 3 Nov" earlier). In selection mode a
/// red remove badge sits on the thumbnail.
struct RecentTileView: View {
    @Environment(RecentsStore.self) private var store
    let entry: RecentEntry
    let isSelecting: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.baseName), \(entry.formatLabel), \(sizeString)")
        .accessibilityAddTraits(isSelecting ? [] : .isButton)
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            // One white paper surface (white in both appearances); the drawing
            // is drawn directly onto it with inner padding. The thumbnail has a
            // transparent background, so there is no inner card-inside-a-card.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
                .aspectRatio(372.0 / 272.0, contentMode: .fit)
                .overlay {
                    if let image = store.thumbnailImage(for: entry) {
                        Image(uiImage: image)
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
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .padding(6)
                }
                .accessibilityLabel("Remove \(entry.baseName) from Recents")
            }
        }
    }

    private var metaLine: String {
        let second = Calendar.current.isDateInToday(entry.openedAt)
            ? sizeString
            : entry.openedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(entry.formatLabel) · \(second)"
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
    }
}
