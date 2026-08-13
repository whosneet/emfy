import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// CJK text-corpus coverage (v1.x backlog: the phase-4 CJK gap). The committed
/// `handmade-cjk-text.emf` renders four styled runs — Simplified Chinese,
/// Japanese, Korean, and a non-BMP surrogate-pair glyph — exercising LOGFONTW
/// non-Latin charset resolution and UTF-16LE EMR_EXTTEXTOUTW playback.
///
/// FONT-AVAILABILITY CAUTION (this machine has Microsoft Office): a CJK Windows
/// facename may resolve directly on a machine that registers it, or substitute
/// to the default face (with CTLine's cascade supplying the glyphs) on one that
/// does not. Tests therefore assert glyphs ALWAYS render, but never hard-require
/// that substitution occurred.
@Suite("CJK text corpus")
struct SnapshotCJKTests {

    private static let corpusName = "handmade-cjk-text"

    // MARK: - Provenance

    /// The committed corpus file is byte-for-byte the generator output, so it can
    /// never drift from its documented origin. Under `EMFY_RECORD=1` this instead
    /// (re-)writes the file into the source `corpus/` and fails deliberately, so
    /// a recording run can never pass as green.
    @Test("CJK corpus provenance: committed file equals the generator byte-for-byte")
    func provenance() throws {
        let url = TestPaths.corpusFile("\(Self.corpusName).emf")
        if isRecordingBaselines {
            try CJKTextCorpus.data.write(to: url)
            Issue.record("EMFY_RECORD: wrote \(url.path) — re-run without EMFY_RECORD to verify")
            return
        }
        let committed = try #require(
            try? Data(contentsOf: url),
            "corpus file not readable at \(url.path) — materialise it with EMFY_RECORD=1 swift test --filter provenance"
        )
        #expect(committed == CJKTextCorpus.data,
                "committed \(Self.corpusName).emf differs from CJKTextCorpus.data (\(committed.count) vs \(CJKTextCorpus.data.count) bytes)")
    }

    // MARK: - Render coverage

    /// Parses and renders the committed file: no record is malformed, the only
    /// unimplemented record is EMR_EOF, and every run draws ink. Font
    /// substitution/stock entries are tolerated (font-availability dependent).
    @Test("CJK corpus render: four runs draw, no malformed or unimplemented (bar EOF)")
    func renderCoverage() throws {
        let file = try parseCorpusFile("\(Self.corpusName).emf")
        let (image, log) = try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(Self.corpusName)"
        )
        #expect(image.width == 360)
        #expect(image.height == 240)

        // No malformed payloads.
        #expect(!log.entries.contains { if case .malformedRecord = $0 { return true }; return false },
                "a record decoded malformed: \(log.entries)")
        // The only tolerated entries are the EOF skip and machine-dependent font
        // resolution notes; anything else (other unimplemented types, unsupported
        // modes, canvas clamps, …) is a coverage failure.
        let unexpected = log.entries.filter { entry in
            switch entry {
            case .fontSubstituted, .stockFontUsed:
                return false
            case .unimplementedRecord(let type, _):
                return type != 14
            default:
                return true
            }
        }
        #expect(unexpected.isEmpty, "unexpected render-log entries for \(Self.corpusName): \(unexpected)")

        // Each run drew ink in its own vertical band (baseline ± em, TA_BASELINE).
        let pixels = try #require(RasterizedImage(image))
        #expect(pixels.containsDarkPixel(in: (x: 20, y: 26, width: 130, height: 34)),
                "Simplified-Chinese run drew no ink")
        #expect(pixels.containsDarkPixel(in: (x: 20, y: 81, width: 190, height: 34)),
                "Japanese run drew no ink")
        #expect(pixels.containsDarkPixel(in: (x: 20, y: 136, width: 150, height: 34)),
                "Korean run drew no ink")
        #expect(pixels.containsDarkPixel(in: (x: 18, y: 186, width: 46, height: 34)),
                "non-BMP surrogate-pair run drew no glyph")
    }

    /// Each run's Windows facename EITHER resolves to that exact family (a
    /// machine that ships it) OR is logged as a substitution — never silently
    /// wrong. Independent of the render, this pins `FontMapper`'s either/or.
    @Test("CJK facenames resolve exactly or log a substitution")
    func fontResolution() {
        for run in CJKTextCorpus.runs {
            var log = EMFRenderLog()
            let resolved = FontMapper.resolve(
                LogFont(
                    height: CJKTextCorpus.fontHeight, width: 0, escapement: 0, orientation: 0,
                    weight: 400, italic: 0, underline: 0, strikeOut: 0,
                    charSet: run.charSet, outPrecision: 0, clipPrecision: 0, quality: 0,
                    pitchAndFamily: 0, faceName: run.faceName
                ),
                log: &log
            )
            let family = (CTFontCopyFamilyName(resolved.base) as String)
                .lowercased().filter { !$0.isWhitespace }
            let requested = run.faceName.lowercased().filter { !$0.isWhitespace }
            let substituted = log.entries.contains {
                if case .fontSubstituted(let req, _, _) = $0 { return req == run.faceName }
                return false
            }
            #expect(family == requested || substituted,
                    "\(run.faceName): neither resolved exactly nor logged a substitution")
        }
    }

    // MARK: - Snapshot

    /// Pixel snapshot against the committed baseline (per-channel tolerance +
    /// differing-pixel budget). The render must show legible, upright,
    /// correctly-ordered CJK glyphs — the baseline is committed only after the
    /// main session's visual-acceptance pass on the artifact PNG.
    @Test("CJK corpus snapshot: legible upright CJK + surrogate glyph")
    func cjkSnapshot() throws {
        let file = try parseCorpusFile("\(Self.corpusName).emf")
        let (image, _) = try #require(
            EMFRenderer.makeImage(file, scale: 1),
            "makeImage returned nil for \(Self.corpusName)"
        )
        // Leave a viewable render in the artifacts folder for the visual pass.
        print("[cjk] render artifact: \(Self.writeArtifactPNG(image))")
        let failure = SnapshotComparator.verify(image, baselineNamed: Self.corpusName)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
    }

    // MARK: - Artifact

    /// Writes the rendered PNG into the shared artifacts folder for visual
    /// acceptance and returns its path (never masks a test result).
    private static func writeArtifactPNG(_ image: CGImage) -> String {
        let directory = TestPaths.artifactsDirectory.appendingPathComponent(corpusName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("render.png")
        return SnapshotComparator.writePNG(image, to: url) ? url.path : "(failed to write \(url.path))"
    }
}
