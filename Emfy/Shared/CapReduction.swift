import SwiftUI

// The `CapReductionController` logic lives in CapReductionController.swift (SwiftUI-
// free, so it's unit-tested directly). This file is only the SwiftUI host: the
// confirmation alert and the "Save Copies…" folder exporter (S1a-5).

extension View {
    /// Hosts the cap-reduction confirmation and its Save-Copies exporter for a
    /// `CapReductionController` (S1a-5). Apply once to the surface that owns the
    /// Recents-to-keep picker, and drive it from `.onChange(of: settings.recentsToKeep)`.
    func capReduction(_ controller: CapReductionController, store: RecentsStore, settings: EmfySettings) -> some View {
        modifier(CapReductionModifier(controller: controller, store: store, settings: settings))
    }
}

private struct CapReductionModifier: ViewModifier {
    @Bindable var controller: CapReductionController
    let store: RecentsStore
    let settings: EmfySettings

    func body(content: Content) -> some View {
        content
            .alert(
                "Reduce Recents?",
                // A dismissal restores the picker unless a button already resolved it
                // (cancel guards on `pending`), so the picker and the store never drift.
                isPresented: Binding(get: { controller.pending != nil }, set: { if !$0 { controller.cancel(settings: settings) } }),
                presenting: controller.pending
            ) { pending in
                Button("Save Copies…") { controller.saveCopiesThenReduce(store: store, settings: settings) }
                Button("Reduce Anyway", role: .destructive) { controller.reduceAnyway(store: store) }
                Button("Cancel", role: .cancel) { controller.cancel(settings: settings) }
            } message: { pending in
                Text(controller.message(pending))
            }
            .fileExporter(
                isPresented: $controller.isExporting,
                document: ReceivedFilesFolderDocument(files: controller.exportFiles),
                contentType: .folder,
                defaultFilename: "Emfy Files"
            ) { result in
                controller.finishExport(success: isSuccess(result), store: store, settings: settings)
            }
            .alert(
                "Couldn’t Save Copies",
                isPresented: Binding(get: { controller.exportError != nil }, set: { if !$0 { controller.exportError = nil } }),
                presenting: controller.exportError
            ) { _ in
                Button("OK", role: .cancel) { controller.exportError = nil }
            } message: { message in
                Text(message)
            }
    }

    private func isSuccess(_ result: Result<URL, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
