import CoreGraphics
import EMFEdit
import Foundation

/// A page-size preset offered by File ▸ New Drawing… (Mac) and the library "+"
/// (iPad). Pure data, so the naming/sizing is testable without any UI (E3a design
/// call 4). Sizes are in millimetres and drive `SceneFactory.blankDocument`.
enum NewDrawingPreset: String, CaseIterable, Identifiable, Sendable {
    case a4Landscape
    case a4Portrait
    case usLetterPortrait
    case widescreen16x9

    var id: String { rawValue }

    /// A4 landscape is the default (design call 4).
    static let `default`: NewDrawingPreset = .a4Landscape

    var title: String {
        switch self {
        case .a4Landscape: return "A4 Landscape"
        case .a4Portrait: return "A4 Portrait"
        case .usLetterPortrait: return "US Letter Portrait"
        case .widescreen16x9: return "Widescreen 16:9"
        }
    }

    /// The page size in millimetres (width, height).
    var pageSizeMillimetres: CGSize {
        switch self {
        case .a4Landscape: return CGSize(width: 297, height: 210)
        case .a4Portrait: return CGSize(width: 210, height: 297)
        case .usLetterPortrait: return CGSize(width: 215.9, height: 279.4)
        case .widescreen16x9: return CGSize(width: 254, height: 142.875)
        }
    }
}

/// Creates a new blank drawing as a real EMF and brings it into the recents
/// library (E3a design call 4): it writes the minimal EMF to a uniquely-named
/// temporary file under a deduplicated "Untitled Drawing" name, then imports it
/// through the store's normal open path — so the file is copied into Imported/
/// (the temp location is ephemeral) and becomes an ordinary recents entry that
/// saves, undoes and exports like any other.
enum NewDrawing {
    static let baseName = "Untitled Drawing"
    static let fileExtension = "emf"

    /// Entry ids that should enter edit mode the moment their viewer finishes
    /// loading (a freshly-created drawing opens straight into the editor, design
    /// call 4). The signal lives here — not in per-window state — so it works the
    /// same from the Mac File menu and the iPad "+". Consumed once.
    @MainActor private static var pendingEditIDs: Set<UUID> = []

    @MainActor static func markPendingEdit(_ id: UUID) { pendingEditIDs.insert(id) }

    /// Whether `id` was created for immediate editing, removing it so edit mode is
    /// entered only once.
    @MainActor static func consumePendingEdit(_ id: UUID) -> Bool {
        pendingEditIDs.remove(id) != nil
    }

    /// The next free "Untitled Drawing" display name given the existing entries'
    /// display names: "Untitled Drawing" when free, otherwise "Untitled Drawing 2",
    /// "Untitled Drawing 3", … skipping any already taken. Compares base names with
    /// the extension stripped, so "Untitled Drawing.emf" counts as taken. Pure.
    static func nextName(existingDisplayNames: [String]) -> String {
        let taken = Set(existingDisplayNames.map { stripExtension($0) })
        if !taken.contains(baseName) { return baseName }
        var n = 2
        while taken.contains("\(baseName) \(n)") { n += 1 }
        return "\(baseName) \(n)"
    }

    private static func stripExtension(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// Writes a new blank drawing for `preset`, imports it, and returns its recents
    /// entry id (or `nil` on failure, with `store.lastErrorMessage` set). Runs on the
    /// main actor; the store does its own off-main file work.
    @MainActor
    static func create(_ preset: NewDrawingPreset, in store: RecentsStore) async -> UUID? {
        let data: Data
        do {
            data = try SceneFactory.blankDocument(pageSizeMillimetres: preset.pageSizeMillimetres)
        } catch {
            store.lastErrorMessage = "Emfy couldn’t create a new drawing."
            return nil
        }
        return await create(data: data, in: store)
    }

    /// Imports a ready-made EMF (e.g. the one an AI "generate a drawing" produced) as a new
    /// "Untitled Drawing" and returns its recents entry id, opening it straight into the
    /// editor. The bytes are written only now — there is no file on disk until the user
    /// generates/creates — so "Cancel" before this never touches the filesystem.
    @MainActor
    static func create(data: Data, in store: RecentsStore) async -> UUID? {
        await store.loadIfNeeded()
        let name = nextName(existingDisplayNames: store.entries.map(\.displayName))
        let fileName = "\(name).\(fileExtension)"
        // A unique per-call temporary directory, so two quick "New Drawing"s never
        // collide on the same path and each imports its own copy.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyNewDrawing-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            store.lastErrorMessage = "Emfy couldn’t create a new drawing."
            return nil
        }
        let id = await store.handleOpenedURL(url)
        if let id { markPendingEdit(id) }   // open straight into the editor
        return id
    }
}
