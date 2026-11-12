#if EMFY_DMG && os(macOS)
import CryptoKit
import Foundation
import Security

/// Verifies a downloaded update before anything is installed (U1 §10.1). Every
/// required check must pass; any failure returns a typed error and the caller
/// deletes the download and installs nothing. Injected behind `UpdateVerifying` so
/// the controller can be tested with a fake, while the real checks are exercised by
/// a real-crypto negative test (an unsigned bundle must fail the signature step).
protocol UpdateVerifying: Sendable {
    /// Mounts, locates and fully verifies the app in `dmg`, returning the verified
    /// app URL (inside the mount) and the mount point to detach afterwards.
    func verify(
        dmg: URL,
        expectedSHA256 hex: String,
        expectedBundleID: String,
        current: AppVersion
    ) throws -> VerifiedUpdate

    /// Re-verifies an already-STAGED bundle (not in a mount): signature + designated
    /// requirement + Gatekeeper + bundle-ID + newer-version. Run right after staging
    /// and again immediately before the swap, so a tampered staged copy never installs
    /// (TOCTOU). Throws on any failure.
    func verifyStagedBundle(appURL: URL, expectedBundleID: String, current: AppVersion) throws

    /// Detaches a mount opened by `verify`.
    func detach(mountPoint: URL)
}

/// The result of a successful verification: where the verified app lives (inside the
/// read-only mount) and its parsed version.
struct VerifiedUpdate: Sendable {
    let appURL: URL
    let mountPoint: URL
    let version: AppVersion
}

/// The Developer ID team the update must be signed by (Apple-anchored). Used in the
/// designated requirement below.
private let emfyTeamOU = "6Y294JNMJ2"

struct SecurityUpdateVerifier: UpdateVerifying {

    // MARK: SHA-256 (step a)

    /// Streams a file through SHA-256 so a 500 MB DMG never loads whole into memory.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Code signature (step c)

    /// Checks that `appURL` is validly signed and satisfies the designated
    /// requirement `anchor apple generic and certificate leaf[subject.OU] = "<team>"`,
    /// with strict, all-architecture, nested-code validation. Throws
    /// `.signatureInvalid` on any failure. Pure enough to unit-test against an
    /// unsigned bundle (which must fail here).
    static func checkCodeSignature(appURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw UpdateError.signatureInvalid("SecStaticCodeCreateWithPath: \(createStatus)")
        }

        var requirement: SecRequirement?
        let dr = "anchor apple generic and certificate leaf[subject.OU] = \"\(emfyTeamOU)\""
        let reqStatus = SecRequirementCreateWithString(dr as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let req = requirement else {
            throw UpdateError.signatureInvalid("SecRequirementCreateWithString: \(reqStatus)")
        }

        let flags: SecCSFlags = [
            SecCSFlags(rawValue: kSecCSStrictValidate),
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            SecCSFlags(rawValue: kSecCSCheckNestedCode),
        ]
        let checkStatus = SecStaticCodeCheckValidity(code, flags, req)
        guard checkStatus == errSecSuccess else {
            throw UpdateError.signatureInvalid("SecStaticCodeCheckValidity: \(checkStatus)")
        }
    }

    // MARK: Gatekeeper / notarisation (step d)

    /// Confirms Gatekeeper accepts the app for execution — i.e. a stapled, accepted
    /// notarisation ticket. No public API exposes the notarisation verdict directly,
    /// so this uses `spctl --assess --type execute` via `Process`
    /// (Apple TN3147 "Migrating to the latest notarization tool" documents spctl as
    /// the supported assessment command). A non-zero exit → `.notNotarized`.
    static func checkGatekeeper(appURL: URL) throws {
        let result = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", appURL.path])
        guard result.exitCode == 0 else {
            throw UpdateError.notNotarized
        }
    }

    // MARK: Bundle identity and version (step e)

    /// Reads the mounted app's Info.plist and checks the bundle identifier matches
    /// and the version is strictly newer than the running app.
    static func checkIdentityAndVersion(
        appURL: URL, expectedBundleID: String, current: AppVersion
    ) throws -> AppVersion {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String else {
            throw UpdateError.bundleIdentifierMismatch
        }
        guard bundleID == expectedBundleID else { throw UpdateError.bundleIdentifierMismatch }
        let short = dict["CFBundleShortVersionString"] as? String ?? "0"
        let build = dict["CFBundleVersion"] as? String
        let version = AppVersion(short: short, build: build)
        guard version > current else { throw UpdateError.notNewer }
        return version
    }

    // MARK: Mount (step b)

    /// Mounts `dmg` read-only, nobrowse, at a fresh private temp mount point and
    /// returns the mount point plus the located `Emfy.app`.
    static func mount(dmg: URL) throws -> (mountPoint: URL, appURL: URL) {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUpdateMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try run("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                              "-mountpoint", mountPoint.path])
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw UpdateError.mountFailed(result.stderr)
        }
        let appURL = mountPoint.appendingPathComponent("Emfy.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            detachMount(mountPoint)
            throw UpdateError.appNotFoundInImage
        }
        return (mountPoint, appURL)
    }

    static func detachMount(_ mountPoint: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    // MARK: Orchestration

    func verify(
        dmg: URL,
        expectedSHA256 hex: String,
        expectedBundleID: String,
        current: AppVersion
    ) throws -> VerifiedUpdate {
        // (a) digest first — cheap and decisive.
        guard UpdateDigest.validHex(hex) else { throw UpdateError.digestUnavailable }
        let actual = try Self.sha256Hex(ofFileAt: dmg)
        guard actual.lowercased() == hex.lowercased() else { throw UpdateError.digestMismatch }

        // (b) mount read-only / nobrowse and locate the app.
        let (mountPoint, appURL) = try Self.mount(dmg: dmg)
        do {
            // (c) code signature + designated requirement.
            try Self.checkCodeSignature(appURL: appURL)
            // (d) Gatekeeper / notarisation.
            try Self.checkGatekeeper(appURL: appURL)
            // (e) bundle id + newer version.
            let version = try Self.checkIdentityAndVersion(
                appURL: appURL, expectedBundleID: expectedBundleID, current: current)
            return VerifiedUpdate(appURL: appURL, mountPoint: mountPoint, version: version)
        } catch {
            Self.detachMount(mountPoint)
            throw error
        }
    }

    /// Re-verifies a staged bundle in place (TOCTOU guard). No digest, no mount — the
    /// staged copy is on a user-writable path, so its signature is the source of truth.
    func verifyStagedBundle(appURL: URL, expectedBundleID: String, current: AppVersion) throws {
        try Self.checkCodeSignature(appURL: appURL)
        try Self.checkGatekeeper(appURL: appURL)
        _ = try Self.checkIdentityAndVersion(
            appURL: appURL, expectedBundleID: expectedBundleID, current: current)
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) throws -> UpdateProcess.Result {
        try UpdateProcess.run(path, args, timeout: timeout)
    }

    func detach(mountPoint: URL) {
        Self.detachMount(mountPoint)
    }
}

/// A `Process` runner that drains stdout and stderr CONCURRENTLY (so a child that
/// fills one pipe can never deadlock against a sequential read of the other) and
/// enforces a hard timeout (`spctl` can stall on an online revocation check). On
/// timeout the child is terminated and `.verificationTimedOut` is thrown.
enum UpdateProcess {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes on their own concurrent tasks so neither blocks the other.
        let queue = DispatchQueue(label: "com.avneetsingh.emfy.update.proc", attributes: .concurrent)
        let drain = DispatchGroup()
        let lock = NSLock()
        var outData = Data(), errData = Data()
        func drainPipe(_ pipe: Pipe, isOut: Bool) {
            drain.enter()
            queue.async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); if isOut { outData = data } else { errData = data }; lock.unlock()
                drain.leave()
            }
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        drainPipe(out, isOut: true)
        drainPipe(err, isOut: false)

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 3)
            _ = drain.wait(timeout: .now() + 3)
            throw UpdateError.verificationTimedOut
        }
        drain.wait()
        lock.lock(); let o = outData, e = errData; lock.unlock()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: o, as: UTF8.self),
            stderr: String(decoding: e, as: UTF8.self))
    }
}
#endif
