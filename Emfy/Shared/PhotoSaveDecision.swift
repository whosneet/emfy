import Photos

/// Maps the Photos add-only authorization status to what the viewer should do after
/// a "Save to Photos" tap (C4a H7). Pure and shared so the mapping is unit-tested
/// on both platforms; the actual library write stays in the iOS-only
/// `PhotoLibrarySaver`.
///
/// H7 separates two cases the old code conflated:
/// - `.restricted` (parental controls / MDM) is not the user's choice, so it shows
///   an informational alert with OK only — no Open Settings path.
/// - `.denied` keeps Open Settings, but only when the file was *already* denied
///   before the tap. If the user just declined the system prompt (the status went
///   `.notDetermined` → `.denied`), Emfy stays quiet: the system already asked.
enum PhotoSaveDecision {
    /// What to do once authorization is resolved.
    enum Outcome: Equatable, Sendable {
        /// Granted (`.authorized` or `.limited`) — perform the add.
        case proceed
        /// `.restricted` — an informational alert, OK only.
        case restricted
        /// Denied, and it was denied before the tap — offer Open Settings.
        case deniedNeedsSettings
        /// Denied just now, by declining the system prompt — no alert.
        case deniedSilently
    }

    /// Decides the outcome from the status before the request and the status after.
    ///
    /// - Parameters:
    ///   - previousStatus: the add-only status read *before* requesting access.
    ///   - resolvedStatus: the status after requesting (or `previousStatus` when it
    ///     was already determined).
    static func outcome(
        previousStatus: PHAuthorizationStatus,
        resolvedStatus: PHAuthorizationStatus
    ) -> Outcome {
        switch resolvedStatus {
        case .authorized, .limited:
            return .proceed
        case .restricted:
            return .restricted
        case .denied:
            // A fresh decline (was undetermined, now denied) needs no Settings
            // nudge — the system prompt just ran. A pre-existing denial does.
            return previousStatus == .notDetermined ? .deniedSilently : .deniedNeedsSettings
        case .notDetermined:
            // Shouldn't occur after a request resolves; treat as a silent decline.
            return .deniedSilently
        @unknown default:
            return .deniedSilently
        }
    }
}
