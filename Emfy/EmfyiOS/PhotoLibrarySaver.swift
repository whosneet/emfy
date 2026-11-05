import Foundation
import Photos

/// The outcome of a "Save to Photos" request, reported back to the main actor (C4a
/// H7). `.restricted` and the two denial cases are distinguished so the viewer can
/// offer the right follow-up: an informational alert, Open Settings, or nothing.
enum PhotoSaveResult: Sendable {
    case saved
    /// Access is restricted (parental controls / MDM) — an informational alert only.
    case restricted
    /// Denied, and it was already denied before the tap — offer Open Settings.
    case deniedNeedsSettings
    /// Denied just now, by declining the system prompt — stay quiet.
    case deniedSilently
    /// The library change itself failed; carries a user-facing message.
    case failed(String)
}

/// Saves an exported PNG to the user's photo library with the minimal, add-only
/// authorization. Never reads the library. The usage string lives in Info.plist as
/// `NSPhotoLibraryAddUsageDescription`.
enum PhotoLibrarySaver {
    /// Requests add-only access if undetermined, then adds `pngData` as a photo.
    /// `.limited` is treated as granted. The status before and after the request are
    /// mapped through the shared, tested `PhotoSaveDecision` (H7). The `performChanges`
    /// block is `@Sendable` so it doesn't inherit an actor and trap on PhotoKit's queue.
    static func save(pngData: Data) async -> PhotoSaveResult {
        let previous = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolved: PHAuthorizationStatus = previous == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : previous

        switch PhotoSaveDecision.outcome(previousStatus: previous, resolvedStatus: resolved) {
        case .restricted:
            return .restricted
        case .deniedNeedsSettings:
            return .deniedNeedsSettings
        case .deniedSilently:
            return .deniedSilently
        case .proceed:
            break
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
