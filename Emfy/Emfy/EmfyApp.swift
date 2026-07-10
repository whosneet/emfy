import AppKit
import SwiftUI

/// Emfy — a viewer-only document app for EMF (Enhanced Metafile) files.
///
/// The window is a thin shell around EMFKit (primer §3): `EMFDocument` parses
/// and renders through the same clean-room package the Quick Look extensions
/// use; this app adds only presentation (zoom/pan/fit) and export.
@main
struct EmfyApp: App {
    var body: some Scene {
        DocumentGroup(viewing: EMFDocument.self) { configuration in
            EMFDocumentView(document: configuration.document)
        }
        .commands {
            // Replace New Document — this viewer cannot create EMF files — but
            // retain the standard File > Open… command this replacement would
            // otherwise remove on some macOS versions.
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Help menu: documentation, What's New, Changelog, and feedback.
            EmfyCommands()
        }

        // Single-instance auxiliary windows the Help menu raises by id.
        Window("What's New in Emfy", id: "whats-new") {
            WhatsNewView()
        }
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentSize)

        Window("Emfy Changelog", id: "changelog") {
            ChangelogView()
        }
        .defaultSize(width: 460, height: 600)
    }
}
