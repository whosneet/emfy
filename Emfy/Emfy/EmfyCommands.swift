import AppKit
import SwiftUI

/// The app's Help menu: developer documentation, the What's New and Changelog
/// windows, and a pre-addressed feedback email. Replaces the default Help
/// group so only these items appear under Help.
struct EmfyCommands: Commands {
    /// Opens a registered `Window` scene by id. Supported in `Commands` on
    /// macOS 14, so the menu items can raise the What's New / Changelog windows.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Developer Documentation") {
                if let url = EmfyLinks.gitHub {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("What's New in Emfy") {
                openWindow(id: "whats-new")
            }
            Button("Changelog") {
                openWindow(id: "changelog")
            }

            Divider()

            Button("Contact the Developer") {
                if let url = EmfyLinks.contact {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
