#if EMFY_DMG
import Foundation

/// Networking and staging for the updater (U1). Everything the controller touches is
/// behind a protocol so tests inject fakes and NEVER hit the network. Real transports
/// enforce HTTPS, the host allowlist and the size caps before and after transfer (§8).

/// The GitHub Releases feed location.
enum GitHubReleases {
    static let feedURL = URL(string: "https://api.github.com/repos/whosneet/emfy/releases")!
    static let accept = "application/vnd.github+json"
}

/// Fetches the release feed JSON. Injected so tests feed fixtures in.
protocol UpdateFeedProviding: Sendable {
    func fetchFeed() async throws -> Data
}

/// Downloads an asset to a local file and fetches small sidecars (the `.sha256`).
/// Injected so tests never download anything.
protocol UpdateAssetFetching: Sendable {
    /// Downloads `url` to a temporary file, failing if it exceeds `maxBytes`.
    func downloadAsset(_ url: URL, maxBytes: Int) async throws -> URL
    /// Fetches a small asset's bytes (e.g. a sibling digest), capped at `maxBytes`.
    func fetchSmall(_ url: URL, maxBytes: Int) async throws -> Data
}

/// The real URLSession-backed transport. Rejects non-HTTPS / off-allowlist URLs up
/// front, caps the feed response, and verifies the downloaded file size against the
/// cap, deleting an oversize download.
struct URLSessionUpdateTransport: UpdateFeedProviding, UpdateAssetFetching {
    var session: URLSession = .shared

    func fetchFeed() async throws -> Data {
        var request = URLRequest(url: GitHubReleases.feedURL)
        request.setValue(GitHubReleases.accept, forHTTPHeaderField: "Accept")
        guard UpdateHostAllowlist.allows(GitHubReleases.feedURL) else {
            throw UpdateError.hostNotAllowed(GitHubReleases.feedURL.host ?? "")
        }
        let (data, response) = try await load(request)
        try checkContentLength(response, cap: UpdateLimits.feedResponseCap)
        guard data.count <= UpdateLimits.feedResponseCap else {
            throw UpdateError.feedTooLarge(data.count)
        }
        return data
    }

    func fetchSmall(_ url: URL, maxBytes: Int) async throws -> Data {
        try requireAllowed(url)
        let (data, response) = try await load(URLRequest(url: url))
        try checkContentLength(response, cap: maxBytes)
        guard data.count <= maxBytes else { throw UpdateError.downloadTooLarge(data.count) }
        return data
    }

    func downloadAsset(_ url: URL, maxBytes: Int) async throws -> URL {
        try requireAllowed(url)
        let (temp, response) = try await session.download(from: url)
        try? checkContentLength(response, cap: maxBytes)
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? nil
        if let size, size > maxBytes {
            try? FileManager.default.removeItem(at: temp)
            throw UpdateError.downloadTooLarge(size)
        }
        return temp
    }

    private func requireAllowed(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else { throw UpdateError.notHTTPS }
        guard UpdateHostAllowlist.allows(url) else { throw UpdateError.hostNotAllowed(url.host ?? "") }
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw UpdateError.networkFailed(error.localizedDescription) }
    }

    private func checkContentLength(_ response: URLResponse, cap: Int) throws {
        if response.expectedContentLength > 0, response.expectedContentLength > Int64(cap) {
            throw UpdateError.downloadTooLarge(Int(clamping: response.expectedContentLength))
        }
    }
}

/// Stages a verified app bundle for the swap-on-quit helper, under
/// `~/Library/Application Support/Emfy/Updates/staged/`.
enum UpdateStaging {
    static func baseDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Emfy/Updates", isDirectory: true)
    }

    static func stagedDirectory() throws -> URL {
        try baseDirectory().appendingPathComponent("staged", isDirectory: true)
    }

    /// Copies the verified app into the staged directory and returns its path. A
    /// previous staged copy is cleared first so staging is idempotent.
    static func stage(verifiedApp: URL) throws -> URL {
        let staged = try stagedDirectory()
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let dest = staged.appendingPathComponent("Emfy.app", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: verifiedApp, to: dest)
        } catch {
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
        return dest
    }
}
#endif
