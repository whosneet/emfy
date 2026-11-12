import AppIntents
import Foundation

// MARK: - App Intents entity for a remembered drawing (F4a)
//
// `DrawingEntity` exposes one Recents entry to Siri, Spotlight and Shortcuts.
// It is deliberately light — an id, the file name, a format/size subtitle and a
// path to the already-cached thumbnail PNG — so building a batch of them never
// resolves a bookmark or renders. The id is the entry's own UUID, so an intent
// that receives an entity re-finds the live entry through `RecentsStore`.
//
// Private mode hides everything (owner, S1a-5): the query returns nothing while
// Private is on, and session-only Private entries are never surfaced even when
// it is off. F4b (Apple Intelligence: IndexedEntity / assistant schemas) layers
// onto this type without changing its stored shape.

/// One remembered drawing, as an App Intents entity.
struct DrawingEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drawing"
    static let defaultQuery = DrawingEntityQuery()

    /// The Recents entry's id — the stable handle an intent resolves back to a file.
    let id: UUID
    /// The file name as shown, with extension ("House sketch.wmf").
    let name: String
    /// Short format badge ("EMF", "Compressed WMF").
    let formatLabel: String
    /// The localised file size ("20 KB").
    let sizeLabel: String
    /// Absolute path to the cached thumbnail PNG, when one exists. Shown in the
    /// entity's display representation; never decoded in-process beyond what the
    /// framework needs to render the row.
    let thumbnailPath: String?

    var displayRepresentation: DisplayRepresentation {
        let image: DisplayRepresentation.Image
        if let thumbnailPath, FileManager.default.fileExists(atPath: thumbnailPath) {
            image = DisplayRepresentation.Image(url: URL(fileURLWithPath: thumbnailPath))
        } else {
            image = DisplayRepresentation.Image(systemName: "doc.richtext")
        }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(formatLabel) · \(sizeLabel)",
            image: image
        )
    }
}

// MARK: - Query

/// Resolves drawings for the Shortcuts/Siri picker: by id, by the ten most recent,
/// and by a name search. Every method runs on the main actor (it reads the
/// main-actor `RecentsStore`) and returns `Sendable` value entities; Private mode
/// yields an empty result throughout (`DrawingEntityFactory`).
struct DrawingEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DrawingEntity] {
        await DrawingEntityProvider.entities(ids: Set(identifiers))
    }

    @MainActor
    func suggestedEntities() async throws -> [DrawingEntity] {
        await DrawingEntityProvider.entities(limit: 10)
    }

    @MainActor
    func entities(matching string: String) async throws -> [DrawingEntity] {
        await DrawingEntityProvider.entities(search: string)
    }
}

// MARK: - Store access

/// Bridges the query to the shared store: loads the persisted history once, then
/// hands the live entries to the pure `DrawingEntityFactory`. Kept apart from the
/// factory so the transformation stays testable without the singleton.
enum DrawingEntityProvider {
    @MainActor
    static func entities(ids: Set<UUID>? = nil, search: String? = nil, limit: Int? = nil) async -> [DrawingEntity] {
        let store = RecentsStore.shared
        // A Shortcuts/Siri resolution can arrive before the library window's own
        // load, so make sure the persisted entries are in memory first.
        await store.loadIfNeeded()
        return DrawingEntityFactory.entities(
            from: store.entries,
            isPrivate: store.isPrivate,
            privateIDs: store.privateIDs,
            thumbnailsDirectory: store.locations.thumbnailsDirectory,
            ids: ids,
            search: search,
            limit: limit
        )
    }
}

// MARK: - Pure factory

/// The pure entries → entities transformation (testable without the store). Private
/// mode returns nothing; session-only Private entries are always filtered; the input
/// is already newest-first, so `limit` yields the most recent.
enum DrawingEntityFactory {
    static func entities(
        from entries: [RecentEntry],
        isPrivate: Bool,
        privateIDs: Set<UUID>,
        thumbnailsDirectory: URL,
        ids: Set<UUID>? = nil,
        search: String? = nil,
        limit: Int? = nil
    ) -> [DrawingEntity] {
        // Private mode hides the whole library from automation (S1a-5).
        guard !isPrivate else { return [] }
        // Session-only Private entries are never surfaced, even with Private off.
        var list = entries.filter { !privateIDs.contains($0.id) }
        if let ids {
            list = list.filter { ids.contains($0.id) }
        }
        if let search {
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !needle.isEmpty {
                list = list.filter { $0.displayName.lowercased().contains(needle) }
            }
        }
        if let limit, limit >= 0 {
            list = Array(list.prefix(limit))
        }
        return list.map { entity(from: $0, thumbnailsDirectory: thumbnailsDirectory) }
    }

    static func entity(from entry: RecentEntry, thumbnailsDirectory: URL) -> DrawingEntity {
        let thumbnailPath = entry.thumbnailFileName.map {
            thumbnailsDirectory.appendingPathComponent($0).path
        }
        return DrawingEntity(
            id: entry.id,
            name: entry.displayName,
            formatLabel: entry.formatLabel,
            sizeLabel: entry.sizeLabel,
            thumbnailPath: thumbnailPath
        )
    }
}
