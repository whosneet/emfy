import SwiftUI
import UniformTypeIdentifiers

/// "Save a Copy…" and the undoable removal flow for received files (C4a H3 — owner
/// decision "Offer Save to Files first"). A received entry (`importedFileName != nil`)
/// is a file Emfy copied in from Mail/Messages/Inbox/tmp, so removing it destroys
/// Emfy's only copy; before that the user is offered an export.
///
/// This file holds the export documents, the shared `RemovalCoordinator` that drives
/// the confirm → optional export → remove sequence for the SwiftUI surfaces (the
/// sidebar row, the grid tile, the viewer, Settings, the More menu), and the toast
/// wiring for the single-removal Undo. The Mac menu-bar "Clear Menu" uses the AppKit
/// `MacRecentsConfirmation` path, which shares the same `RemovalConfirmation` wording.
///
/// These formats have no system UTI (see `MetafileTypes`), so a copy is exported as
/// plain data under its real name and extension — Files/Finder derive the type from
/// the extension, exactly as they do for the originals.

/// A `FileDocument` carrying one received file's bytes, exported under its real name.
/// Write-only.
struct MetafileCopyDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.data]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A `FileDocument` wrapping a directory of several received copies, so Clear with
/// several received files exports them all under their real names in one folder
/// (C4a H3 — chosen approach: a single folder export). Write-only.
struct ReceivedFilesFolderDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.folder]
    /// file name → bytes.
    let files: [String: Data]

    init(files: [String: Data]) { self.files = files }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for (name, data) in files {
            children[name] = FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}

/// Drives the SwiftUI confirm → optional Save a Copy → remove sequence, shared by
/// every surface that removes recents (C4a H3, H2). Apply `.recentsRemoval(...)` to
/// host the alerts and exporters; call `requestRemoval` / `requestClear` to start.
@MainActor
@Observable
final class RemovalCoordinator {
    struct SingleRequest: Identifiable, Equatable {
        let id: UUID
        let displayName: String
    }
    struct ClearRequest: Identifiable, Equatable {
        let id = UUID()
        let receivedCount: Int
        let totalCount: Int
    }

    var singleRequest: SingleRequest?
    var clearRequest: ClearRequest?

    // Export presentation state.
    var isExportingSingle = false
    var isExportingFolder = false
    var singleDocument = MetafileCopyDocument(data: Data())
    var singleFileName = "Metafile"
    var folderDocument = ReceivedFilesFolderDocument(files: [:])
    var exportError: String?

    /// The id to remove once a single Save a Copy completes.
    @ObservationIgnored private var pendingSingleRemovalID: UUID?

    /// A per-window guard consulted before removing an entry that may be the open, dirty editing
    /// document (R2U3): it runs the save guard and returns `false` to abort the removal (the user
    /// must resolve a save decision on the document first). Set by `LibraryWindow`; `nil`
    /// elsewhere ⇒ no guard, remove straight away.
    @ObservationIgnored var removalGuard: ((UUID) async -> Bool)?

    /// Asks to remove a single entry. Ordinary entries are removed at once (with the
    /// Undo toast); a received entry raises the Save-a-Copy confirmation. The open, dirty
    /// editing document's edits are saved (or its save dialog is raised) first, so a Remove
    /// never discards them (R2U3).
    func requestRemoval(id: UUID, store: RecentsStore, toast: ToastCenter?) {
        guard let entry = store.entry(id: id) else { return }
        if let removalGuard {
            Task { @MainActor in
                guard await removalGuard(id) else { return }   // aborted: resolve the save first
                guard store.entry(id: id) != nil else { return }
                self.beginRemoval(id: id, entry: entry, store: store, toast: toast)
            }
        } else {
            beginRemoval(id: id, entry: entry, store: store, toast: toast)
        }
    }

    private func beginRemoval(id: UUID, entry: RecentEntry, store: RecentsStore, toast: ToastCenter?) {
        let plan = RemovalConfirmation.plan(forSingleReceived: entry.importedFileName != nil)
        if plan.needsConfirmation {
            singleRequest = SingleRequest(id: id, displayName: entry.displayName)
        } else {
            performRemoval(id: id, displayName: entry.displayName, store: store, toast: toast, undoable: true)
        }
    }

    /// Removes the entry and (when undoable) shows the Undo toast with the removed
    /// name (A17, H3).
    func performRemoval(id: UUID, displayName: String, store: RecentsStore, toast: ToastCenter?, undoable: Bool) {
        let base = (displayName as NSString).deletingPathExtension
        store.remove(id)
        if undoable {
            toast?.show(
                "Removed “\(base)”",
                systemImage: "trash",
                duration: RecentsStore.undoWindowSeconds,
                actionTitle: "Undo",
                action: { [weak store] in store?.undoLastRemoval() }
            )
        } else {
            toast?.show("Saved a copy of “\(base)”", systemImage: "checkmark.circle")
        }
    }

    /// Begins a single Save a Copy: resolves the bytes, then opens the exporter; the
    /// removal happens only when the export succeeds.
    func saveCopyThenRemove(id: UUID, store: RecentsStore) {
        guard let entry = store.entry(id: id) else { return }
        pendingSingleRemovalID = id
        singleFileName = entry.displayName
        Task { @MainActor in
            do {
                let data = try await store.resolveData(for: entry)
                singleDocument = MetafileCopyDocument(data: data)
                isExportingSingle = true
            } catch {
                exportError = "Emfy couldn’t read this file to save a copy."
                pendingSingleRemovalID = nil
            }
        }
    }

    /// The exporter finished for a single Save a Copy.
    func finishSingleExport(success: Bool, store: RecentsStore, toast: ToastCenter?) {
        defer { pendingSingleRemovalID = nil }
        guard success, let id = pendingSingleRemovalID, let entry = store.entry(id: id) else { return }
        // The copy is safe now, so remove it (non-undoable — it was just saved).
        performRemoval(id: id, displayName: entry.displayName, store: store, toast: toast, undoable: false)
    }

    /// Asks to clear Recents, confirming per `RemovalConfirmation`.
    func requestClear(store: RecentsStore) {
        let received = store.entries.filter { $0.importedFileName != nil }.count
        clearRequest = ClearRequest(receivedCount: received, totalCount: store.entries.count)
    }

    /// Begins Save a Copy for Clear: builds a folder of all received copies, then
    /// opens the folder exporter. The clear happens when the export succeeds.
    func saveCopiesThenClear(store: RecentsStore) {
        let received = store.entries.filter { $0.importedFileName != nil }
        Task { @MainActor in
            var files: [String: Data] = [:]
            for entry in received {
                if let data = try? await store.resolveData(for: entry) {
                    files[uniqueName(entry.displayName, in: files)] = data
                }
            }
            guard !files.isEmpty else {
                exportError = "Emfy couldn’t read these files to save copies."
                return
            }
            folderDocument = ReceivedFilesFolderDocument(files: files)
            isExportingFolder = true
        }
    }

    /// The folder exporter finished for Clear.
    func finishFolderExport(success: Bool, store: RecentsStore) {
        guard success else { return }
        store.clear()
    }

    private func uniqueName(_ name: String, in files: [String: Data]) -> String {
        guard files[name] != nil else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if files[candidate] == nil { return candidate }
            index += 1
        }
    }
}

extension View {
    /// Hosts the single-removal and clear confirmations and their Save-a-Copy
    /// exporters for a `RemovalCoordinator`. Apply once per surface that removes
    /// recents (C4a H3, H2).
    func recentsRemoval(_ coordinator: RemovalCoordinator, store: RecentsStore, toast: ToastCenter?) -> some View {
        modifier(RecentsRemovalModifier(coordinator: coordinator, store: store, toast: toast))
    }
}

private struct RecentsRemovalModifier: ViewModifier {
    @Bindable var coordinator: RemovalCoordinator
    let store: RecentsStore
    let toast: ToastCenter?

    func body(content: Content) -> some View {
        content
            .alert(
                "Remove This File?",
                isPresented: Binding(get: { coordinator.singleRequest != nil }, set: { if !$0 { coordinator.singleRequest = nil } }),
                presenting: coordinator.singleRequest
            ) { request in
                Button("Save a Copy…") { coordinator.saveCopyThenRemove(id: request.id, store: store) }
                Button("Remove", role: .destructive) {
                    coordinator.performRemoval(id: request.id, displayName: request.displayName, store: store, toast: toast, undoable: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(RemovalConfirmation.plan(forSingleReceived: true).message)
            }
            .alert(
                "Clear Recents?",
                isPresented: Binding(get: { coordinator.clearRequest != nil }, set: { if !$0 { coordinator.clearRequest = nil } }),
                presenting: coordinator.clearRequest
            ) { request in
                if RemovalConfirmation.plan(scope: .clear, receivedCount: request.receivedCount, totalCount: request.totalCount).offersSaveCopy {
                    Button("Save a Copy…") { coordinator.saveCopiesThenClear(store: store) }
                }
                Button("Clear Recents", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(RemovalConfirmation.plan(scope: .clear, receivedCount: request.receivedCount, totalCount: request.totalCount).message)
            }
            .fileExporter(
                isPresented: $coordinator.isExportingSingle,
                document: coordinator.singleDocument,
                contentType: .data,
                defaultFilename: coordinator.singleFileName
            ) { result in
                coordinator.finishSingleExport(success: isSuccess(result), store: store, toast: toast)
            }
            .fileExporter(
                isPresented: $coordinator.isExportingFolder,
                document: coordinator.folderDocument,
                contentType: .folder,
                defaultFilename: "Emfy Files"
            ) { result in
                coordinator.finishFolderExport(success: isSuccess(result), store: store)
            }
            .alert(
                "Couldn’t Save a Copy",
                isPresented: Binding(get: { coordinator.exportError != nil }, set: { if !$0 { coordinator.exportError = nil } }),
                presenting: coordinator.exportError
            ) { _ in
                Button("OK", role: .cancel) { coordinator.exportError = nil }
            } message: { message in
                Text(message)
            }
    }

    private func isSuccess(_ result: Result<URL, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
