#if os(iOS)
import SwiftUI

/// The iPad/iPhone viewer menu commands (C4b K1): the zoom group, the immersive
/// controls toggle, and Info — driven by the viewer's `focusedSceneValue(.viewerActions)`.
/// Registered on the `WindowGroup`'s `.commands` rather than as view-level
/// `.keyboardShortcut`s, so iPadOS owns them through the menu bar and they fire even
/// while the sidebar holds first responder — the case the view-level shortcuts missed.
///
/// `CommandGroup(after: .sidebar)` adds these into the system **View** menu (the same
/// placement the Mac uses), so there is no second "View" menu (C4b review #2).
///
/// ⌘= also zooms in: "+" needs Shift on a US keyboard. On iPadOS the system treats the
/// "+" key command as also matching the unshifted "=" chord, so one "Zoom In ⌘+" item
/// catches both — no duplicate menu row needed (verified on the iPad simulator, review #2).
///
/// Chrome toggle key: ⌃⌘H. ⌘H is the iPadOS Go-to-Home shortcut and ⇧⌘H is the
/// Simulator's own Home; adding Control sidesteps both and reads as "Hide". Esc still
/// restores the chrome (kept view-level in the viewer).
struct ViewerCommandsIOS: Commands {
    @FocusedValue(\.viewerActions) private var actions

    private var noDocument: Bool { actions?.isDocumentLoaded != true }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(noDocument)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(noDocument)
            Button("Actual Size") { actions?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(noDocument)
            Button("Zoom to Fit") { actions?.fit() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(noDocument)

            Divider()

            Button(actions?.isChromeHidden == true ? "Show Controls" : "Hide Controls") {
                actions?.toggleChrome?()
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(noDocument)

            Button("Show Details") { actions?.toggleInfo?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(noDocument)

            Divider()

            // Find (F3b): the single ⌘F/⌘G/⇧⌘G owners, routed through the viewer's
            // focusedSceneValue like the zoom group so they fire from the hardware keyboard.
            Button("Find…") { actions?.presentFind?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.presentFind == nil)
            Button("Find Next") { actions?.findNext?() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.findNext == nil)
            Button("Find Previous") { actions?.findPrevious?() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.findPrevious == nil)
        }
    }
}
#endif
