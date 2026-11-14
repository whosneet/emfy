import Foundation

/// The App Group shared by the app and its Quick Look preview and thumbnail
/// extensions (S1b-2b). The app writes the Rendering and Quick Look settings into
/// this suite; the extensions read them back, so a Finder/Files preview or icon
/// matches the viewer.
///
/// Foundation only — this file is compiled into the extensions, which must not
/// link the app's observable settings model or any SwiftUI code.
enum AppGroup {
    /// The bare group name, shared by the Mac (team-prefixed) and iOS (`group.`)
    /// forms below.
    private static let groupName = "com.avneetsingh.emfy"
    /// The Mac team prefix to fall back on when the Info.plist key is absent — the
    /// value `$(AppIdentifierPrefix)` resolves to at build time, trailing dot and all.
    private static let fallbackTeamPrefix = "6Y294JNMJ2."

    /// The App Group identifier.
    ///
    /// - macOS uses the **team-prefixed** form `<TeamID>.com.avneetsingh.emfy`.
    ///   A team-prefixed group needs no App Store Connect registration and works
    ///   for a locally- or Developer-ID-signed app on macOS 14+. It must match the
    ///   `com.apple.security.application-groups` entry in each target's macOS
    ///   entitlements, where it is written as `$(TeamIdentifierPrefix)com.avneetsingh.emfy`.
    ///   The team prefix is read from the `AppIdentifierPrefix` Info.plist key (set to
    ///   `$(AppIdentifierPrefix)` in the app and both extensions), so a change of team
    ///   can't silently desync from a hard-coded literal; the literal is used only if
    ///   that key is missing (S-L1).
    /// - iOS uses the `group.`-prefixed identifier, matching the iOS entitlements.
    static let identifier: String = {
        #if os(macOS)
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTeamPrefix
        return prefix + groupName
        #else
        return "group." + groupName
        #endif
    }()

    /// Whether this process can actually resolve the App Group container. Resolved
    /// once and cached: `UserDefaults(suiteName:)` NEVER returns nil, so gating on it
    /// is dead — `containerURL(forSecurityApplicationGroupIdentifier:)` is the real
    /// test of whether the signature grants the group (S-L1).
    private static let containerAvailable: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil

    /// The shared defaults suite, or `nil` if the container cannot be resolved
    /// (an unentitled process, or a macOS group the signature doesn't grant). A
    /// `nil` return is never fatal: the app falls back to `.standard` and the
    /// extensions fall back to built-in defaults.
    static func defaults() -> UserDefaults? {
        guard containerAvailable else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    // MARK: - MCP server enable gate (A3a)

    /// The shared-suite key for the "Allow AI apps to read drawings" toggle. The
    /// app (Settings) writes it; the `emfy-mcp` helper reads it before serving any
    /// tool call. Default OFF.
    static let mcpServerEnabledKey = "settings.mcp.serverEnabled"

    /// Whether the MCP server is enabled, read by NAME from the shared suite so a
    /// helper process WITHOUT the app-group entitlement still reads the same
    /// preferences domain (its `containerURL` is nil, so `defaults()` would be —
    /// unlike this — unavailable). Defaults to `false` (off) when absent.
    static func mcpServerEnabled() -> Bool {
        UserDefaults(suiteName: identifier)?.bool(forKey: mcpServerEnabledKey) ?? false
    }

    /// The shared-suite key for the MCP server's approved-folder list: the absolute
    /// paths of the folders the user has allowed an AI app to read drawings from. The
    /// app (Settings) writes it; the `emfy-mcp` helper reads it before serving any
    /// file (S9).
    static let mcpAllowedFoldersKey = "settings.mcp.allowedFolders"

    /// The folders the MCP server may read drawings from, read by NAME from the
    /// shared suite (same reasoning as `mcpServerEnabled`). **Default EMPTY** — the
    /// safer default: the GitHub/DMG helper is unsandboxed and driven by an external
    /// AI client, so it serves nothing until the user explicitly approves a folder in
    /// Settings (fail-closed), rather than pre-granting broad folders like Documents.
    /// Absent, non-array, or empty ⇒ no folder is approved and every path is refused.
    static func mcpAllowedFolders() -> [String] {
        (UserDefaults(suiteName: identifier)?.array(forKey: mcpAllowedFoldersKey) as? [String]) ?? []
    }
}
