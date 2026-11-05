import Foundation

/// Builds the sectioned recents list shared by the Mac sidebar and the iOS grid/list
/// (S1a-5 Library › Sort, Pin, Private mode). Pure, so the sectioning is unit-tested
/// without a view; the views feed it the already-filtered entries (search still
/// works under every sort) and render the returned sections.
///
/// Section order, top to bottom:
/// 1. **Private** — this launch's session-only Private-mode entries (never persisted).
/// 2. **Pinned** — entries the user pinned, in the current sort order.
/// 3. The rest, by sort:
///    - **Date** keeps the Today / Earlier split.
///    - **Name** and **Size** collapse to a single untitled section.
///
/// Every entry appears in exactly one section: a pinned or private entry is drawn out
/// of the Today/Earlier/all buckets so it never shows twice.
enum RecentSections {
    struct Section: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case privateSession, pinned, today, earlier, all
        }
        let kind: Kind
        let entries: [RecentEntry]

        var id: String { kind.rawValue }

        /// The visible header, or `nil` for the single all-files section (name/size).
        var title: String? {
            switch kind {
            case .privateSession: "Private"
            case .pinned: "Pinned"
            case .today: "Today"
            case .earlier: "Earlier"
            case .all: nil
            }
        }
    }

    static func build(
        _ entries: [RecentEntry],
        sort: EmfySettings.SortOrder,
        privateIDs: Set<UUID> = [],
        now: Date = Date()
    ) -> [Section] {
        let sorted = RecentSort.sorted(entries, by: sort)
        let privateEntries = sorted.filter { privateIDs.contains($0.id) }
        let visible = sorted.filter { !privateIDs.contains($0.id) }
        let pinned = visible.filter { $0.isPinned == true }
        let rest = visible.filter { $0.isPinned != true }

        var sections: [Section] = []
        if !privateEntries.isEmpty { sections.append(Section(kind: .privateSession, entries: privateEntries)) }
        if !pinned.isEmpty { sections.append(Section(kind: .pinned, entries: pinned)) }

        switch sort {
        case .date:
            let split = RecentEntry.partitionedByDay(rest, now: now)
            if !split.today.isEmpty { sections.append(Section(kind: .today, entries: split.today)) }
            if !split.earlier.isEmpty { sections.append(Section(kind: .earlier, entries: split.earlier)) }
        case .name, .size:
            if !rest.isEmpty { sections.append(Section(kind: .all, entries: rest)) }
        }
        return sections
    }
}
