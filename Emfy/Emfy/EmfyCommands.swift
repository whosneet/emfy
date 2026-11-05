import AppKit
import SwiftUI

/// The app's Help menu: developer documentation, the What's New and Changelog
/// windows, Copy Diagnostic Report, and a pre-addressed support email. Replaces
/// the default Help group so only these items appear under Help.
struct EmfyCommands: Commands {
    /// Opens a registered `Window` scene by id. Supported in `Commands` on
    /// macOS 14, so the menu items can raise the What's New / Changelog windows.
    @Environment(\.openWindow) private var openWindow
    /// The focused viewer's actions, so Copy Diagnostic Report targets the file on
    /// screen (and reads disabled when no file is shown).
    @FocusedValue(\.viewerActions) private var actions

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

            Button("Copy Diagnostic Report") { actions?.copyDiagnosticReport?() }
                .disabled(actions?.copyDiagnosticReport == nil)
            Button("Contact Support") {
                if let url = EmfyLinks.contact {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// Replaces the default "About Emfy" item so the standard About panel shows a single
/// clickable link to the public repo beneath the app name and bundle version (S1a-6).
/// `orderFrontStandardAboutPanel` reads the version from the bundle, and the
/// Info.plist copyright line is the one place Arrley and the MIT licence appear — so
/// the credits don't repeat them.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Emfy") {
                // Built here (not a global) because `NSAttributedString` is not
                // `Sendable`; the action runs on the main actor.
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .paragraphStyle: paragraph,
                ]
                if let url = EmfyLinks.gitHub { attributes[.link] = url }
                let credits = NSAttributedString(string: "github.com/whosneet/emfy", attributes: attributes)
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
