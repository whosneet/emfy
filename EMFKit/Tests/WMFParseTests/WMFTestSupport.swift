import Foundation

/// Filesystem anchor for committed corpus files, derived from `#filePath`.
///
/// FRAGILITY NOTE: the location is resolved from this source file's compile-time
/// path (`<repo>/EMFKit/Tests/WMFParseTests/`). Moving this file, renaming the
/// test directory, or building from a copied tree without the sibling `corpus/`
/// directory breaks the lookup. This mirrors the trade-off documented in
/// EMFParseTests' `CorpusPaths` / `MetafileCorpus`; SPM has no supported way to
/// reference files outside the package.
enum WMFCorpus {
    /// `<repo>/corpus/<name>`
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // WMFParseTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // EMFKit
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("corpus")
            .appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// Every committed WMF the W3 corpus tests run over (placeable LibreOffice
    /// exports, the derived non-placeable export, and the W2 hand-built
    /// headers). The gzip-wrapped `.wmz` is opened through the front door
    /// separately.
    static let wmfFiles: [String] = [
        "gate-wmf-p2-house.wmf",
        "gate-wmf-p2-star.wmf",
        "gate-wmf-p2-triangles.wmf",
        "gate-wmf-p3-curves.wmf",
        "gate-wmf-p3-shapes.wmf",
        "gate-wmf-p4-image.wmf",
        "gate-wmf-p4-text.wmf",
        "gate-wmf-p4-image-standard.wmf",
        "handmade-wmf-standard.wmf",
        "handmade-wmf-placeable.wmf",
    ]

    /// The committed placeable WMFs (checksum must verify).
    static let placeableFiles: [String] = [
        "gate-wmf-p2-house.wmf",
        "gate-wmf-p2-star.wmf",
        "gate-wmf-p2-triangles.wmf",
        "gate-wmf-p3-curves.wmf",
        "gate-wmf-p3-shapes.wmf",
        "gate-wmf-p4-image.wmf",
        "gate-wmf-p4-text.wmf",
        "handmade-wmf-placeable.wmf",
    ]
}

/// SplitMix64, local to this module (deterministic for a given seed). The
/// EMFParseTests copy is in a different module, hence the duplication.
struct WMFPRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
