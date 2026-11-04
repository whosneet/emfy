import SwiftUI

/// Emfy for iPhone and iPad — a viewer for EMF / WMF files and their gzip-wrapped
/// .emz / .wmz forms.
///
/// Not a `DocumentGroup`: on iOS 17 that always launches into the system file
/// browser (v3-plan §4 I1). Emfy instead owns a recents home — a `WindowGroup`
/// with a `NavigationStack` rooted at `RecentsView`. Files arrive through the
/// Files picker (`fileImporter`) and through `onOpenURL` (Mail, Messages, the
/// share sheet). The document model and renderer are the shared, clean-room
/// EMFKit the Mac app and Quick Look extensions use.
@main
struct EmfyiOSApp: App {
    var body: some Scene {
        WindowGroup {
            RecentsView()
                // One shared store, loaded once. The app is single-window
                // (`UIApplicationSupportsMultipleScenes` = false), so an incoming
                // file open reuses this window and navigates it — never a new
                // iPad window per open (the I1 "3 Hidden Windows" fix).
                .environment(RecentsStore.shared)
        }
    }
}

/// A push onto the viewer. Carries only the recents entry id; the viewer
/// resolves the file and renders it, so navigation state stays light and
/// restorable (Axiom nav.md: routes carry ids, not models). `Codable` so the
/// navigation path survives scene restoration (iPad multiple windows / Stage
/// Manager); a stale id falls to the viewer's existing failed/pruned path.
struct ViewerRoute: Hashable, Codable {
    let entryID: UUID
}
