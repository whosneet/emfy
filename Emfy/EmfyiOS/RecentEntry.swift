import Foundation

/// One remembered file in the recents home. Persisted as JSON (bookmark + light
/// metadata); the rendered thumbnail is cached separately as a PNG in Caches,
/// referenced here by file name. Everything needed to show a tile is stored, so
/// the grid never has to resolve a bookmark just to draw.
struct RecentEntry: Identifiable, Hashable, Codable {
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
    /// A security-scoped bookmark (iOS) that re-resolves the file in place.
    var bookmark: Data
    /// The cached thumbnail's file name within the thumbnails cache directory,
    /// or `nil` when rendering produced none.
    var thumbnailFileName: String?

    /// The file name without its extension, for the viewer navigation title and
    /// VoiceOver.
    var baseName: String {
        (displayName as NSString).deletingPathExtension
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
}
