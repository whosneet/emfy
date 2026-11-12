#if EMFY_DMG
import Foundation
import Testing

/// Pure-logic tests for the GitHub/DMG updater (U1): version comparison, feed
/// decoding and selection, digest handling, the host allowlist, size caps, the mode
/// state machine, the throttle, the first-launch decision, the install-location
/// guard, and the swap-helper script. No network, no filesystem, no real crypto —
/// the feed fixtures are inline JSON. These compile only under the DMG configs
/// (EMFY_DMG); run them with `-configuration Debug-DMG`.
struct UpdateLogicTests {

    // MARK: Fixtures

    private static let goodHex = String(repeating: "a", count: 64)
    private static let otherHex = String(repeating: "b", count: 64)
    private static let current = AppVersion(core: [3, 0, 0], build: 5)

    private func asset(_ name: String, _ url: String, digest: String? = nil, size: Int? = nil) -> UpdateAsset {
        UpdateAsset(name: name, downloadURL: URL(string: url)!, rawDigest: digest, size: size)
    }

    private func release(_ tag: String, draft: Bool = false, pre: Bool = false, assets: [UpdateAsset] = []) -> UpdateRelease {
        UpdateRelease(tag: tag, isDraft: draft, isPrerelease: pre, assets: assets)
    }

    private var dmgInline: UpdateAsset {
        asset("Emfy.dmg", "https://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg",
              digest: "sha256:\(Self.goodHex)")
    }

    // MARK: Version comparison

    @Test func versionParsingAndOrdering() {
        #expect(AppVersion(tag: "3.0.1")! > AppVersion(tag: "3.0.0")!)
        #expect(AppVersion(tag: "v3.1")! > AppVersion(tag: "3.0.9")!)
        #expect(AppVersion(tag: "3.0.0+7")! > AppVersion(tag: "3.0.0+6")!)
        #expect(AppVersion(tag: "3.0.0")! == AppVersion(core: [3, 0, 0], build: nil))
        #expect(!(AppVersion(tag: "3.0.0")! > AppVersion(tag: "3.0.0")!))
        #expect(AppVersion(tag: "10.0.0")! > AppVersion(tag: "9.9.9")!)
    }

    @Test func versionRejectsNonNumericTags() {
        #expect(AppVersion(tag: "beta") == nil)
        #expect(AppVersion(tag: "") == nil)
        #expect(AppVersion(tag: "latest") == nil)
    }

    @Test func versionFromBundleStrings() {
        let v = AppVersion(short: "3.1", build: "6")
        #expect(v.core == [3, 1, 0])
        #expect(v.build == 6)
    }

    // MARK: Digest handling

    @Test func sha256HexExtraction() {
        #expect(dmgInline.sha256Hex == Self.goodHex)
        #expect(asset("x.dmg", "https://github.com/x", digest: "sha256:zzzz").sha256Hex == nil)
        #expect(asset("x.dmg", "https://github.com/x", digest: "md5:\(Self.goodHex)").sha256Hex == nil)
        #expect(asset("x.dmg", "https://github.com/x", digest: nil).sha256Hex == nil)
    }

    @Test func validHex() {
        #expect(UpdateDigest.validHex(Self.goodHex))
        #expect(!UpdateDigest.validHex(String(repeating: "a", count: 63)))
        #expect(!UpdateDigest.validHex(String(repeating: "g", count: 64)))
    }

    // MARK: Host allowlist

    @Test func hostAllowlist() {
        #expect(UpdateHostAllowlist.allows(URL(string: "https://github.com/a")!))
        #expect(UpdateHostAllowlist.allows(URL(string: "https://release-assets.githubusercontent.com/a")!))
        #expect(UpdateHostAllowlist.allows(URL(string: "https://objects.githubusercontent.com/a")!))
        #expect(!UpdateHostAllowlist.allows(URL(string: "http://github.com/a")!))   // not HTTPS
        #expect(!UpdateHostAllowlist.allows(URL(string: "https://evil.example.com/a")!))
    }

    // MARK: Feed decode + size caps

    @Test func decodeRejectsOversizeFeed() {
        let big = Data(count: UpdateLimits.feedResponseCap + 1)
        #expect(throws: UpdateError.feedTooLarge(UpdateLimits.feedResponseCap + 1)) {
            try UpdateFeed.decode(big)
        }
    }

    @Test func decodeRejectsMalformedJSON() {
        #expect(throws: UpdateError.malformedFeed) {
            try UpdateFeed.decode(Data("{not an array}".utf8))
        }
    }

    @Test func decodeParsesReleasesAndAssets() throws {
        let json = """
        [
          {"tag_name":"v3.0.1","draft":false,"prerelease":false,
           "assets":[{"name":"Emfy.dmg","browser_download_url":"https://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg","size":1234,"digest":"sha256:\(Self.goodHex)"}]},
          {"tag_name":"v2.9.0","draft":false,"prerelease":false,"assets":[]}
        ]
        """
        let releases = try UpdateFeed.decode(Data(json.utf8))
        #expect(releases.count == 2)
        #expect(releases[0].dmgAsset?.sha256Hex == Self.goodHex)
        #expect(releases[0].dmgAsset?.size == 1234)
    }

    // MARK: Selection

    @Test func selectsNewerStableWithInlineDigest() {
        let candidate = UpdateFeed.selectUpdate(
            from: [release("v3.0.1", assets: [dmgInline])],
            includingBeta: false, current: Self.current)
        #expect(candidate?.release.tag == "v3.0.1")
        #expect(candidate?.digest == .inline(hex: Self.goodHex))
    }

    @Test func rejectsOlderOnly() {
        let candidate = UpdateFeed.selectUpdate(
            from: [release("v2.9.0", assets: [dmgInline])],
            includingBeta: false, current: Self.current)
        #expect(candidate == nil)
    }

    @Test func skipsDraft() {
        let draft = release("v9.9.9", draft: true, assets: [dmgInline])
        #expect(UpdateFeed.selectUpdate(from: [draft], includingBeta: true, current: Self.current) == nil)
    }

    @Test func prereleaseGatedByBetaFlag() {
        let pre = release("v3.1.0", pre: true, assets: [
            asset("Emfy.dmg", "https://github.com/whosneet/emfy/releases/download/v3.1.0/Emfy.dmg", digest: "sha256:\(Self.goodHex)")
        ])
        #expect(UpdateFeed.selectUpdate(from: [pre], includingBeta: false, current: Self.current) == nil)
        #expect(UpdateFeed.selectUpdate(from: [pre], includingBeta: true, current: Self.current)?.release.tag == "v3.1.0")
    }

    @Test func rejectsForeignHostAsset() {
        let foreign = release("v3.0.1", assets: [
            asset("Emfy.dmg", "https://evil.example.com/Emfy.dmg", digest: "sha256:\(Self.goodHex)")
        ])
        #expect(UpdateFeed.selectUpdate(from: [foreign], includingBeta: false, current: Self.current) == nil)
    }

    @Test func rejectsNonHTTPSAsset() {
        let insecure = release("v3.0.1", assets: [
            asset("Emfy.dmg", "http://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg", digest: "sha256:\(Self.goodHex)")
        ])
        #expect(UpdateFeed.selectUpdate(from: [insecure], includingBeta: false, current: Self.current) == nil)
    }

    @Test func hardSkipsWhenDigestMissing() {
        let noDigest = release("v3.0.1", assets: [
            asset("Emfy.dmg", "https://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg")
        ])
        #expect(UpdateFeed.selectUpdate(from: [noDigest], includingBeta: false, current: Self.current) == nil)
    }

    @Test func resolvesSiblingDigest() {
        let siblingURL = "https://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg.sha256"
        let withSibling = release("v3.0.1", assets: [
            asset("Emfy.dmg", "https://github.com/whosneet/emfy/releases/download/v3.0.1/Emfy.dmg"),
            asset("Emfy.dmg.sha256", siblingURL),
        ])
        let candidate = UpdateFeed.selectUpdate(from: [withSibling], includingBeta: false, current: Self.current)
        #expect(candidate?.digest == .sibling(url: URL(string: siblingURL)!))
    }

    @Test func highestVersionWins() {
        let releases = [
            release("v3.0.1", assets: [dmgInline]),
            release("v3.2.0", assets: [asset("Emfy.dmg", "https://github.com/whosneet/emfy/releases/download/v3.2.0/Emfy.dmg", digest: "sha256:\(Self.otherHex)")]),
        ]
        #expect(UpdateFeed.selectUpdate(from: releases, includingBeta: false, current: Self.current)?.release.tag == "v3.2.0")
    }

    // MARK: Mode state machine

    @Test func policyChecksAutomatically() {
        #expect(!UpdatePolicy.checksAutomatically(.off))
        #expect(UpdatePolicy.checksAutomatically(.notifyOnLaunch))
        #expect(UpdatePolicy.checksAutomatically(.autoDownload))
        #expect(UpdatePolicy.checksAutomatically(.autoUpdate))
    }

    @Test func policyActionAfterFound() {
        #expect(UpdatePolicy.actionAfterFound(.off) == .none)
        #expect(UpdatePolicy.actionAfterFound(.notifyOnLaunch) == .notify)
        #expect(UpdatePolicy.actionAfterFound(.autoDownload) == .downloadAndOffer)
        #expect(UpdatePolicy.actionAfterFound(.autoUpdate) == .downloadAndStageSilently)
    }

    @Test func policySwapOnQuit() {
        #expect(UpdatePolicy.swapOnQuit(mode: .autoUpdate, userRequestedInstall: false, hasStaged: true))
        #expect(!UpdatePolicy.swapOnQuit(mode: .autoUpdate, userRequestedInstall: false, hasStaged: false))
        #expect(!UpdatePolicy.swapOnQuit(mode: .autoDownload, userRequestedInstall: false, hasStaged: true))
        #expect(UpdatePolicy.swapOnQuit(mode: .autoDownload, userRequestedInstall: true, hasStaged: true))
        #expect(UpdatePolicy.swapOnQuit(mode: .notifyOnLaunch, userRequestedInstall: true, hasStaged: true))
        #expect(!UpdatePolicy.swapOnQuit(mode: .off, userRequestedInstall: true, hasStaged: true))
    }

    // MARK: Throttle

    @Test func throttle() {
        let now = Date()
        #expect(UpdateThrottle.shouldCheck(now: now, lastCheck: nil))
        #expect(!UpdateThrottle.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-3600)))
        #expect(UpdateThrottle.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-25 * 3600)))
    }

    // MARK: First launch

    @Test func firstLaunchPrompt() {
        #expect(UpdateFirstLaunch.shouldPrompt(hasChosenMode: false))
        #expect(!UpdateFirstLaunch.shouldPrompt(hasChosenMode: true))
        #expect(UpdateFirstLaunch.defaultMode == .notifyOnLaunch)
    }

    // MARK: Install-location guard

    @Test func installGuardRefusals() {
        #expect(UpdateInstallGuard.check(isWritable: true, isOnReadOnlyVolume: false, isTranslocated: false) == nil)
        #expect(UpdateInstallGuard.check(isWritable: true, isOnReadOnlyVolume: false, isTranslocated: true) == .translocated)
        #expect(UpdateInstallGuard.check(isWritable: true, isOnReadOnlyVolume: true, isTranslocated: false) == .readOnlyVolume)
        #expect(UpdateInstallGuard.check(isWritable: false, isOnReadOnlyVolume: false, isTranslocated: false) == .targetNotWritable)
        // Translocation takes precedence over the others.
        #expect(UpdateInstallGuard.check(isWritable: false, isOnReadOnlyVolume: true, isTranslocated: true) == .translocated)
    }

    // MARK: Swap script

    @Test func swapScriptQuotesPlainPaths() {
        let script = UpdateSwapScript.script(.init(
            pid: 4242,
            stagedApp: "/Library/Application Support/Emfy/Updates/staged/Emfy.app",
            targetApp: "/Applications/Emfy.app",
            backupPath: "/Applications/.Emfy.app.backup-1"))
        #expect(script.contains("kill -0 4242"))
        #expect(script.contains("'/Applications/Emfy.app'"))
        #expect(script.contains("'/Library/Application Support/Emfy/Updates/staged/Emfy.app'"))
        #expect(script.contains("/bin/mv '/Applications/Emfy.app' '/Applications/.Emfy.app.backup-1'"))
        #expect(script.contains("/usr/bin/ditto"))
        #expect(script.contains("/usr/bin/open '/Applications/Emfy.app'"))
        // The restore branch exists.
        #expect(script.contains("/bin/mv '/Applications/.Emfy.app.backup-1' '/Applications/Emfy.app'"))
    }

    @Test func swapScriptEscapesSingleQuotes() {
        let tricky = "/Users/x/Bob's Apps/Emfy.app"
        let script = UpdateSwapScript.script(.init(
            pid: 1, stagedApp: tricky, targetApp: tricky, backupPath: tricky + ".bak"))
        // A single quote becomes '\'' — no bare quote can terminate the string early.
        #expect(script.contains("/Users/x/Bob'\\''s Apps/Emfy.app"))
        #expect(!script.contains("Bob's Apps"))
    }

    @Test func swapScriptQuoting() {
        #expect(UpdateSwapScript.shQuote("a b") == "'a b'")
        #expect(UpdateSwapScript.shQuote("a'b") == "'a'\\''b'")
        #expect(UpdateSwapScript.shQuote("$(rm -rf /)") == "'$(rm -rf /)'")
    }
}
#endif
