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
            // Replace the New Document command — this app cannot create files.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
