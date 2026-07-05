import AppKit
import SwiftUI

/// The app's Help menu: developer documentation, the What's New and Changelog
/// windows, and a pre-addressed feedback email. Replaces the default Help
/// group so only these items appear under Help.
struct EmfyCommands: Commands {
    /// Opens a registered `Window` scene by id. Supported in `Commands` on
    /// macOS 14, so the menu items can raise the What's New / Changelog windows.
    @Environment(\.openWindow) private var openWindow

    /// The project's public repository, used as the developer documentation.
    private static let documentationURL = URL(string: "https://github.com/whosneet/emfy")

    /// A pre-addressed feedback email. Built with `URLComponents` so the
    /// subject is percent-encoded correctly.
    private static var feedbackURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@neetsingh.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "Emfy - Feedback/Support")]
        return components.url
    }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Developer Documentation") {
                if let url = Self.documentationURL {
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
                if let url = Self.feedbackURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
