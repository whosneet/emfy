import Foundation

/// One remembered file in the recents home. Persisted as JSON (bookmark + light
/// metadata); the rendered thumbnail is cached separately as a PNG in Caches,
/// referenced here by file name. Everything needed to show a tile is stored, so
/// the grid never has to resolve a bookmark just to draw.
///
/// Cross-platform (C2): the model is compiled for macOS and iOS. The bookmark is
/// app-scoped and security-scoped on macOS, a plain data bookmark on iOS; the
/// entry doesn't care which — it only carries the bytes.
struct RecentEntry: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    /// The file name as shown, including extension ("House sketch.wmf").
    var displayName: String
    /// Short format badge for the grid meta line ("WMF", "Compressed WMF").
    var formatLabel: String
    /// Full format name for the viewer subtitle and file info ("Windows
    /// Metafile").
    var fullFormatName: String
    /// The file's byte size on disk.
    var byteCount: Int64
    /// When Emfy last opened the file — drives Today/Earlier sectioning and the
    /// meta line's date.
    var openedAt: Date
    /// A security-scoped bookmark that re-resolves the file in place (app-scoped
    /// on macOS, a plain data bookmark on iOS).
    var bookmark: Data
    /// The cached thumbnail's file name within the thumbnails cache directory,
    /// or `nil` when rendering produced none.
    var thumbnailFileName: String?

    // MARK: - C2 fields (all optional, so an older store decodes cleanly — §d)

    /// A stable identity for the underlying file, used to de-duplicate recents so
    /// reopening the same file promotes its entry rather than adding a second one
    /// (§c). The standardised resolved path, or `nil` when identity couldn't be
    /// derived (the store then falls back to display name + byte count).
    var fileIdentity: String?
    /// When the opened file arrived somewhere Emfy can't keep accessing it (tmp,
    /// an Inbox, or a location whose security scope couldn't be taken), its bytes
    /// are copied into Application Support/Emfy/Imported and this names that copy
    /// (§b). The copy is deleted together with the entry.
    var importedFileName: String?
    /// Changes on every open, so the viewer's `task(id:)` re-runs and re-renders
    /// when the same file is reopened with changed content, rather than keeping a
    /// stale render (§c). `nil` only for an entry persisted before C2, until it is
    /// next opened.
    var reloadToken: UUID?

    /// The file name without its extension, for the viewer navigation title and
    /// VoiceOver.
    var baseName: String {
        (displayName as NSString).deletingPathExtension
    }

    /// A value that changes whenever this file is (re)opened, for the viewer's
    /// `task(id:)`. Falls back to `id` for a pre-C2 entry with no token.
    var reloadKey: ReloadKey {
        ReloadKey(id: id, token: reloadToken)
    }

    /// Composite reload identity: the entry id plus its per-open token.
    struct ReloadKey: Hashable, Sendable {
        let id: UUID
        let token: UUID?
    }
}

/// Maps a metafile's extension to the user-facing format names. Derived from the
/// file name because that is what the recents grid and the mockups show
/// ("House sketch.wmf" → "WMF" / "Windows Metafile"); the bytes are not needed.
enum MetafileFormatLabel {
    /// Returns (short badge, full name) for a file name's extension.
    static func names(for fileName: String) -> (short: String, full: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "emf": return ("EMF", "Enhanced Metafile")
        case "wmf": return ("WMF", "Windows Metafile")
        case "emz": return ("Compressed EMF", "Compressed Enhanced Metafile")
        case "wmz": return ("Compressed WMF", "Compressed Windows Metafile")
        default: return ("Metafile", "Metafile")
        }
    }

    /// The file extension to give an imported copy, lower-cased and limited to the
    /// metafile extensions Emfy reads (so a crafted name can't pick the stored
    /// copy's type). Defaults to `emf` when the name has no usable extension.
    static func importedExtension(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["emf", "wmf", "emz", "wmz"].contains(ext) ? ext : "emf"
    }
}
