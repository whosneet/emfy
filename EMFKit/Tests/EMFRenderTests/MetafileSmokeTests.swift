import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// The iOS-simulator smoke gate (v3-plan I0): every committed corpus metafile
/// goes through the single front door — `OpenedMetafile.open` →
/// `MetafileRenderer.prepare` → `MetafileRenderer.makeImage` — and must produce
/// a non-blank raster without crashing. It runs on macOS too (extra coverage),
/// but its reason to exist is proving EMFKit renders on iOS, where the snapshot
/// baselines cannot (CoreText rasterises differently per platform, so those are
/// gated to macOS).
///
/// Corpus access: `TestPaths` anchors on `#filePath`, so the committed corpus is
/// read by its absolute compile-time path. An iOS Simulator process shares the
/// host filesystem, so that path resolves there as well as on macOS.
@Suite("Metafile render smoke (all platforms, iOS gate)")
struct MetafileSmokeTests {

    /// The committed corpus directory, from the same `#filePath` anchor the
    /// snapshot/corpus tests use.
    static var corpusDirectory: URL {
        TestPaths.repositoryRoot.appendingPathComponent("corpus")
    }

    /// Every committed metafile input the renderer accepts: EMF, EMZ, WMF, WMZ.
    /// Enumerated from the corpus directory so a new committed file is covered
    /// automatically; SVG/PNG/README and anything else are ignored. Sorted for a
    /// stable case order. Empty if the directory cannot be read — the
    /// `corpusDirectoryIsPopulated` guard turns that into a failure rather than a
    /// silently green zero-case run.
    static var corpusMetafileNames: [String] {
        let renderable: Set<String> = ["emf", "emz", "wmf", "wmz"]
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: corpusDirectory.path
        ) else { return [] }
        return names
            .filter { renderable.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    /// Guards against the enumeration coming back empty (e.g. a broken
    /// compile-time anchor on a copied tree, or an unreadable corpus path on a
    /// simulator): a zero-case parameterized run would otherwise masquerade as
    /// green. The committed corpus has 33 renderable files as of I0; a floor of
    /// 30 leaves room for churn without hiding a wholesale lookup failure.
    @Test("the corpus directory resolves and is populated")
    func corpusDirectoryIsPopulated() {
        let names = Self.corpusMetafileNames
        #expect(
            names.count >= 30,
            "found \(names.count) renderable corpus files at \(Self.corpusDirectory.path); expected at least 30 — the TestPaths #filePath anchor may be broken on this platform"
        )
    }

    /// The two committed WMF fixtures that are META_HEADER + META_EOF only — no
    /// drawing records at all (they exist to exercise the parser/front door). A
    /// blank canvas is the CORRECT output for these, so the non-blank probe is
    /// skipped for them; the open → prepare → makeImage pipeline is still asserted.
    static let intentionallyBlank: Set<String> = [
        "handmade-wmf-standard.wmf",
        "handmade-wmf-placeable.wmf",
    ]

    /// Every corpus metafile opens, prepares, and renders at scale 1 to a valid
    /// (non-nil) image without crashing — the core iOS smoke. Every file that
    /// carries drawing records must also land some ink: the non-blank probe is
    /// "any pixel that is not near-white", and since the canvas is cleared to
    /// opaque white before playback, any drawn shape — black, red, blue, an image
    /// — trips it. That catches the §8 anti-goal of a silent blank canvas on a
    /// file that has content.
    @Test("every corpus metafile opens, renders and is non-blank", arguments: corpusMetafileNames)
    func corpusFileRendersNonBlank(_ name: String) throws {
        let data = try #require(
            try? Data(contentsOf: Self.corpusDirectory.appendingPathComponent(name)),
            "corpus file not readable: \(name)"
        )
        let opened = try OpenedMetafile.open(data)
        let prepared = try #require(
            MetafileRenderer.prepare(opened),
            "prepare returned nil for \(name) (format \(opened.format))"
        )
        let (image, _) = try #require(
            MetafileRenderer.makeImage(prepared, scale: 1),
            "makeImage returned nil for \(name)"
        )
        let raster = try #require(RasterizedImage(image), "could not rasterize \(name)")
        guard !Self.intentionallyBlank.contains(name) else { return }
        let nonBlank = raster.contains(in: (0, 0, raster.width, raster.height)) {
            !($0.r > 240 && $0.g > 240 && $0.b > 240)
        }
        #expect(nonBlank, "\(name) rendered a blank (all-white) canvas")
    }
}
