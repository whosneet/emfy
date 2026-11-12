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
