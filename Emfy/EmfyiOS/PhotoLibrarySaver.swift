import Foundation
import Photos

/// The outcome of a "Save to Photos" request, reported back to the main actor.
enum PhotoSaveResult: Sendable {
    case saved
    /// Access was refused (or restricted) — the caller offers a Settings path.
    case denied
    /// The library change itself failed; carries a user-facing message.
    case failed(String)
}

/// Saves an exported PNG to the user's photo library with the minimal,
/// add-only authorization. Never reads the library. The usage string lives in
/// Info.plist as `NSPhotoLibraryAddUsageDescription`.
enum PhotoLibrarySaver {
    /// Requests add-only access if undetermined, then adds `pngData` as a photo.
    /// `.limited` is treated as granted (Axiom `photo-library`: limited access is
    /// valid, not a denial). The `performChanges` block is `@Sendable` so it does
    /// not inherit an actor and trap on PhotoKit's queue.
    static func save(pngData: Data) async -> PhotoSaveResult {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status: PHAuthorizationStatus = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current

        guard status == .authorized || status == .limited else {
            return .denied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData, options: nil)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
