import AppIntents
import Foundation

// MARK: - Open Drawing intent (F4a)
//
// Opens a remembered drawing in Emfy. It conforms to `OpenIntent`, so `openAppWhenRun`
// is true (from the framework, not the deprecated `AppIntent` override) and the system
// brings Emfy forward; the custom `perform` then routes the selection through the app's
// `OpenCoordinator`, exactly as a Finder / Files open would. Kept apart from the
// convert/text/info intents because it reaches into the window coordinator, which the
// logic-test bundle doesn't compile.

struct OpenDrawingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Drawing"
    static let description = IntentDescription("Open a drawing in Emfy.", categoryName: "Drawings")

    @Parameter(title: "Drawing")
    var target: DrawingEntity

    func perform() async throws -> some IntentResult {
        await Self.open(target.id)
        return .result()
    }

    /// Loads the recents history (an intent can arrive cold) and selects the entry in
    /// the front window — or holds it for the next window on a cold launch
    /// (`OpenCoordinator`). Main-actor isolated so `perform` stays nonisolated.
    @MainActor
    private static func open(_ id: UUID) async {
        await RecentsStore.shared.loadIfNeeded()
        OpenCoordinator.shared.selectInFront(id)
    }
}
