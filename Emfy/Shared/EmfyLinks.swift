import Foundation

/// Emfy's outbound links, shared by every surface that offers them: the macOS Help
/// menu and Settings, and the iOS More menu and Settings (C3b). One declaration so
/// the repository URL and the support address never drift between platforms.
enum EmfyLinks {
    /// The public repository, used as the developer documentation link.
    static let gitHub = URL(string: "https://github.com/whosneet/emfy")

    /// A pre-addressed support email. Built with `URLComponents` so the subject is
    /// percent-encoded correctly.
    static var contact: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@arrley.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "Emfy support")]
        return components.url
    }
}
