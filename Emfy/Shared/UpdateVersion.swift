#if EMFY_DMG
import Foundation

/// A comparable app version: a dotted numeric core (major.minor.patch, missing
/// parts treated as 0) plus an optional build number (U1). Parsed both from a
/// GitHub release tag ("v3.0.1", "3.0.1+6") and from the running app's
/// `CFBundleShortVersionString` / `CFBundleVersion`.
///
/// Comparison is by the numeric core first, then by build; a missing build sorts
/// as 0. Parsing is defensive — any non-numeric component becomes 0 rather than
/// failing — because a release feed is untrusted input (§8).
struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    /// The dotted numeric core, always at least three components (zero-padded).
    let core: [Int]
    /// The optional build number (the `+<n>` suffix, or the app's CFBundleVersion).
    let build: Int?

    /// Parses "v3.0.1", "3.0.1", "3.0.1+6" or "3.0" into a version. Returns `nil`
    /// only when no numeric core can be found at all, so a garbage tag never
    /// compares as an update.
    init?(tag: String) {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // Build metadata after '+' (semver) — take the first run of digits.
        var buildPart: Int?
        if let plus = s.firstIndex(of: "+") {
            let after = s[s.index(after: plus)...]
            buildPart = Int(after.prefix(while: { $0.isNumber }))
            s = String(s[..<plus])
        }
        // Require the string to start with a digit, so a non-numeric tag ("beta",
        // "") never compares as a real version.
        guard let first = s.first, first.isNumber else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var nums = parts.map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        while nums.count < 3 { nums.append(0) }
        self.core = nums
        self.build = buildPart
    }

    /// The running app's version from its bundle Info dictionary.
    init(short: String, build buildString: String?) {
        let parsed = AppVersion(tag: short) ?? AppVersion(core: [0, 0, 0], build: nil)
        self.core = parsed.core
        self.build = buildString.flatMap { Int($0) } ?? parsed.build
    }

    init(core: [Int], build: Int?) {
        var c = core
        while c.count < 3 { c.append(0) }
        self.core = c
        self.build = build
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.core.count, rhs.core.count)
        for i in 0..<n {
            let l = i < lhs.core.count ? lhs.core[i] : 0
            let r = i < rhs.core.count ? rhs.core[i] : 0
            if l != r { return l < r }
        }
        return (lhs.build ?? 0) < (rhs.build ?? 0)
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String {
        let c = core.map(String.init).joined(separator: ".")
        return build.map { "\(c)+\($0)" } ?? c
    }
}
#endif
