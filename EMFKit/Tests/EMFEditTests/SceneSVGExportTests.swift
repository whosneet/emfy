import CoreGraphics
import EMFParse
import Foundation
import Testing
@testable import EMFEdit

/// F2 SVG export: structural well-formedness, the feature mapping per committed
/// fixture, determinism, security/hostile handling, and golden-snippet checks.
struct SceneSVGExportTests {

    // MARK: - Helpers

    private func scene(_ name: String) throws -> Scene {
        let url = EditTestPaths.corpusDirectory.appendingPathComponent(name)
        return try SceneImporter.import(data: try Data(contentsOf: url))
    }

    private func svgString(_ scene: Scene, options: SVGExportOptions = SVGExportOptions()) -> String {
        let result = SceneSVGExporter.export(scene, options: options)
        return String(data: result.data, encoding: .utf8) ?? ""
    }

    /// True when `data` is well-formed XML (the gate every exported document must
    /// pass — Quick Look and other apps parse it).
    private func isWellFormed(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        return parser.parse()
    }

    /// A synthetic scene wrapping arbitrary elements (an unparseable empty source;
    /// the exporter falls back to a 96-DPI physical size and never traps).
    private func syntheticScene(_ elements: [Element], page: CGRect = CGRect(x: 0, y: 0, width: 200, height: 150)) -> Scene {
        var ided = elements
        for i in ided.indices { ided[i].id = i }
        let partition = ScenePartition(structural: [], state: [], drawing: Set(0 ..< ided.count), passthrough: [], unitCount: ided.count)
        let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: ided.count)
        return Scene(pageBoundsDevice: page, layers: [Layer(id: 0, name: "l", elements: ided)], partition: partition, source: source)
    }

    private func pathElement(_ segments: [ScenePath.Segment], fill: SceneColor? = SceneColor(red: 1, green: 0, blue: 0), kind: ElementKind = .path) -> Element {
        Element(
            id: 0, kind: kind, geometryDevice: ScenePath(segments: segments), transform: .identity,
            style: SceneStyle(fill: fill.map { SceneFill(color: $0, evenOdd: false) }),
            provenance: Provenance(sourceRecordIndices: [])
        )
    }

    // MARK: - Well-formedness over the whole committed corpus

    @Test func everyCommittedFileExportsWellFormedSVG() throws {
        let files = EditTestPaths.committedMetafiles()
        try #require(!files.isEmpty)
        for url in files {
            guard let data = try? Data(contentsOf: url), let scene = try? SceneImporter.import(data: data) else { continue }
            let result = SceneSVGExporter.export(scene)
            #expect(isWellFormed(result.data), "not well-formed: \(url.lastPathComponent)")
            let text = String(data: result.data, encoding: .utf8) ?? ""
            #expect(text.hasPrefix("<?xml version=\"1.0\""), "missing XML decl: \(url.lastPathComponent)")
            #expect(text.contains("<svg "), "missing svg root: \(url.lastPathComponent)")
            #expect(text.contains("viewBox=\""), "missing viewBox: \(url.lastPathComponent)")
            #expect(text.hasSuffix("</svg>\n"), "unterminated: \(url.lastPathComponent)")
        }
    }

    // MARK: - Feature mapping per fixture

    @Test func emfGeometryMapsToVectorShapes() throws {
        let svg = svgString(try scene("gate-p2-house.emf"))
        #expect(svg.contains("<polygon "))
        #expect(svg.contains("width=\"") && svg.contains("mm\""))   // physical size present
        #expect(svg.contains("fill=\"#"))
    }

    @Test func emfPlusShapesMapGradientAndClip() throws {
        let svg = svgString(try scene("handmade-emfplus-shapes.emf"))
        #expect(svg.contains("<linearGradient "))
        #expect(svg.contains("gradientUnits=\"userSpaceOnUse\""))
        #expect(svg.contains("<clipPath "))
        #expect(svg.contains("fill=\"url(#g0)\""))
        #expect(svg.contains("<g clip-path=\"url(#c0)\">"))
    }

    @Test func dualFileExportsWellFormed() throws {
        let result = SceneSVGExporter.export(try scene("handmade-emfplus-dual.emf"))
        #expect(isWellFormed(result.data))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        #expect(svg.contains("fill=\"#"))   // the EMF+ and GetDC-GDI rects
    }

    @Test func wmfPlaceableUsesPhysicalSizeAndIsWellFormed() throws {
        let result = SceneSVGExporter.export(try scene("gate-wmf-p2-house.wmf"))
        #expect(isWellFormed(result.data))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        #expect(svg.contains("mm\""))
        #expect(svg.contains("<polygon ") || svg.contains("<path "))
    }

    @Test func getDCTextDualExportsText() throws {
        let svg = svgString(try scene("handmade-getdc-text-dual.emf"))
        #expect(svg.contains("<text "))
        #expect(svg.contains("Metafile") || svg.contains("Condensed"))
    }

    @Test func imageFixtureEmbedsBase64PNG() throws {
        let svg = svgString(try scene("gate-p4-image.emf"))
        #expect(svg.contains("<image "))
        #expect(svg.contains("data:image/png;base64,"))
        #expect(svg.contains("image-rendering=\"pixelated\""))
    }

    // MARK: - Golden snippets (one fixture per feature)

    @Test func goldenGradientStops() throws {
        let svg = svgString(try scene("handmade-emfplus-shapes.emf"))
        // The lifted linear gradient: red→blue along the device x-axis (230→330).
        #expect(svg.contains("<linearGradient id=\"g0\" gradientUnits=\"userSpaceOnUse\" x1=\"230\" y1=\"50\" x2=\"330\" y2=\"50\">"))
        #expect(svg.contains("<stop offset=\"0\" stop-color=\"#ff0000\"/>"))
        #expect(svg.contains("<stop offset=\"1\" stop-color=\"#0000ff\"/>"))
    }

    @Test func goldenClipPath() throws {
        let svg = svgString(try scene("handmade-emfplus-shapes.emf"))
        #expect(svg.contains("<clipPath id=\"c0\" clipPathUnits=\"userSpaceOnUse\">"))
        #expect(svg.contains("<g clip-path=\"url(#c0)\"><path d=\"M 0 190 L 360 190 L 360 240 L 0 240 Z\""))
    }

    @Test func goldenTextWithAdvances() throws {
        let svg = svgString(try scene("gate-p4-text.emf"))
        // An axis-aligned GDI run is drawn upright in DEVICE space: the explicit
        // per-character advances become an absolute device-space x list (14 values
        // for the 14 characters), with xml:space preserved and no mirroring transform.
        #expect(svg.contains("x=\"8.013 28.006 43.011 49.02 55.03 70.035"))
        #expect(svg.contains("font-size=\"28.006\""))
        #expect(svg.contains("xml:space=\"preserve\""))
        #expect(svg.contains(">Hello Emfy 123</text>"))
    }

    @Test func goldenRotatedImage() throws {
        // handmade-emfplus-image draws the same bitmap via DrawImage (axis-aligned)
        // and DrawImagePoints (a sheared parallelogram → a matrix transform).
        let svg = svgString(try scene("handmade-emfplus-image.emf"))
        #expect(svg.contains("<image x=\"0\" y=\"0\" width=\"1\" height=\"1\" transform=\"matrix("))
    }

    // MARK: - Determinism

    @Test func exportIsByteDeterministic() throws {
        for name in ["gate-p2-house.emf", "handmade-emfplus-shapes.emf", "gate-p4-text.emf", "handmade-emfplus-image.emf", "gate-wmf-p2-house.wmf"] {
            let s = try scene(name)
            let a = SceneSVGExporter.export(s)
            let b = SceneSVGExporter.export(s)
            #expect(a.data == b.data, "non-deterministic: \(name)")
        }
    }

    @Test func floatFormattingHasNoExponentOrLongDecimals() throws {
        let svg = svgString(try scene("gate-p3-curves.emf"))
        #expect(!svg.lowercased().contains("e-"))   // no exponent notation
        #expect(!svg.lowercased().contains("e+"))
        // No coordinate carries more than 3 fractional digits.
        let pattern = try NSRegularExpression(pattern: #"\.\d{4,}"#)
        let range = NSRange(svg.startIndex..., in: svg)
        #expect(pattern.firstMatch(in: svg, range: range) == nil)
    }

    // MARK: - Security / hostile handling

    @Test func textNodeEscapesScriptAndCDATAAndStripsControls() throws {
        var s = try scene("gate-p4-text.emf")
        let hostile = "<script>alert('x')</script>]]>\u{0}\u{1}\u{8}end&more"
        outer: for li in s.layers.indices {
            for ei in s.layers[li].elements.indices where s.layers[li].elements[ei].kind == .text {
                s.layers[li].elements[ei].text?.string = hostile
                break outer
            }
        }
        let result = SceneSVGExporter.export(s)
        #expect(isWellFormed(result.data))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        #expect(!svg.contains("<script"))
        #expect(!svg.contains("]]>"))
        #expect(!svg.contains("\u{0}") && !svg.contains("\u{1}") && !svg.contains("\u{8}"))
        #expect(svg.contains("&amp;more"))   // ampersand escaped, text preserved
        #expect(svg.contains("end"))
    }

    @Test func hostileTextDoesNotInjectAttributes() throws {
        var s = try scene("gate-p4-text.emf")
        // A family name crafted to try to break out of the attribute.
        let evil = "Arial\" onload=\"evil()"
        outer: for li in s.layers.indices {
            for ei in s.layers[li].elements.indices where s.layers[li].elements[ei].kind == .text {
                s.layers[li].elements[ei].text?.requestedFamily = evil
                break outer
            }
        }
        let result = SceneSVGExporter.export(s)
        #expect(isWellFormed(result.data))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        // The closing double-quote was stripped, so no new attribute can be injected
        // (the hostile text survives only as a harmless literal inside the value).
        #expect(!svg.contains("onload=\""))
        #expect(!svg.contains("\" onload"))
    }

    @Test func nonFiniteGeometryIsSkippedWithWarning() throws {
        let good = pathElement([.move(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 50, y: 50)), .close])
        let bad = pathElement([.move(CGPoint(x: CGFloat.nan, y: 0)), .line(CGPoint(x: CGFloat.infinity, y: 10)), .close])
        let result = SceneSVGExporter.export(syntheticScene([good, bad]))
        #expect(isWellFormed(result.data))
        #expect(result.warnings.contains(.elementSkipped(elementID: 1)))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        #expect(!svg.lowercased().contains("nan"))
        #expect(!svg.lowercased().contains("inf"))
    }

    @Test func hiddenElementsAreOmitted() throws {
        var hidden = pathElement([.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 10)), .close], fill: SceneColor(red: 0, green: 1, blue: 0))
        hidden.hidden = true
        let visible = pathElement([.move(CGPoint(x: 20, y: 20)), .line(CGPoint(x: 40, y: 40)), .close])
        let svg = String(data: SceneSVGExporter.export(syntheticScene([hidden, visible])).data, encoding: .utf8) ?? ""
        #expect(!svg.contains("#00ff00"))   // the hidden green element is gone
        #expect(svg.contains("#ff0000"))    // the visible red element remains
    }

    @Test func tenThousandElementsExportWellFormed() throws {
        var elements: [Element] = []
        elements.reserveCapacity(10_000)
        for i in 0 ..< 10_000 {
            let x = Double(i % 100), y = Double(i / 100)
            elements.append(pathElement([
                .move(CGPoint(x: x, y: y)), .line(CGPoint(x: x + 1, y: y)),
                .line(CGPoint(x: x + 1, y: y + 1)), .close,
            ], kind: .polygon))
        }
        let result = SceneSVGExporter.export(syntheticScene(elements, page: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(isWellFormed(result.data))
        let svg = String(data: result.data, encoding: .utf8) ?? ""
        #expect(svg.components(separatedBy: "<polygon ").count - 1 == 10_000)
    }

    @Test func hostileImageDimensionsAreDroppedNotCrashed() throws {
        var s = try scene("gate-p4-image.emf")
        // Replace the DIB with an absurd declared size and a tiny buffer: the
        // decoder validates the pixel count and returns nil → the image is dropped,
        // never allocated (§8).
        let hostileDIB = DIB(width: 100_000, height: 100_000, bitCount: 32, compression: .rgb,
                             content: .pixels(bytes: Data(count: 16), stride: 400_000, palette: []))
        outer: for li in s.layers.indices {
            for ei in s.layers[li].elements.indices where s.layers[li].elements[ei].kind == .image {
                s.layers[li].elements[ei].image?.sourceDIB = hostileDIB
                s.layers[li].elements[ei].image?.emfPlusImage = nil
                break outer
            }
        }
        let result = SceneSVGExporter.export(s)
        #expect(isWellFormed(result.data))
        #expect(result.warnings.contains { if case .imageDropped = $0 { return true }; return false })
    }

    // MARK: - Warning summary

    @Test func summarizeGroupsWarnings() throws {
        let warnings: [SVGExportWarning] = [.contentRasterized(elementID: 1), .contentRasterized(elementID: 2), .imageDropped(elementID: 3)]
        let summary = SceneSVGExporter.summarize(warnings)
        #expect(summary[.rasterized] == 2)
        #expect(summary[.image] == 1)
    }
}
