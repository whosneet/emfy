import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Presents the system Translate overlay (`translationPresentation`) over the viewer for
/// `text` (F3d) — a read-only translation of the current Find match or the drawing's text.
/// Gated to macOS 14.4 / iOS 17.4, where the Translation framework's SwiftUI modifier
/// exists; below that it is a no-op and the Translate menu item is hidden. Isolated in one
/// modifier so the viewers' already-large bodies gain a single, cheap modifier.
struct DrawingTranslationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 14.4, iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
