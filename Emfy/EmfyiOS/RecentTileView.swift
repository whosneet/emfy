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
    /// Whether this is a session-only Private-mode entry (shows the marker — S1a-5).
    var isPrivate: Bool = false

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
        // One shared label so the tile, list row and sidebar row read identically and
        // all three say ", Pinned" (A-M4) and ", Private" — the tile previously omitted
        // the pin state.
        .accessibilityLabel(entry.accessibilityLabel(pinned: store.isPinned(entry.id), isPrivate: isPrivate))
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

            if isPrivate {
                Image(systemName: "eye.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityHidden(true)
            }

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

/// One row of the iOS list layout (S1a-5 Library › Layout = List): a leading paper
/// thumbnail sized by the Thumbnail-size setting, the file name and meta line, an
/// optional Private marker, and a pin glyph for pinned entries. Tap opens; a context
/// menu and a trailing swipe give Pin/Unpin and Remove; Select mode shows a leading
/// remove badge instead, mirroring the grid tile.
struct RecentListRow: View {
    @Environment(RecentsStore.self) private var store
    @Environment(EmfySettings.self) private var settings
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: RecentEntry
    let isSelecting: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void
    /// Batch Convert multi-select (F1): when `onToggleSelect` is set, Select mode toggles
    /// the row's membership (checkmark) instead of showing the remove badge.
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil

    @State private var loadedThumbnail: CGImage?

    private var thumbnail: CGImage? {
        store.cachedThumbnail(for: entry) ?? loadedThumbnail
    }
    private var isPrivate: Bool { store.isSessionPrivate(entry.id) }

    /// The list thumbnail, capped at accessibility text sizes so the (now multi-line)
    /// name and meta keep horizontal room, mirroring the grid tile (A-H3).
    private var box: CGSize {
        let base = settings.thumbnailSize.listThumbnail
        guard dynamicTypeSize.isAccessibilitySize else { return base }
        let cap: CGFloat = 48
        guard base.width > cap else { return base }
        return CGSize(width: cap, height: base.height * (cap / base.width))
    }

    var body: some View {
        rowContent
            .contextMenu { menu }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
            }
            .task(id: ThumbnailTaskID(name: entry.thumbnailFileName, needsLoad: thumbnail == nil)) {
                guard store.cachedThumbnail(for: entry) == nil else { return }
                loadedThumbnail = await store.loadThumbnail(for: entry)
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        if isSelecting, let onToggleSelect {
            // Batch Convert multi-select (F1): a tap toggles membership, shown by a
            // leading checkmark.
            Button(action: onToggleSelect) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 32)
                    rowBody
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        } else if isSelecting {
            // Select mode: the remove badge is its OWN labelled element (not absorbed by
            // the row), so Voice Control can target "Remove <file>" and it keeps a full
            // 44 pt hit area (A-M5); the row body is a separate, non-interactive label.
            HStack(spacing: 12) {
                removeBadge
                rowBody
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            }
        } else {
            Button(action: onOpen) { rowBody }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityActions {
                    if !isPrivate {
                        Button(store.isPinned(entry.id) ? "Unpin" : "Pin") { store.togglePin(entry.id) }
                    }
                    Button("Remove from Recents", role: .destructive) { onRemove() }
                }
        }
    }

    private var removeBadge: some View {
        Button(action: onRemove) {
            Image(systemName: "minus.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .frame(width: 44, height: 44)   // A-M5: full hit target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(entry.baseName)")
        .accessibilityInputLabels(["Remove \(entry.baseName)", "Remove"])   // A-M5: Voice Control
    }

    private var rowBody: some View {
        HStack(spacing: 12) {
            thumbnailTile
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    // Big text gets up to three lines before truncating, like the grid
                    // tile, instead of a single clipped line (A-H3).
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                Text(entry.metaLine())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            Spacer(minLength: 4)
            if store.isPinned(entry.id) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isPrivate {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnailTile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white)
            .frame(width: box.width, height: box.height)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if OpenRouting.offersNewWindow(supportsMultipleWindows: supportsMultipleWindows) {
            Button {
                openWindow(id: "library", value: LibraryWindowValue(entryID: entry.id))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        if !isPrivate {
            let pinned = store.isPinned(entry.id)
            Button {
                store.togglePin(entry.id)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
        }
        Button(role: .destructive, action: onRemove) {
            Label("Remove from Recents", systemImage: "trash")
        }
    }

    private var accessibilityLabel: String {
        entry.accessibilityLabel(pinned: store.isPinned(entry.id), isPrivate: isPrivate)   // A-M4
    }
}
