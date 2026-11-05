import Foundation

/// The App Group shared by the app and its Quick Look preview and thumbnail
/// extensions (S1b-2b). The app writes the Rendering and Quick Look settings into
/// this suite; the extensions read them back, so a Finder/Files preview or icon
/// matches the viewer.
///
/// Foundation only — this file is compiled into the extensions, which must not
/// link the app's observable settings model or any SwiftUI code.
enum AppGroup {
    /// The App Group identifier.
    ///
    /// - macOS uses the **team-prefixed** form `<TeamID>.com.avneetsingh.emfy`.
    ///   A team-prefixed group needs no App Store Connect registration and works
    ///   for a locally- or Developer-ID-signed app on macOS 14+. It must match the
    ///   `com.apple.security.application-groups` entry in each target's macOS
    ///   entitlements, where it is written as `$(TeamIdentifierPrefix)com.avneetsingh.emfy`
    ///   and resolves to the string below.
    /// - iOS uses the `group.`-prefixed identifier, matching the iOS entitlements.
    static let identifier: String = {
        #if os(macOS)
        return "6Y294JNMJ2.com.avneetsingh.emfy"
        #else
        return "group.com.avneetsingh.emfy"
        #endif
    }()

    /// The shared defaults suite, or `nil` if the container cannot be resolved
    /// (an unentitled process, or a macOS group the signature doesn't grant). A
    /// `nil` return is never fatal: the app falls back to `.standard` and the
    /// extensions fall back to built-in defaults.
    static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
