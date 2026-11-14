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
    ) async throws -> VerifiedUpdate

    /// Re-verifies an already-STAGED bundle (not in a mount): signature + designated
    /// requirement + Gatekeeper + bundle-ID + newer-version. Run right after staging
    /// and again before quit (C-3), so a tampered staged copy never installs (TOCTOU).
    /// Throws on any failure.
    func verifyStagedBundle(appURL: URL, expectedBundleID: String, current: AppVersion) async throws

    /// Detaches a mount opened by `verify`.
    func detach(mountPoint: URL) async
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

    /// The Developer ID designated requirement the update must satisfy (S-9): Apple
    /// anchored, the Developer ID intermediate CA marker OID
    /// (1.2.840.113635.100.6.2.6) on cert 1, the Developer ID Application leaf marker
    /// OID (1.2.840.113635.100.6.1.13) on the leaf, AND the Emfy team OU. The marker
    /// OIDs are what distinguish a Developer ID Application certificate from an Apple
    /// Development certificate — the old DR (`anchor apple generic and certificate
    /// leaf[subject.OU] = "<team>"`) accepted a Development-signed build.
    static let developerIDRequirement =
        "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(emfyTeamOU)\""

    /// Checks that `appURL` is validly signed and satisfies the Developer ID
    /// designated requirement (`developerIDRequirement`), with strict,
    /// all-architecture, nested-code validation. Throws `.signatureInvalid` on any
    /// failure. Pure enough to unit-test against an unsigned bundle (which must fail here).
    static func checkCodeSignature(appURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw UpdateError.signatureInvalid("SecStaticCodeCreateWithPath: \(createStatus)")
        }

        var requirement: SecRequirement?
        let dr = developerIDRequirement
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
    static func checkGatekeeper(appURL: URL) async throws {
        let result = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", appURL.path])
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
    static func mount(dmg: URL) async throws -> (mountPoint: URL, appURL: URL) {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUpdateMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try await run("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                              "-mountpoint", mountPoint.path])
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw UpdateError.mountFailed(result.stderr)
        }
        let appURL = mountPoint.appendingPathComponent("Emfy.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            await detachMount(mountPoint)
            throw UpdateError.appNotFoundInImage
        }
        return (mountPoint, appURL)
    }

    static func detachMount(_ mountPoint: URL) async {
        _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    // MARK: Orchestration

    func verify(
        dmg: URL,
        expectedSHA256 hex: String,
        expectedBundleID: String,
        current: AppVersion
    ) async throws -> VerifiedUpdate {
        // (a) digest first — cheap and decisive.
        guard UpdateDigest.validHex(hex) else { throw UpdateError.digestUnavailable }
        let actual = try Self.sha256Hex(ofFileAt: dmg)
        guard actual.lowercased() == hex.lowercased() else { throw UpdateError.digestMismatch }

        // (b) mount read-only / nobrowse and locate the app.
        let (mountPoint, appURL) = try await Self.mount(dmg: dmg)
        do {
            // (c) code signature + designated requirement.
            try Self.checkCodeSignature(appURL: appURL)
            // (d) Gatekeeper / notarisation.
            try await Self.checkGatekeeper(appURL: appURL)
            // (e) bundle id + newer version.
            let version = try Self.checkIdentityAndVersion(
                appURL: appURL, expectedBundleID: expectedBundleID, current: current)
            return VerifiedUpdate(appURL: appURL, mountPoint: mountPoint, version: version)
        } catch {
            await Self.detachMount(mountPoint)
            throw error
        }
    }

    /// Re-verifies a staged bundle in place (TOCTOU guard). No digest, no mount — the
    /// staged copy is on a user-writable path, so its signature is the source of truth.
    func verifyStagedBundle(appURL: URL, expectedBundleID: String, current: AppVersion) async throws {
        try Self.checkCodeSignature(appURL: appURL)
        try await Self.checkGatekeeper(appURL: appURL)
        _ = try Self.checkIdentityAndVersion(
            appURL: appURL, expectedBundleID: expectedBundleID, current: current)
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) async throws -> UpdateProcess.Result {
        try await UpdateProcess.run(path, args, timeout: timeout)
    }

    func detach(mountPoint: URL) async {
        await Self.detachMount(mountPoint)
    }
}

/// A `Process` runner that drains stdout and stderr CONCURRENTLY (so a child that
/// fills one pipe can never deadlock against a sequential read of the other) and
/// enforces a hard timeout (`spctl` can stall on an online revocation check). On
/// timeout the child is terminated and `.verificationTimedOut` is thrown.
enum UpdateProcess {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes on their own concurrent tasks so neither blocks the other.
        // The collected bytes live in a Sendable, lock-guarded box, so the queue
        // closures never mutate a captured `var` (Swift 6 concurrency).
        let queue = DispatchQueue(label: "com.avneetsingh.emfy.update.proc", attributes: .concurrent)
        let drain = DispatchGroup()
        let collected = CollectedOutput()
        func drainPipe(_ pipe: Pipe, isOut: Bool) {
            drain.enter()
            queue.async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.store(data, isOut: isOut)
                drain.leave()
            }
        }

        // Await the child's exit via a continuation resumed from `terminationHandler`
        // (C-5), NOT a DispatchSemaphore blocking a cooperative-pool thread. The timeout
        // is scheduled on the concurrent queue; a single-resume box makes the
        // exit/timeout/launch-failure race safe, and the thrown timeout terminates the
        // child first (spctl can stall on an online revocation check).
        let resumer = ContinuationBox()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                resumer.set(cont)
                process.terminationHandler = { _ in resumer.resume(returning: ()) }
                do {
                    try process.run()
                } catch {
                    resumer.resume(throwing: error)
                    return
                }
                drainPipe(out, isOut: true)
                drainPipe(err, isOut: false)
                queue.asyncAfter(deadline: .now() + timeout) {
                    if resumer.resume(throwing: UpdateError.verificationTimedOut) {
                        process.terminate()
                    }
                }
            }
        } catch {
            // Timeout or launch failure: bound the drain so the read handles close, then
            // rethrow the typed error. Nothing is returned. The blocking join runs OFF
            // the async context (`DispatchGroup.wait` is unavailable there).
            await Self.joinDrain(drain, out: out, err: err, timeout: 3)
            throw error
        }
        // The process has exited, but a surviving grandchild can still hold the
        // inherited pipe fds (hdiutil's diskimages helpers do this), so a plain
        // `drain.wait()` could block forever on the NORMAL path too. Bound it; on
        // timeout close the read handles — which unblocks the drain reads — and keep
        // whatever was collected. The exit code is already known.
        await Self.joinDrain(drain, out: out, err: err, timeout: 10)
        let (o, e) = collected.snapshot()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: o, as: UTF8.self),
            stderr: String(decoding: e, as: UTF8.self))
    }

    /// Waits (bounded) for the pipe-drain tasks to finish, OFF the async context — a
    /// `DispatchGroup.wait` is unavailable from an async function, so the blocking join
    /// runs in a dispatch closure and resumes the continuation when done. On the
    /// bounded timeout it closes the read handles (which unblocks a drain read a
    /// surviving grandchild is holding) and waits a moment more.
    private static func joinDrain(_ group: DispatchGroup, out: Pipe, err: Pipe, timeout: TimeInterval) async {
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    try? outHandle.close()
                    try? errHandle.close()
                    _ = group.wait(timeout: .now() + 2)
                }
                continuation.resume()
            }
        }
    }

    /// A lock-guarded single-resume wrapper around a `CheckedContinuation` (C-5): the
    /// child's exit, the timeout, and a launch failure can each try to resume, but only
    /// the first wins. `resume(throwing:)` returns whether it was the one that resumed,
    /// so the timeout path only terminates the child when it actually won the race.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        private var resumed = false

        func set(_ c: CheckedContinuation<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            cont = c
        }

        @discardableResult
        func resume(returning value: Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !resumed, let c = cont else { return false }
            resumed = true; cont = nil
            c.resume(returning: ())
            return true
        }

        @discardableResult
        func resume(throwing error: Error) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !resumed, let c = cont else { return false }
            resumed = true; cont = nil
            c.resume(throwing: error)
            return true
        }
    }

    /// A lock-guarded, Sendable box for the stdout/stderr bytes the concurrent drain
    /// tasks collect — so no captured `var` is mutated in the queue closures.
    private final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func store(_ data: Data, isOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isOut { out = data } else { err = data }
        }

        func snapshot() -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }
}
#endif
