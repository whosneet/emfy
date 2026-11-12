import AppIntents

// MARK: - App Shortcuts (F4a)
//
// The Siri / Spotlight phrases for Emfy's App Intents. Every phrase carries
// `\(.applicationName)` as Apple requires, and each shortcut has a short title and
// an SF Symbol so it reads well in the Shortcuts app and Spotlight. The Open phrase
// interpolates the drawing parameter so Siri can disambiguate from the recent files;
// Convert and Get Text work on a drawing the user picks or a file they hand in, so
// their parameters are optional and the phrases stay natural.

struct EmfyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDrawingIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open \(\.$target) with \(.applicationName)",
            ],
            shortTitle: "Open Drawing",
            systemImageName: "doc.richtext"
        )
        AppShortcut(
            intent: ConvertDrawingIntent(),
            phrases: [
                "Convert a drawing with \(.applicationName)",
                "Convert a drawing in \(.applicationName)",
            ],
            shortTitle: "Convert Drawing",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: GetTextFromDrawingIntent(),
            phrases: [
                "Get text from a drawing in \(.applicationName)",
                "Get text from a drawing with \(.applicationName)",
            ],
            shortTitle: "Get Text from Drawing",
            systemImageName: "text.viewfinder"
        )
    }
}
