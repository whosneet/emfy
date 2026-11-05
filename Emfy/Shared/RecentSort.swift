import Foundation

/// Pure ordering for the recents library (S1a Library extras › Sort recents).
///
/// `.date` reproduces today's order exactly — most recently opened first, the
/// same comparator `RecentsStore` uses. `.name` and `.size` add deterministic
/// orderings for the single-section views, each breaking ties by recency. The
/// Today/Earlier split (date) and the pinned section are applied by the views
/// around this; this is only the comparator.
enum RecentSort {
    static func sorted(_ entries: [RecentEntry], by order: EmfySettings.SortOrder) -> [RecentEntry] {
        switch order {
        case .date:
            return entries.sorted { $0.openedAt > $1.openedAt }
        case .name:
            return entries.sorted { a, b in
                switch a.displayName.localizedCaseInsensitiveCompare(b.displayName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.openedAt > b.openedAt
                }
            }
        case .size:
            return entries.sorted { a, b in
                a.byteCount != b.byteCount
                    ? a.byteCount > b.byteCount          // largest first
                    : a.openedAt > b.openedAt
            }
        }
    }
}
