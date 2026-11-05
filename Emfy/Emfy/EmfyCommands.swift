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

/// Replaces the default "About Emfy" item so the standard About panel shows Emfy's
/// credits — Arrley Pty Ltd and the MIT licence — beneath the app name and the
/// bundle version (S1a-6). `orderFrontStandardAboutPanel` reads the version from
/// the bundle itself; only the credits need supplying.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Emfy") {
                // Built here (not a global) because `NSAttributedString` is not
                // `Sendable`; the action runs on the main actor.
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let credits = NSAttributedString(
                    string: "Made by Arrley Pty Ltd\nMIT licensed. Source at github.com/whosneet/emfy",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
