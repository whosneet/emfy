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
    /// The single in-flight pipeline task (C-4): the re-entrancy guard. Only one
    /// check/download/verify runs at a time; a second request while busy is ignored.
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// Set true once the staged bundle has passed verification BEFORE quit (C-3), so
    /// `installOnQuitIfNeeded` at terminate does only a fast location check and never a
    /// blocking codesign/spctl pass.
    @ObservationIgnored private var installApproved = false

    /// Whether a check/download/verify is in flight (C-4). The UI disables
    /// "Check for Updates…" / "Check Now" and "Download" while this is true.
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying: return true
        default: return false
        }
    }

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
        guard !isBusy,   // C-4: never start a second pipeline over a running one
              UpdatePolicy.checksAutomatically(mode),
              UpdateThrottle.shouldCheck(now: now, lastCheck: lastChecked) else { return }
        pipelineTask = Task { await check(automatic: true) }
    }

    /// "Check Now" from Settings or the menu — always runs, ignoring the throttle, but
    /// never while a check/download is already in flight (C-4).
    func checkNow() {
        guard !isBusy else { return }
        pipelineTask = Task { await check(automatic: false) }
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
        guard !isBusy, let candidate = pendingCandidate else { return }   // C-4
        pipelineTask = Task { await downloadVerifyStage(candidate) }
    }

    private func downloadVerifyStage(_ candidate: UpdateCandidate) async {
        phase = .downloading
        installApproved = false
        var downloaded: URL?
        do {
            let hex = try await resolveDigest(candidate)
            let dmg = try await fetcher.downloadAsset(candidate.dmg.downloadURL, maxBytes: UpdateLimits.downloadCap)
            downloaded = dmg
            phase = .verifying
            let verifier = self.verifier
            let bundleID = self.bundleID
            let current = self.current
            // (C-3) Verify, stage (ditto) and detach (hdiutil) ALL off the main actor —
            // the streaming SHA-256, spctl and the copy are CPU/IO heavy and must never
            // block the UI. The verifier methods are async (continuation-based), so the
            // detached work never blocks a cooperative thread on a semaphore (C-5).
            let result: (staged: URL, version: AppVersion) = try await Task.detached {
                let verified = try await verifier.verify(
                    dmg: dmg, expectedSHA256: hex, expectedBundleID: bundleID, current: current)
                let copy: URL
                do {
                    copy = try await UpdateStaging.stage(verifiedApp: verified.appURL)
                } catch {
                    await verifier.detach(mountPoint: verified.mountPoint)
                    throw error
                }
                await verifier.detach(mountPoint: verified.mountPoint)
                // TOCTOU guard: re-verify the STAGED copy (now on a user-writable path).
                // This is the "verification done before quit" (C-3) for the silent path.
                do {
                    try await verifier.verifyStagedBundle(
                        appURL: copy, expectedBundleID: bundleID, current: current)
                } catch {
                    try? FileManager.default.removeItem(at: copy)
                    throw error
                }
                return (copy, verified.version)
            }.value
            try? FileManager.default.removeItem(at: dmg)
            stagedAppURL = result.staged
            installApproved = true
            phase = .readyToInstall(version: String(describing: result.version))
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

    /// The user pressed "Restart to Update": re-verify the staged bundle BEFORE quit
    /// (C-3), off the main actor, then record intent and quit so the swap runs. A
    /// failed re-verification deletes the staged copy and aborts — nothing is installed.
    /// The re-verify happens here, not at terminate, so quitting never blocks on
    /// codesign/spctl.
    func restartToUpdate() {
        guard !isBusy, let staged = stagedAppURL else { return }
        let verifier = self.verifier
        let bundleID = self.bundleID
        let current = self.current
        pipelineTask = Task {
            phase = .verifying
            do {
                try await Task.detached {
                    try await verifier.verifyStagedBundle(
                        appURL: staged, expectedBundleID: bundleID, current: current)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: staged)
                stagedAppURL = nil
                installApproved = false
                phase = .failed((error as? UpdateError) ?? .signatureInvalid("staged re-verification failed"))
                return
            }
            installApproved = true
            userRequestedInstall = true
            phase = .readyToInstall(version: currentVersionString)
            NSApp.terminate(nil)
        }
    }

    /// Called from `applicationWillTerminate`. If a verified-BEFORE-quit update is staged
    /// and the mode/intent call for it, and the install location is replaceable, writes
    /// the detached swap helper and launches it. This runs ONLY the fast location check
    /// (C-3) — the signature/notarisation verification already ran before quit — so
    /// termination is never blocked by codesign/spctl. Refuses a translocated /
    /// read-only / non-writable location.
    func installOnQuitIfNeeded() {
        guard !didLaunchSwap, installApproved else { return }
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
        do {
            let helperDir = try UpdateStaging.helperDirectory()
            let scriptURL = helperDir.appendingPathComponent("swap-\(UUID().uuidString).sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            // Lock the script to the owner only, so it can't be swapped before it runs.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
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
        guard args.contains("-EmfyDebugUpdateAvailable") else { return }
        // Default to a version strictly NEWER than the running one (current patch + 1),
        // so the screenshot never advertises an older build as an update. An explicit
        // argument is honoured only when it genuinely parses as newer.
        let newer = AppVersion(core: [current.core[0], current.core[1], current.core[2] + 1],
                               build: (current.build ?? 0) + 1)
        var text = "\(newer.core.map(String.init).joined(separator: ".")) (\(newer.build ?? 0))"
        if let i = args.firstIndex(of: "-EmfyDebugUpdateAvailable"), i + 1 < args.count,
           let provided = AppVersion(tag: args[i + 1]), provided > current {
            text = args[i + 1]
        }
        lastChecked = Date()
        phase = .available(version: text)
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
