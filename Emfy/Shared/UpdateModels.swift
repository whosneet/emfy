#if EMFY_DMG
import Foundation

/// The GitHub Releases feed model and the §8 guard rails around it (U1). Foundation
/// only, no UI, no network — the fetch lives in `UpdateDownloader`; this file is the
/// pure, testable decoding, host allowlist, size caps and update-selection logic.

/// The hard limits a hostile or oversized feed/asset must not exceed (§8).
enum UpdateLimits {
    /// Largest release-feed JSON response accepted (bytes). A real feed is a few KB.
    static let feedResponseCap = 2 * 1024 * 1024
    /// Largest DMG download accepted (bytes).
    static let downloadCap = 500 * 1024 * 1024
    /// Largest sibling `.sha256` asset accepted (bytes) — it holds one hex digest.
    static let digestAssetCap = 1024
    /// Most releases decoded from one feed page.
    static let maxReleases = 100
    /// Most assets decoded per release.
    static let maxAssetsPerRelease = 50
}

/// The hosts an asset download URL may use. Any other host is rejected before a
/// single byte is fetched (§8). GitHub serves release assets from
/// `release-assets.githubusercontent.com` today and `objects.githubusercontent.com`
/// historically; the API itself is on `api.github.com` / `github.com`.
enum UpdateHostAllowlist {
    static let hosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// Whether `url` is HTTPS and on an allowlisted host (case-insensitive).
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}

/// One downloadable asset on a release.
struct UpdateAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    /// The GitHub `digest` field, "sha256:<hex>", when the API provides it.
    let rawDigest: String?
    let size: Int?

    /// The lower-cased 64-hex SHA-256 from `rawDigest`, or `nil` when absent or
    /// malformed. Only an `sha256:` digest of exactly 64 hex chars is accepted.
    var sha256Hex: String? {
        guard let raw = rawDigest?.lowercased() else { return nil }
        guard raw.hasPrefix("sha256:") else { return nil }
        let hex = String(raw.dropFirst("sha256:".count))
        return UpdateDigest.validHex(hex) ? hex : nil
    }

    var isDMG: Bool { name.lowercased().hasSuffix(".dmg") }
    var isSHA256Sibling: Bool { name.lowercased().hasSuffix(".sha256") }
}

/// One release from the feed.
struct UpdateRelease: Equatable, Sendable {
    let tag: String
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [UpdateAsset]

    var version: AppVersion? { AppVersion(tag: tag) }
    var dmgAsset: UpdateAsset? { assets.first { $0.isDMG } }
}

/// How the required SHA-256 for a chosen DMG is obtained.
enum UpdateDigestSource: Equatable, Sendable {
    /// Taken straight from the asset's `digest` field (no extra fetch).
    case inline(hex: String)
    /// Must be fetched from a sibling `<asset>.sha256` asset (small, capped).
    case sibling(url: URL)
}

/// A chosen, installable update: the release, its DMG asset, and where its
/// required digest comes from. Produced only when every §8 precondition holds.
struct UpdateCandidate: Equatable, Sendable {
    let release: UpdateRelease
    let dmg: UpdateAsset
    let digest: UpdateDigestSource
    var version: AppVersion? { release.version }
}

/// Every way the update pipeline can fail. Each is typed, logged, and leaves
/// nothing installed; a download is always deleted on failure (U1 §8).
enum UpdateError: Error, Equatable, Sendable {
    case feedTooLarge(Int)
    case malformedFeed
    case networkFailed(String)
    case notHTTPS
    case hostNotAllowed(String)
    case downloadTooLarge(Int)
    case digestUnavailable
    case digestMismatch
    case mountFailed(String)
    case appNotFoundInImage
    case signatureInvalid(String)
    case notNotarized
    case bundleIdentifierMismatch
    case notNewer
    case targetNotWritable
    case translocated
    case readOnlyVolume
    case stagingFailed(String)

    /// A short, plain-language summary for the UI; the technical detail stays in logs.
    var userMessage: String {
        switch self {
        case .feedTooLarge, .malformedFeed, .networkFailed:
            return "Emfy couldn’t check for updates."
        case .notHTTPS, .hostNotAllowed, .downloadTooLarge,
             .digestUnavailable, .digestMismatch, .signatureInvalid,
             .notNotarized, .bundleIdentifierMismatch:
            return "The update couldn’t be verified and was not installed."
        case .notNewer:
            return "Emfy is already up to date."
        case .appNotFoundInImage, .mountFailed, .stagingFailed:
            return "The update couldn’t be prepared."
        case .targetNotWritable, .translocated, .readOnlyVolume:
            return "Emfy can’t update itself from this location. Move Emfy to Applications and try again."
        }
    }
}

enum UpdateDigest {
    /// Whether `hex` is exactly 64 lower/upper hex characters (a SHA-256).
    static func validHex(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
    }
}

enum UpdateFeed {
    /// Decodes a GitHub Releases API JSON array defensively, bounded by the §8 caps.
    /// Unknown fields are ignored; a malformed top level throws; individual malformed
    /// assets are skipped rather than failing the whole feed.
    static func decode(_ data: Data) throws -> [UpdateRelease] {
        guard data.count <= UpdateLimits.feedResponseCap else {
            throw UpdateError.feedTooLarge(data.count)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let array = root as? [[String: Any]] else {
            throw UpdateError.malformedFeed
        }
        var releases: [UpdateRelease] = []
        for obj in array.prefix(UpdateLimits.maxReleases) {
            guard let tag = obj["tag_name"] as? String else { continue }
            let draft = (obj["draft"] as? Bool) ?? false
            let prerelease = (obj["prerelease"] as? Bool) ?? false
            var assets: [UpdateAsset] = []
            if let rawAssets = obj["assets"] as? [[String: Any]] {
                for a in rawAssets.prefix(UpdateLimits.maxAssetsPerRelease) {
                    guard let name = a["name"] as? String,
                          let urlString = a["browser_download_url"] as? String,
                          let url = URL(string: urlString) else { continue }
                    let size = a["size"] as? Int
                    let digest = a["digest"] as? String
                    assets.append(UpdateAsset(name: name, downloadURL: url, rawDigest: digest, size: size))
                }
            }
            releases.append(UpdateRelease(tag: tag, isDraft: draft, isPrerelease: prerelease, assets: assets))
        }
        return releases
    }

    /// Selects the update to install, or `nil` when none qualifies. Rules (U1 §10.1):
    /// skip drafts always; skip pre-releases unless `includingBeta`; require a newer
    /// version than `current`; require a `.dmg` asset on an allowlisted HTTPS host; and
    /// require a resolvable SHA-256 (inline digest, else a sibling `.sha256` on an
    /// allowlisted host). The highest qualifying version wins.
    static func selectUpdate(
        from releases: [UpdateRelease],
        includingBeta: Bool,
        current: AppVersion
    ) -> UpdateCandidate? {
        let eligible = releases
            .filter { !$0.isDraft }
            .filter { includingBeta || !$0.isPrerelease }
            .compactMap { release -> (UpdateRelease, AppVersion)? in
                guard let v = release.version, v > current else { return nil }
                return (release, v)
            }
            .sorted { $0.1 > $1.1 }

        for (release, _) in eligible {
            guard let dmg = release.dmgAsset, UpdateHostAllowlist.allows(dmg.downloadURL) else { continue }
            if let hex = dmg.sha256Hex {
                return UpdateCandidate(release: release, dmg: dmg, digest: .inline(hex: hex))
            }
            if let sibling = release.assets.first(where: {
                $0.isSHA256Sibling && $0.name.lowercased().hasPrefix(dmg.name.lowercased())
            }), UpdateHostAllowlist.allows(sibling.downloadURL) {
                return UpdateCandidate(release: release, dmg: dmg, digest: .sibling(url: sibling.downloadURL))
            }
            // A newer DMG with no resolvable digest is a hard skip, not a silent install.
            continue
        }
        return nil
    }
}
#endif
