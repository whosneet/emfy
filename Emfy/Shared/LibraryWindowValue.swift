import Foundation

/// The presentation value a library window opens on (v3-plan §9.1, §11.2). Carries
/// only the recents entry id to show, never the entry itself — `openWindow(id:
/// value:)` persists this for state restoration, so it must be a small, `Codable`
/// identifier, and the window resolves the file from the shared `RecentsStore`
/// (Axiom windows.md: pass ids, not model objects). `nil` opens an empty library
/// window (File ▸ New Window / ⌘N).
struct LibraryWindowValue: Hashable, Codable, Sendable {
    var entryID: UUID?

    init(entryID: UUID? = nil) {
        self.entryID = entryID
    }
}
