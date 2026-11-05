import Foundation

/// Derives the macOS File ▸ Open Recent list (C3b scope 2): the most recent files
/// by recency, capped. Pure so the derivation is unit-tested independently of the
/// store's own ordering, and so the cap is one stated constant.
enum OpenRecentList {
    /// How many recent files the Open Recent submenu shows. Stated cap.
    static let maximumCount = 10

    /// The newest `maximumCount` entries, newest first — regardless of the input
    /// order, so the menu is correct even if the caller hands an unsorted list.
    static func items(from entries: [RecentEntry]) -> [RecentEntry] {
        Array(entries.sorted { $0.openedAt > $1.openedAt }.prefix(maximumCount))
    }
}
