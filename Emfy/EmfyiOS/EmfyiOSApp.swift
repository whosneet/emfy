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
    @State private var store = RecentsStore()

    var body: some Scene {
        WindowGroup {
            RecentsView()
                .environment(store)
        }
    }
}

/// A push onto the viewer. Carries only the recents entry id; the viewer
/// resolves the file and renders it, so navigation state stays light and
/// restorable (Axiom nav.md: routes carry ids, not models).
struct ViewerRoute: Hashable {
    let entryID: UUID
}
