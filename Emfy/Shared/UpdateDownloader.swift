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
        // A DEDICATED ephemeral session with a resource timeout (N-1): never the shared
        // session, so a stalled or runaway multi-hundred-MB download can't wedge the
        // app's shared connections and is bounded in total time. Invalidated on exit.
        let downloadSession = Self.makeDownloadSession()
        defer { downloadSession.finishTasksAndInvalidate() }

        // A STREAMING size cap (N-1): the delegate cancels the task the instant the
        // bytes written — or the server's declared Content-Length — exceed the cap, so
        // a hostile asset never lands a full oversize file on disk first.
        let capDelegate = CappedDownloadDelegate(maxBytes: maxBytes)
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await downloadSession.download(from: url, delegate: capDelegate)
        } catch {
            if capDelegate.didExceed { throw UpdateError.downloadTooLarge(maxBytes) }
            throw UpdateError.networkFailed(error.localizedDescription)
        }
        // A Content-Length check that THROWS when the declared size is over the cap
        // (N-1): the old `try?` swallowed it. Belt-and-braces alongside the streaming cap.
        try checkContentLength(response, cap: maxBytes)
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? nil
        if let size, size > maxBytes {
            try? FileManager.default.removeItem(at: temp)
            throw UpdateError.downloadTooLarge(size)
        }
        return temp
    }

    /// A dedicated ephemeral download session: a bounded total-resource timeout, no
    /// cache, no cookies (N-1). Separate from `session` (the feed fetcher) and never
    /// `.shared`.
    static func makeDownloadSession(resourceTimeout: TimeInterval = 600) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
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

/// Cancels a download task the moment it exceeds the cap — either by bytes actually
/// written or by the server's declared total — so an oversize asset never fully lands
/// on disk (N-1). Thread-safe single flag; `didExceed` lets the caller map the
/// resulting cancellation to `.downloadTooLarge` rather than a generic network error.
final class CappedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var exceeded = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    var didExceed: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    private func markExceeded() {
        lock.lock(); exceeded = true; lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(maxBytes) || totalBytesExpectedToWrite > Int64(maxBytes) {
            markExceeded()
            downloadTask.cancel()
        }
    }

    // Required by the protocol; the async `download(from:delegate:)` returns the file.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
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

    /// Removes a stale staged bundle and any leftover swap-helper scripts at launch
    /// (ST5). Staging and the swap-on-quit install both belong to a single session:
    /// anything left under `Updates/staged` or `Updates/helper` on a fresh launch is
    /// from a prior session that already installed or abandoned the update, so it is
    /// never the in-flight install (which is staged and swapped within one run). Safe
    /// to call off the main thread; best-effort.
    static func cleanupStaleStaging() {
        guard let base = try? baseDirectory() else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("staged", isDirectory: true))
        try? FileManager.default.removeItem(at: base.appendingPathComponent("helper", isDirectory: true))
    }

    /// The private directory the swap helper script is written into, created 0700 so
    /// no other user can read or replace the script between write and launch.
    static func helperDirectory() throws -> URL {
        let dir = try baseDirectory().appendingPathComponent("helper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Copies the verified app into the staged directory and returns its path. A
    /// previous staged copy is cleared first so staging is idempotent. Uses `ditto`
    /// (not `FileManager.copyItem`) so symlinks, extended attributes and the code
    /// signature are preserved byte-for-byte — the caller re-verifies the staged copy
    /// regardless (TOCTOU guard).
    static func stage(verifiedApp: URL) async throws -> URL {
        let staged = try stagedDirectory()
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(
            at: staged, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let dest = staged.appendingPathComponent("Emfy.app", isDirectory: true)
        #if os(macOS)
        do {
            let result = try await UpdateProcess.run("/usr/bin/ditto", [verifiedApp.path, dest.path], timeout: 120)
            guard result.exitCode == 0 else { throw UpdateError.stagingFailed(result.stderr) }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
        #else
        do {
            try FileManager.default.copyItem(at: verifiedApp, to: dest)
        } catch {
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
        #endif
        return dest
    }
}
#endif
