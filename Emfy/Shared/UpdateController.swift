#if EMFY_DMG && os(macOS)
import AppKit
import Foundation
import Observation

/// The stateful orchestrator of Emfy's own updater (U1, GitHub/DMG build only). It
/// owns the mode, the throttle, and the check → download → verify → stage → swap
/// pipeline, delegating every decision to the pure `UpdatePolicy`/`UpdateThrottle`/
/// `UpdateFirstLaunch` helpers and every side effect to injected transports and the
/// verifier (so tests drive the logic without a network or a real signed build).
@MainActor
@Observable
final class UpdateController {
    /// The coarse UI phase. Candidate/staged detail lives in non-published fields.
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case verifying
        case readyToInstall(version: String)
        case failed(UpdateError)
    }

    static let shared = UpdateController()

    private(set) var phase: Phase = .idle
    var mode: UpdateMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            defaults.set(true, forKey: Keys.hasChosenMode)
        }
    }
    var includeBeta: Bool {
        didSet { defaults.set(includeBeta, forKey: Keys.includeBeta) }
    }
    private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked?.timeIntervalSince1970 ?? 0, forKey: Keys.lastChecked) }
    }

    /// The running app's marketing version string, for the Settings "current version" row.
    let currentVersionString: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let feed: UpdateFeedProviding
    @ObservationIgnored private let fetcher: UpdateAssetFetching
    @ObservationIgnored private let verifier: UpdateVerifying
    @ObservationIgnored private let current: AppVersion
    @ObservationIgnored private let bundleID: String

    @ObservationIgnored private var pendingCandidate: UpdateCandidate?
    @ObservationIgnored private var stagedAppURL: URL?
    @ObservationIgnored private var mountToDetach: URL?
    /// Set when the user presses "Restart to Update" (autoDownload / notify paths).
    @ObservationIgnored private var userRequestedInstall = false
    @ObservationIgnored private var didLaunchSwap = false

    init(
        defaults: UserDefaults = .standard,
        feed: UpdateFeedProviding = URLSessionUpdateTransport(),
        fetcher: UpdateAssetFetching = URLSessionUpdateTransport(),
        verifier: UpdateVerifying = SecurityUpdateVerifier()
    ) {
        self.defaults = defaults
        self.feed = feed
        self.fetcher = fetcher
        self.verifier = verifier
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.current = AppVersion(short: short, build: build)
        self.currentVersionString = build.map { "\(short) (\($0))" } ?? short
        self.bundleID = Bundle.main.bundleIdentifier ?? "com.avneetsingh.emfy"
        self.mode = UpdateMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? UpdateFirstLaunch.defaultMode
        self.includeBeta = defaults.bool(forKey: Keys.includeBeta)
        let t = defaults.double(forKey: Keys.lastChecked)
        self.lastChecked = t > 0 ? Date(timeIntervalSince1970: t) : nil

        #if DEBUG
        seedDebugStateIfRequested()
        #endif
    }

    // MARK: First launch

    /// Whether the one-time "Keep Emfy up to date?" sheet should be shown.
    var shouldPromptFirstLaunch: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-EmfyDebugFirstLaunchUpdates") { return true }
        #endif
        return UpdateFirstLaunch.shouldPrompt(hasChosenMode: defaults.bool(forKey: Keys.hasChosenMode))
    }

    /// Persists the user's first-launch choice; the sheet never shows again.
    func chooseMode(_ chosen: UpdateMode) {
        mode = chosen   // didSet records the choice + hasChosenMode
    }

    // MARK: Checking

    /// The launch/timer entry point. Checks only when the mode checks automatically
    /// and the 24h throttle allows it.
    func startAutomaticCheckIfDue(now: Date = Date()) {
        guard UpdatePolicy.checksAutomatically(mode),
              UpdateThrottle.shouldCheck(now: now, lastCheck: lastChecked) else { return }
        Task { await check(automatic: true) }
    }

    /// "Check Now" from Settings or the menu — always runs, ignoring the throttle.
    func checkNow() {
        Task { await check(automatic: false) }
    }

    private func check(automatic: Bool) async {
        phase = .checking
        lastChecked = Date()
        do {
            let data = try await feed.fetchFeed()
            let releases = try UpdateFeed.decode(data)
            guard let candidate = UpdateFeed.selectUpdate(
                from: releases, includingBeta: includeBeta, current: current) else {
                phase = .upToDate
                return
            }
            pendingCandidate = candidate
            let versionText = candidate.version.map(String.init(describing:)) ?? candidate.release.tag
            switch UpdatePolicy.actionAfterFound(mode) {
            case .notify, .none:
                phase = .available(version: versionText)
            case .downloadAndOffer, .downloadAndStageSilently:
                await downloadVerifyStage(candidate)
            }
        } catch let error as UpdateError {
            phase = .failed(error)
        } catch {
            phase = .failed(.networkFailed(error.localizedDescription))
        }
    }

    /// The user chose to download an update surfaced by `notify`.
    func downloadNow() {
        guard let candidate = pendingCandidate else { return }
        Task { await downloadVerifyStage(candidate) }
    }

    private func downloadVerifyStage(_ candidate: UpdateCandidate) async {
        phase = .downloading
        var downloaded: URL?
        do {
            let hex = try await resolveDigest(candidate)
            let dmg = try await fetcher.downloadAsset(candidate.dmg.downloadURL, maxBytes: UpdateLimits.downloadCap)
            downloaded = dmg
            phase = .verifying
            let verifier = self.verifier
            let bundleID = self.bundleID
            let current = self.current
            let verified = try await Task.detached {
                try verifier.verify(dmg: dmg, expectedSHA256: hex, expectedBundleID: bundleID, current: current)
            }.value
            // Stage a copy out of the mount, then detach.
            let staged = try UpdateStaging.stage(verifiedApp: verified.appURL)
            verifier.detach(mountPoint: verified.mountPoint)
            try? FileManager.default.removeItem(at: dmg)
            stagedAppURL = staged
            phase = .readyToInstall(version: String(describing: verified.version))
        } catch let error as UpdateError {
            if let d = downloaded { try? FileManager.default.removeItem(at: d) }
            phase = .failed(error)
        } catch {
            if let d = downloaded { try? FileManager.default.removeItem(at: d) }
            phase = .failed(.networkFailed(error.localizedDescription))
        }
    }

    private func resolveDigest(_ candidate: UpdateCandidate) async throws -> String {
        switch candidate.digest {
        case .inline(let hex):
            return hex
        case .sibling(let url):
            let data = try await fetcher.fetchSmall(url, maxBytes: UpdateLimits.digestAssetCap)
            let text = String(decoding: data, as: UTF8.self)
            // A .sha256 file is "<hex>  <filename>" or just "<hex>".
            let hex = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? ""
            guard UpdateDigest.validHex(hex) else { throw UpdateError.digestUnavailable }
            return hex.lowercased()
        }
    }

    // MARK: Install on quit

    /// The user pressed "Restart to Update": record intent and quit, so the swap runs.
    func restartToUpdate() {
        userRequestedInstall = true
        NSApp.terminate(nil)
    }

    /// Called from `applicationWillTerminate`. If a verified update is staged and the
    /// mode/intent call for it, and the install location is replaceable, writes the
    /// detached swap helper and launches it. Refuses a translocated / read-only /
    /// non-writable location.
    func installOnQuitIfNeeded() {
        guard !didLaunchSwap else { return }
        guard let staged = stagedAppURL,
              UpdatePolicy.swapOnQuit(mode: mode, userRequestedInstall: userRequestedInstall, hasStaged: true)
        else { return }

        let bundleURL = Bundle.main.bundleURL
        let facts = installLocationFacts(for: bundleURL)
        if UpdateInstallGuard.check(
            isWritable: facts.writable,
            isOnReadOnlyVolume: facts.readOnly,
            isTranslocated: facts.translocated) != nil {
            return   // the UI already surfaced the refusal; never touch the bundle
        }
        didLaunchSwap = true
        launchSwapHelper(staged: staged, target: bundleURL)
    }

    private struct LocationFacts { let writable: Bool; let readOnly: Bool; let translocated: Bool }

    private func installLocationFacts(for bundleURL: URL) -> LocationFacts {
        let path = bundleURL.path
        let writable = FileManager.default.isWritableFile(atPath: path)
            && FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let translocated = path.contains("/AppTranslocation/")
        return LocationFacts(writable: writable, readOnly: readOnly, translocated: translocated)
    }

    private func launchSwapHelper(staged: URL, target: URL) {
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).backup-\(UUID().uuidString)")
        let script = UpdateSwapScript.script(.init(
            pid: ProcessInfo.processInfo.processIdentifier,
            stagedApp: staged.path,
            targetApp: target.path,
            backupPath: backup.path))
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUpdateSwap-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()   // detached; it waits for this PID to exit
        } catch {
            // Nothing is installed on failure; the staged copy remains for a retry.
        }
    }

    #if DEBUG
    /// Seeds a synthetic "available" state for the Settings screenshot (U1
    /// verification b), driven by `-EmfyDebugUpdateAvailable <version>`. No network.
    private func seedDebugStateIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-EmfyDebugUpdateAvailable"), i + 1 < args.count else { return }
        let version = args[i + 1]
        lastChecked = Date()
        phase = .available(version: version)
    }
    #endif

    private enum Keys {
        static let mode = "updates.mode"
        static let includeBeta = "updates.includeBeta"
        static let lastChecked = "updates.lastChecked"
        static let hasChosenMode = "updates.hasChosenMode"
    }
}
#endif
