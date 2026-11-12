#if EMFY_DMG && os(macOS)
import Foundation
import Testing

/// Real-crypto negative tests for the updater verifier (U1). A positive full-path
/// test needs a Developer ID-signed, notarised Emfy build and a real DMG, so it
/// can't run here — it goes on the C5 device list. These prove the two checks that
/// CAN run offline: the streaming SHA-256 against a known vector, and that an
/// UNSIGNED app bundle FAILS the code-signature/designated-requirement step.
struct UpdateVerifierTests {

    @Test func sha256MatchesKnownVector() throws {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyShaTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        let hex = try SecurityUpdateVerifier.sha256Hex(ofFileAt: file)
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func wrongDigestIsHardFailureBeforeMount() throws {
        // A mismatched SHA-256 must fail at the digest step — before any mount — so a
        // tampered download never reaches signature/notarisation checks and nothing is
        // installed. Uses a real file (not a DMG); the digest check runs first.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyDigestTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fake.dmg")
        try Data("not a real dmg".utf8).write(to: file)
        let wrongHex = String(repeating: "0", count: 64)
        #expect(throws: UpdateError.digestMismatch) {
            try SecurityUpdateVerifier().verify(
                dmg: file, expectedSHA256: wrongHex,
                expectedBundleID: "com.avneetsingh.emfy",
                current: AppVersion(core: [3, 0, 0], build: 5))
        }
    }

    @Test func processRunTimesOut() {
        // A child that outlives the timeout is terminated and reported as a typed
        // timeout — spctl can stall on an online revocation check, so verification
        // must never hang forever.
        #expect(throws: UpdateError.verificationTimedOut) {
            _ = try UpdateProcess.run("/bin/sleep", ["5"], timeout: 1)
        }
    }

    @Test func processReturnsDespiteSurvivingGrandchild() {
        // A backgrounded grandchild inherits stdout/stderr and outlives the child that
        // spawned it (hdiutil's helpers do this). The runner's NORMAL-exit path must
        // still return promptly — it bounds the pipe drain and closes the read handles
        // — rather than hang on `readDataToEndOfFile`.
        let start = Date()
        let result = try? UpdateProcess.run("/bin/sh", ["-c", "sleep 30 & exit 0"])
        #expect(result?.exitCode == 0)
        #expect(Date().timeIntervalSince(start) < 15)
    }

    @Test func stagedBundleReverificationRefusesTampered() throws {
        // The TOCTOU guard: an unsigned/tampered staged bundle must fail
        // re-verification, so it never swaps in.
        let (dir, app) = try Self.makeUnsignedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: UpdateError.self) {
            try SecurityUpdateVerifier().verifyStagedBundle(
                appURL: app, expectedBundleID: "com.avneetsingh.emfy",
                current: AppVersion(core: [3, 0, 0], build: 5))
        }
    }

    /// Builds a minimal, UNSIGNED `.app` in a fresh temp dir; returns (dir, appURL).
    private static func makeUnsignedBundle() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUnsigned-\(UUID().uuidString)", isDirectory: true)
        let app = dir.appendingPathComponent("Emfy.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.avneetsingh.emfy</string>
          <key>CFBundleExecutable</key><string>Emfy</string>
          <key>CFBundleShortVersionString</key><string>9.9.9</string>
          <key>CFBundleVersion</key><string>999</string>
        </dict></plist>
        """
        try Data(info.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: macos.appendingPathComponent("Emfy"))
        return (dir, app)
    }

    @Test func unsignedBundleFailsSignatureCheck() throws {
        // Build a minimal, UNSIGNED .app in a temp dir. The designated-requirement
        // validity check must throw .signatureInvalid — it never installs an app that
        // isn't Developer-ID-signed and anchored to the Emfy team.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyUnsigned-\(UUID().uuidString)", isDirectory: true)
        let app = dir.appendingPathComponent("Unsigned.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.avneetsingh.emfy</string>
          <key>CFBundleExecutable</key><string>Unsigned</string>
          <key>CFBundleShortVersionString</key><string>9.9.9</string>
          <key>CFBundleVersion</key><string>999</string>
        </dict></plist>
        """
        try Data(info.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: macos.appendingPathComponent("Unsigned"))

        #expect(throws: UpdateError.self) {
            try SecurityUpdateVerifier.checkCodeSignature(appURL: app)
        }
    }
}
#endif
