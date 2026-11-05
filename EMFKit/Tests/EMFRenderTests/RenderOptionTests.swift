import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

// MARK: - EMF+ fixture builders
//
// Hand-built EMF+ records wrapped in an EMR_COMMENT_EMFPLUS, mirroring the
// builders in EMFPlusPlaybackTests (kept file-private here so the two files do
// not collide). Each EMF+ record is Type(u16)/Flags(u16)/Size(u32)/DataSize(u32)
// then data ([MS-EMFPLUS] §2.3).

private let plusVersion: UInt32 = 0xDBC0_1002

private func le(_ build: (inout RenderFixture.LE) -> Void) -> [UInt8] {
    var writer = RenderFixture.LE()
    build(&writer)
    return writer.bytes
}

private func plusRecord(_ type: UInt16, _ flags: UInt16, _ data: [UInt8] = []) -> [UInt8] {
    le { writer in
        writer.u16(type)
        writer.u16(flags)
        writer.u32(UInt32(12 + data.count))
        writer.u32(UInt32(data.count))
        writer.raw(data)
    }
}

/// EmfPlusHeader (§2.3.3.3). The record-header Flags Dual bit (0x0001) marks a
/// dual file that carries a complete GDI copy.
private func plusHeader(dual: Bool) -> [UInt8] {
    plusRecord(0x4001, dual ? 0x0001 : 0x0000, le { $0.u32(plusVersion); $0.u32(0); $0.u32(96); $0.u32(96) })
}

/// EmfPlusSetAntiAliasMode (§2.3.6.1): the antialias state lives in Flags bit 0.
private func setAntiAliasMode(on: Bool) -> [UInt8] {
    plusRecord(0x401E, on ? 0x0001 : 0x0000)
}

/// EmfPlusFillRects (§2.3.4.5), S flag set → BrushId is a direct ARGB colour;
/// one RectF (x, y, w, h).
private func fillRectsDirect(_ argb: UInt32, _ rect: (Float, Float, Float, Float)) -> [UInt8] {
    plusRecord(0x400A, 0x8000, le { writer in
        writer.u32(argb); writer.u32(1)
        writer.f32(rect.0); writer.f32(rect.1); writer.f32(rect.2); writer.f32(rect.3)
    })
}

/// EmfPlusFillPolygon (§2.3.4.4), S flag → direct ARGB BrushId; float points.
private func fillPolygonDirect(_ argb: UInt32, _ points: [(Float, Float)]) -> [UInt8] {
    plusRecord(0x400C, 0x8000, le { writer in
        writer.u32(argb); writer.u32(UInt32(points.count))
        for point in points { writer.f32(point.0); writer.f32(point.1) }
    })
}

private extension RenderFixture {
    /// Appends an EMR_COMMENT_EMFPLUS carrying `stream` ([MS-EMF] §2.3.3.4).
    mutating func plusComment(_ stream: [UInt8]) {
        var payload = LE()
        payload.u32(UInt32(4 + stream.count))   // DataSize (identifier + stream)
        payload.u32(0x2B46_4D45)                // "EMF+"
        payload.raw(stream)
        append(type: 70, payload: payload.bytes)
    }
}

/// A 100×100 EMF whose one EMF+ comment carries `records` after an EMF+-only
/// (non-dual) header, so the renderer takes the EMF+ playback path.
private func plusFile(_ records: [[UInt8]]) throws -> EMFFile {
    var fixture = RenderFixture()
    fixture.plusComment(plusHeader(dual: false) + records.reduce([], +))
    return try fixture.parsed()
}

/// A 100×100 EMF with a GDI full-canvas RED rectangle AND an EMF+ comment that
/// fills the canvas BLUE. `dual` sets the EmfPlusHeader Dual flag, so option 3's
/// `.gdi` arbitration applies only when `dual` is true.
private func mixedFixture(dual: Bool) -> RenderFixture {
    var fixture = RenderFixture()
    fixture.createSolidBrush(index: 1, r: 255, g: 0, b: 0)
    fixture.selectObject(1)
    fixture.selectObject(0x8000_0008)                 // NULL_PEN — no outline
    fixture.rectangle(0, 0, 100, 100)                 // GDI copy: full-canvas red
    fixture.plusComment(plusHeader(dual: dual) + fillRectsDirect(0xFF00_00FF, (0, 0, 100, 100)))
    return fixture
}

/// The one public, Sendable, Equatable `RenderOptions` value threaded through
/// EMFRender (S1b slice 1). `.default` keeps every output byte-identical; the
/// four options change antialiasing, font substitution, EMF+ dual arbitration,
/// and WMF embedded-EMF selection.
@Suite("RenderOptions")
struct RenderOptionTests {

    // MARK: - Pixel probes

    private static func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.r > 180 && p.g < 80 && p.b < 80
    }
    private static func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.b > 180 && p.r < 80 && p.g < 80
    }

    /// Counts pixels with at least one channel strictly between near-black (20)
    /// and near-white (235) — i.e. partial-coverage antialiased pixels. A render
    /// of hard-edged black/white or pure-blue/white shapes has none.
    private static func intermediateCount(_ r: RasterizedImage) -> Int {
        func mid(_ v: UInt8) -> Bool { v > 20 && v < 235 }
        var count = 0
        for y in 0 ..< r.height {
            for x in 0 ..< r.width {
                let p = r[x, y]
                if mid(p.r) || mid(p.g) || mid(p.b) { count += 1 }
            }
        }
        return count
    }

    // MARK: - RenderOptions value

    @Test("`.default` is the all-defaults value")
    func defaultValue() {
        #expect(RenderOptions.default == RenderOptions())
        #expect(RenderOptions.default == RenderOptions(
            antialiasing: .smooth, fontSubstitutions: [],
            emfPlusArbitration: .emfPlus, useEmbeddedEMF: true))
    }

    @Test("rendering with `.default` matches rendering with no options argument")
    func defaultMatchesImplicit() throws {
        let file = try Self.diagonalLine()
        let (implicit, _) = try #require(EMFRenderer.makeImage(file))
        let (explicit, _) = try #require(EMFRenderer.makeImage(file, options: .default))
        #expect(try #require(RasterizedImage(implicit)).pixels == #require(RasterizedImage(explicit)).pixels)
    }

    // MARK: - Option 1: antialiasing

    /// A black cosmetic diagonal line on a 100×100 white canvas; the shallow
    /// slope guarantees partial-coverage pixels when smoothing is on.
    private static func diagonalLine() throws -> EMFFile {
        var fixture = RenderFixture()
        fixture.createPen(index: 1, style: 0, width: 0, r: 0, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.moveToEx(0, 8)
        fixture.lineTo(99, 70)
        return try fixture.parsed()
    }

    @Test("crisp has only fully-on/off coverage; smooth has intermediate pixels (GDI)")
    func antialiasingGDI() throws {
        let file = try Self.diagonalLine()
        let (smoothImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(antialiasing: .smooth)))
        let smooth = try #require(RasterizedImage(smoothImg))
        let (crispImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(antialiasing: .crisp)))
        let crisp = try #require(RasterizedImage(crispImg))

        #expect(Self.intermediateCount(smooth) > 0, "smooth must antialias the diagonal edge")
        #expect(Self.intermediateCount(crisp) == 0, "crisp must have no partial-coverage pixels")
        // The line still drew under crisp (there are fully-black pixels).
        #expect(crisp.contains(in: (0, 0, crisp.width, crisp.height)) { $0.r < 20 && $0.g < 20 && $0.b < 20 },
                "crisp dropped the line entirely")
    }

    @Test("crisp overrides the file's EMF+ SetAntiAliasMode")
    func antialiasingEMFPlus() throws {
        // The file asks for antialiasing ON, then fills a triangle (diagonal edge).
        let file = try plusFile([
            setAntiAliasMode(on: true),
            fillPolygonDirect(0xFF00_00FF, [(10, 10), (90, 10), (10, 90)]),
        ])
        let (smoothImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(antialiasing: .smooth)))
        let smooth = try #require(RasterizedImage(smoothImg))
        let (crispImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(antialiasing: .crisp)))
        let crisp = try #require(RasterizedImage(crispImg))

        #expect(Self.intermediateCount(smooth) > 0, "EMF+ smooth must antialias the triangle edge")
        #expect(Self.intermediateCount(crisp) == 0, "crisp must override the file's SetAntiAliasMode")
        // The triangle still filled blue under crisp.
        #expect(crisp.contains(in: (15, 15, 10, 10)) { Self.isBlue($0) }, "crisp dropped the EMF+ fill")
    }

    // MARK: - Option 2: font substitutions

    private static let missingFamily = "Zzqx Nonexistent Family"

    /// A 100×100 EMF selecting `faceName` and drawing a short string.
    private static func textFile(faceName: String) throws -> EMFFile {
        var fixture = RenderFixture()
        fixture.extCreateFontIndirectW(index: 1, height: -24, faceName: faceName)
        fixture.selectObject(1)
        fixture.setTextColor(r: 0, g: 0, b: 0)
        fixture.extTextOutW(reference: (6, 60), string: "Hello")
        return try fixture.parsed()
    }

    private static func substituted(_ log: EMFRenderLog, requested: String, used: String) -> Bool {
        log.entries.contains(.fontSubstituted(requested: requested, used: used, count: 1))
    }

    private static func anySubstitution(_ log: EMFRenderLog) -> Bool {
        log.entries.contains { if case .fontSubstituted = $0 { return true } else { return false } }
    }

    @Test("a user substitution maps a missing family to its replacement")
    func userSubstitutionMapsMissingFamily() throws {
        let file = try Self.textFile(faceName: Self.missingFamily)
        let options = RenderOptions(fontSubstitutions: [
            FontSubstitution(requestedFamily: Self.missingFamily, replacementFamily: "Helvetica"),
        ])
        let (_, log) = try #require(EMFRenderer.makeImage(file, options: options))
        #expect(Self.substituted(log, requested: Self.missingFamily, used: "Helvetica"),
                "expected the user replacement Helvetica, log: \(log.entries)")
    }

    @Test("without a user table the missing family falls to the built-in default")
    func missingFamilyUsesBuiltInDefault() throws {
        let file = try Self.textFile(faceName: Self.missingFamily)
        let (_, log) = try #require(EMFRenderer.makeImage(file))   // default options, no table
        #expect(Self.substituted(log, requested: Self.missingFamily, used: FontMapper.defaultFamily),
                "expected the built-in default \(FontMapper.defaultFamily), log: \(log.entries)")
    }

    @Test("an installed family is never substituted, even with a table entry for it")
    func installedFamilyNeverSubstituted() throws {
        let file = try Self.textFile(faceName: "Helvetica")
        let options = RenderOptions(fontSubstitutions: [
            FontSubstitution(requestedFamily: "Helvetica", replacementFamily: "Times New Roman"),
        ])
        let (_, log) = try #require(EMFRenderer.makeImage(file, options: options))
        #expect(!Self.anySubstitution(log), "an installed family must resolve directly, log: \(log.entries)")
    }

    @Test("a missing replacement falls through to the built-in table")
    func missingReplacementFallsThrough() throws {
        let file = try Self.textFile(faceName: Self.missingFamily)
        let options = RenderOptions(fontSubstitutions: [
            FontSubstitution(requestedFamily: Self.missingFamily, replacementFamily: "Another Nonexistent Qqq"),
        ])
        let (_, log) = try #require(EMFRenderer.makeImage(file, options: options))
        #expect(Self.substituted(log, requested: Self.missingFamily, used: FontMapper.defaultFamily),
                "expected fall-through to \(FontMapper.defaultFamily), log: \(log.entries)")
    }

    @Test("user-table matching is case- and space-insensitive")
    func userSubstitutionCaseInsensitive() throws {
        let file = try Self.textFile(faceName: Self.missingFamily)
        let options = RenderOptions(fontSubstitutions: [
            FontSubstitution(requestedFamily: "  zzqxNONEXISTENTfamily ", replacementFamily: "Helvetica"),
        ])
        let (_, log) = try #require(EMFRenderer.makeImage(file, options: options))
        #expect(Self.substituted(log, requested: Self.missingFamily, used: "Helvetica"),
                "case/space-insensitive match failed, log: \(log.entries)")
    }

    // MARK: - Option 3: EMF+ dual arbitration

    @Test("a dual EMF+ file shows EMF+ content by default and its GDI copy under `.gdi`")
    func dualArbitration() throws {
        let file = try mixedFixture(dual: true).parsed()
        // Default (.emfPlus): the EMF+ blue drives; the GDI red never plays
        // (no GetDC window).
        let (defImg, _) = try #require(EMFRenderer.makeImage(file))
        let def = try #require(RasterizedImage(defImg))
        #expect(Self.isBlue(def[50, 50]), "default must show EMF+ blue, got \(def[50, 50])")
        // .gdi: the GDI red rectangle drives; EMF+ blue is ignored.
        let (gdiImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(emfPlusArbitration: .gdi)))
        let gdi = try #require(RasterizedImage(gdiImg))
        #expect(Self.isRed(gdi[50, 50]), "`.gdi` must show the GDI copy, got \(gdi[50, 50])")
    }

    @Test("`.gdi` has no effect on a non-dual EMF+ file")
    func nonDualArbitrationNoEffect() throws {
        let file = try mixedFixture(dual: false).parsed()
        let (defImg, _) = try #require(EMFRenderer.makeImage(file))
        let def = try #require(RasterizedImage(defImg))
        let (gdiImg, _) = try #require(EMFRenderer.makeImage(file, options: RenderOptions(emfPlusArbitration: .gdi)))
        let gdi = try #require(RasterizedImage(gdiImg))
        // No complete GDI copy → both play the EMF+ blue.
        #expect(Self.isBlue(def[50, 50]))
        #expect(Self.isBlue(gdi[50, 50]))
        #expect(def.pixels == gdi.pixels, "`.gdi` must not change a non-dual EMF+ render")
    }

    @Test("Prepared.hasGDICopy is true only for an EMF+ dual file")
    func hasGDICopyFlag() throws {
        let dual = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(mixedFixture(dual: true).data())))
        #expect(dual.hasGDICopy)
        let nonDual = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(mixedFixture(dual: false).data())))
        #expect(!nonDual.hasGDICopy)
        // A pure-GDI EMF carries no EMF+ header.
        var plain = RenderFixture()
        plain.rectangle(10, 10, 50, 50)
        let plainPrepared = try #require(MetafileRenderer.prepare(try OpenedMetafile.open(plain.data())))
        #expect(!plainPrepared.hasGDICopy)
    }

    // MARK: - Option 4: WMF embedded EMF

    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func placeable(w: Int16, h: Int16, inch: UInt16) -> [UInt8] {
        u32(0x9AC6_CDD7) + u16(0) + i16(0) + i16(0) + i16(w) + i16(h) + u16(inch) + u32(0) + u16(0)
    }
    private static func metaHeader() -> [UInt8] {
        u16(1) + u16(9) + u16(0x0300) + u16(0) + u16(0) + u16(0) + u32(0) + u16(0)
    }
    private static func record(_ function: UInt16, _ body: [UInt8]) -> [UInt8] {
        u32(UInt32((6 + body.count) / 2)) + u16(function) + body
    }
    private static func eof() -> [UInt8] { record(0x0000, []) }
    /// WMF GDI records that fill the whole canvas RED.
    private static func redFill() -> [UInt8] {
        record(0x020B, i16(0) + i16(0))
            + record(0x020C, i16(96) + i16(96))
            + record(0x02FC, u16(0) + [255, 0, 0, 0] + u16(0))
            + record(0x012D, u16(0))
            + record(0x041B, i16(96) + i16(96) + i16(0) + i16(0))
    }
    /// One META_ESCAPE_ENHANCED_METAFILE "WMFC" chunk ([MS-WMF] §2.3.6.25).
    private static func wmfcChunk(_ chunk: [UInt8], recordCount: UInt32, remaining: UInt32, total: UInt32) -> [UInt8] {
        var body: [UInt8] = []
        body += u16(0x000F)
        body += u16(UInt16(34 + chunk.count))
        body += u32(0x4346_4D57)                // "WMFC"
        body += u32(0x0000_0001)
        body += u32(0x0001_0000)
        body += u16(0)
        body += u32(0)
        body += u32(recordCount)
        body += u32(UInt32(chunk.count))
        body += u32(remaining)
        body += u32(total)
        body += chunk
        return record(0x0626, body)
    }

    @Test("useEmbeddedEMF=false plays the WMF records instead of the embedded EMF")
    func embeddedEMFDeclined() throws {
        // A placeable WMF carrying a complete embedded EMF (a blue top-left mark)
        // AND GDI records that fill the canvas RED.
        var emf = RenderFixture()
        emf.bounds = (0, 0, 95, 95)
        emf.createSolidBrush(index: 1, r: 0, g: 0, b: 255)
        emf.selectObject(1)
        emf.selectObject(0x8000_0008)             // NULL_PEN
        emf.rectangle(0, 0, 20, 20)               // blue mark, top-left only
        let emfBytes = Array(emf.data())

        let wmf = Self.placeable(w: 96, h: 96, inch: 96) + Self.metaHeader()
            + Self.wmfcChunk(emfBytes, recordCount: 1, remaining: 0, total: UInt32(emfBytes.count))
            + Self.redFill() + Self.eof()
        let opened = try OpenedMetafile.open(Data(wmf))

        // Default: the embedded EMF supersedes → blue mark, centre undrawn.
        let played = try #require(MetafileRenderer.prepare(opened))
        #expect(played.kind == .emf)
        #expect(played.embeddedEMF == .played)
        let (playedImg, _) = try #require(MetafileRenderer.makeImage(played))
        let playedRaster = try #require(RasterizedImage(playedImg))
        #expect(Self.isBlue(playedRaster[5, 5]), "default must play the embedded EMF's blue mark")
        #expect(!Self.isRed(playedRaster[48, 48]), "default must not play the WMF red records")

        // Declined: the WMF records play → full-canvas red.
        let declined = try #require(MetafileRenderer.prepare(opened, options: RenderOptions(useEmbeddedEMF: false)))
        #expect(declined.kind == .wmfRecords)
        #expect(declined.embeddedEMF == .declined)
        let (declinedImg, _) = try #require(MetafileRenderer.makeImage(declined, options: RenderOptions(useEmbeddedEMF: false)))
        let declinedRaster = try #require(RasterizedImage(declinedImg))
        #expect(Self.isRed(declinedRaster[declinedRaster.width / 2, declinedRaster.height / 2]),
                "declined must play the WMF red fill")
    }

    @Test("useEmbeddedEMF toggles the embedded-EMF fate on a real corpus file")
    func embeddedEMFDeclinedCorpus() throws {
        let data = try Data(contentsOf: TestPaths.corpusFile("gate-wmf-p2-star.wmz"))
        let opened = try OpenedMetafile.open(data)
        let played = try #require(MetafileRenderer.prepare(opened))
        #expect(played.kind == .emf && played.embeddedEMF == .played)
        let declined = try #require(MetafileRenderer.prepare(opened, options: RenderOptions(useEmbeddedEMF: false)))
        #expect(declined.kind == .wmfRecords && declined.embeddedEMF == .declined)
        #expect(MetafileRenderer.makeImage(declined, options: RenderOptions(useEmbeddedEMF: false)) != nil)
    }
}

/// `EMFFile.emfPlusIsDual()` — the bounded, header-only Dual-flag read that
/// backs `Prepared.hasGDICopy` without reassembling the EMF+ stream.
@Suite("EMF+ dual flag (bounded read)")
struct EMFPlusDualFlagTests {

    /// The bounded read must give the same verdict as the full stream decode.
    private static func agrees(_ file: EMFFile) -> Bool {
        file.emfPlusIsDual() == (file.emfPlusStream().header?.isDual ?? false)
    }

    @Test("agrees with emfPlusStream().header?.isDual on every committed EMF fixture")
    func agreesOnCorpus() throws {
        let dir = TestPaths.repositoryRoot.appendingPathComponent("corpus")
        let urls = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "emf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!urls.isEmpty, "no corpus .emf files found at \(dir.path)")
        for url in urls {
            let file = try EMFFile.parse(try Data(contentsOf: url))
            #expect(Self.agrees(file),
                    "disagreement on \(url.lastPathComponent): bounded=\(file.emfPlusIsDual()), stream=\(file.emfPlusStream().header?.isDual ?? false)")
        }
    }

    @Test("agrees on the hand-built dual and non-dual EMF+ fixtures")
    func agreesOnFixtures() throws {
        let dual = try mixedFixture(dual: true).parsed()
        #expect(dual.emfPlusIsDual())
        #expect(Self.agrees(dual))
        let nonDual = try mixedFixture(dual: false).parsed()
        #expect(!nonDual.emfPlusIsDual())
        #expect(Self.agrees(nonDual))
    }

    @Test("a truncated first EMF+ comment returns false without trapping")
    func truncatedCommentIsFalse() throws {
        // A comment that declares the EMF+ identifier (DataSize == 4) but carries
        // no EMF+ record, so the first-record Type/Flags read runs off the record
        // end — the bounds-checked RecordSlice returns nil and the verdict is false.
        var fixture = RenderFixture()
        fixture.plusComment([])
        let file = try fixture.parsed()
        #expect(!file.emfPlusIsDual())
        #expect(Self.agrees(file))
    }

    @Test("a pure-GDI file (no EMF+ comment) returns false")
    func pureGDIIsFalse() throws {
        var fixture = RenderFixture()
        fixture.rectangle(10, 10, 50, 50)
        let file = try fixture.parsed()
        #expect(!file.emfPlusIsDual())
        #expect(Self.agrees(file))
    }
}
