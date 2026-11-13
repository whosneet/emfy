import CoreGraphics
import EMFParse
import Foundation

// MARK: - Content report

/// One typeface used in the drawing and the point sizes it appears at.
public struct FontUsage: Sendable, Equatable {
    public var family: String
    /// Distinct print point sizes, ascending (rounded to one decimal).
    public var pointSizes: [Double]
    public var runCount: Int
}

/// Where a colour is used, for the swatch inventory.
public enum ColorRole: Sendable, Equatable, Hashable { case fill, stroke, text }

/// One colour and the number of elements that use it in a given role.
public struct ColorUsage: Sendable, Equatable {
    public var color: SceneColor
    public var role: ColorRole
    public var count: Int
}

/// One distinct image (pixel size + format) and how many times it appears.
public struct ImageUsage: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var format: String
    public var count: Int
}

/// A text run in reading order.
public struct TextRunInfo: Sendable, Equatable {
    public var elementID: Int
    public var string: String
    /// Best-effort print point size, or nil when it could not be resolved.
    public var pointSize: Double?
    public var color: SceneColor
}

/// Element count for one kind.
public struct KindCount: Sendable, Equatable {
    public var kind: ElementKind
    public var count: Int
}

/// Content kept verbatim (passthrough), grouped by a human label.
public struct UnsupportedGroup: Sendable, Equatable {
    public var label: String
    public var count: Int
}

/// The deterministic content report: fonts, colours, images, the text inventory,
/// page size, element counts by kind, and the unsupported-record summary. Pure —
/// no model writes any of it (design §1).
public struct ContentReport: Sendable, Equatable {
    public var pageSizeDevice: CGSize
    /// Physical page size in millimetres, when the source carries a physical
    /// reference (EMF rclFrame / placeable-WMF Inch); nil for a plain WMF.
    public var physicalSizeMM: CGSize?
    public var fonts: [FontUsage]
    public var colors: [ColorUsage]
    public var images: [ImageUsage]
    public var textRuns: [TextRunInfo]
    public var kindCounts: [KindCount]
    public var unsupported: [UnsupportedGroup]
    /// Total editable + passthrough element count.
    public var elementCount: Int
}

// MARK: - Findings

/// How serious a finding is, driving the inspector icon.
public enum FindingSeverity: Sendable, Equatable { case high, medium, low }

/// One accessibility / legibility finding over the scene. `elementIDs` are the
/// elements it concerns (for canvas highlight and the fix).
public struct Finding: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Text contrast below WCAG 2.2 AA against the detected background.
        case lowContrast(ratio: Double, required: Double, text: SceneColor, background: SceneColor, isLarge: Bool)
        /// Text smaller than the tiny-text threshold at print size.
        case tinyText(pointSize: Double)
        /// Two fills that are distinct in normal vision but collapse under a
        /// dichromacy simulation (colour-only distinction risk).
        case colorPair(a: SceneColor, b: SceneColor, under: DrawingColorMath.Dichromacy)
        /// An image with no nearby text label (informational only).
        case unlabelledImage
    }

    public var id: Int
    public var kind: Kind
    public var severity: FindingSeverity
    public var elementIDs: [Int]

    public init(id: Int, kind: Kind, severity: FindingSeverity, elementIDs: [Int]) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.elementIDs = elementIDs
    }
}

// MARK: - Analysis

/// A deterministic accessibility, legibility and content analysis of a `Scene`.
/// Built with pure maths (`DrawingColorMath`) so it is fully unit-testable and
/// never depends on a model (design §1). The AI layer summarises these findings;
/// it never produces them.
public struct DrawingAnalysis: Sendable, Equatable {

    /// Tunable thresholds. Defaults are WCAG 2.2 AA plus conservative heuristics.
    public struct Config: Sendable, Equatable {
        public var pageBackground: SceneColor
        public var tinyTextPoint: Double
        public var largeTextPoint: Double
        public var largeBoldPoint: Double
        public var normalContrast: Double
        public var largeContrast: Double
        /// A colour pair is "distinct" in normal vision at or above this distance.
        public var pairNormalDistinct: Double
        /// A simulated pair is "the same" at or below this distance.
        public var pairSimulatedSame: Double
        /// Adjacency gap as a fraction of the page diagonal.
        public var pairAdjacencyFraction: Double
        /// An image is "unlabelled" when no text run lies within this fraction of
        /// the page diagonal.
        public var imageLabelGapFraction: Double
        /// Cap on filled elements compared pairwise, bounding O(n²) cost (§8).
        public var pairComparisonCap: Int

        public init(
            pageBackground: SceneColor = SceneColor(red: 1, green: 1, blue: 1),
            tinyTextPoint: Double = 8,
            largeTextPoint: Double = 18,
            largeBoldPoint: Double = 14,
            normalContrast: Double = 4.5,
            largeContrast: Double = 3.0,
            pairNormalDistinct: Double = 0.30,
            pairSimulatedSame: Double = 0.10,
            pairAdjacencyFraction: Double = 0.15,
            imageLabelGapFraction: Double = 0.25,
            pairComparisonCap: Int = 200
        ) {
            self.pageBackground = pageBackground
            self.tinyTextPoint = tinyTextPoint
            self.largeTextPoint = largeTextPoint
            self.largeBoldPoint = largeBoldPoint
            self.normalContrast = normalContrast
            self.largeContrast = largeContrast
            self.pairNormalDistinct = pairNormalDistinct
            self.pairSimulatedSame = pairSimulatedSame
            self.pairAdjacencyFraction = pairAdjacencyFraction
            self.imageLabelGapFraction = imageLabelGapFraction
            self.pairComparisonCap = pairComparisonCap
        }
    }

    public var report: ContentReport
    public var findings: [Finding]

    public init(scene: Scene, config: Config = Config()) {
        let elements = scene.elements   // back-to-front z-order
        self.report = Self.buildReport(scene: scene, elements: elements)
        self.findings = Self.buildFindings(scene: scene, elements: elements, config: config)
    }

    // MARK: Geometry helpers

    /// The vertical scale a transform applies: the device length of a unit logical
    /// vertical vector. For a plain scale this is the y-scale; for a rotation/shear
    /// it is the length of the mapped (0,1) vector.
    static func verticalScale(_ t: CGAffineTransform) -> CGFloat {
        (t.c * t.c + t.d * t.d).squareRoot()
    }

    /// Best-effort print point size of a text run, or nil. GDI: `|logicalHeight|`
    /// mapped to device through the element transform, divided by the page's
    /// device-units-per-point. EMF+: the em size by its unit ([MS-EMFPLUS]
    /// §2.1.1.32 UnitType: 3 = Point, 2 = Pixel).
    static func pointSize(of element: Element, in scene: Scene) -> Double? {
        guard let text = element.text else { return nil }
        let perPoint = Double(scene.deviceUnitsPerPoint)
        guard perPoint > 0 else { return nil }
        if text.isEMFPlus {
            guard text.emSize > 0 else { return nil }
            switch text.emSizeUnit {
            case 3: return text.emSize                                   // Point
            case 2: return text.emSize / perPoint                        // Pixel (device)
            default: return text.emSize                                  // treat as points (best effort)
            }
        } else {
            let logical = Double(abs(text.logicalHeight))
            guard logical > 0 else { return nil }
            let deviceHeight = logical * Double(verticalScale(element.transform))
            return deviceHeight / perPoint
        }
    }

    /// Whether a run counts as "large text" for the AA 3:1 threshold: ≥ 18 pt, or
    /// ≥ 14 pt when bold.
    static func isLargeText(pointSize: Double, bold: Bool, config: Config) -> Bool {
        pointSize >= config.largeTextPoint || (bold && pointSize >= config.largeBoldPoint)
    }

    /// The gap between two rectangles (0 when they overlap or touch).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard !a.isNull, !b.isNull else { return .infinity }
        let dx = Swift.max(0, Swift.max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = Swift.max(0, Swift.max(a.minY - b.maxY, b.minY - a.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The background colour behind a text run: the fill of the topmost opaque
    /// solid-filled element, below the run in z-order, whose bounds contain the
    /// run; else the page colour (design §1).
    static func background(forTextIndex index: Int, elements: [Element], config: Config) -> SceneColor {
        let runBounds = elements[index].boundsDevice
        if !runBounds.isNull, index > 0 {
            for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
                let candidate = elements[candidateIndex]
                guard candidate.kind != .text,
                      let fill = candidate.style.fill, fill.gradient == nil,
                      !candidate.boundsDevice.isNull,
                      candidate.boundsDevice.contains(runBounds)
                else { continue }
                return DrawingColorMath.composite(fill.color, over: config.pageBackground)
            }
        }
        return config.pageBackground
    }

    // MARK: Report

    private static func buildReport(scene: Scene, elements: [Element]) -> ContentReport {
        // Fonts.
        var fontSizes: [String: Set<Int>] = [:]       // family → size×10 (dedup rounded)
        var fontRuns: [String: Int] = [:]
        // Colours.
        var colorCounts: [ColorKey: Int] = [:]
        var colorOrder: [ColorKey] = []
        // Images.
        var imageCounts: [ImageKey: Int] = [:]
        var imageOrder: [ImageKey] = []
        // Text inventory.
        var runs: [(element: Element, index: Int)] = []
        // Unsupported.
        var unsupportedCounts: [String: Int] = [:]
        var unsupportedOrder: [String] = []

        func addColor(_ color: SceneColor, _ role: ColorRole) {
            let key = ColorKey(color: color, role: role)
            if colorCounts[key] == nil { colorOrder.append(key) }
            colorCounts[key, default: 0] += 1
        }

        for (index, element) in elements.enumerated() {
            if element.kind == .text, let text = element.text {
                runs.append((element, index))
                if let size = pointSize(of: element, in: scene) {
                    fontSizes[text.fontFamily, default: []].insert(Int((size * 10).rounded()))
                }
                fontRuns[text.fontFamily, default: 0] += 1
                addColor(text.color, .text)
            } else {
                if let fill = element.style.fill { addColor(fill.color, .fill) }
            }
            if let stroke = element.style.stroke { addColor(stroke.color, .stroke) }

            if element.kind == .image, let image = element.image {
                let key = imageKey(for: image)
                if imageCounts[key] == nil { imageOrder.append(key) }
                imageCounts[key, default: 0] += 1
            }

            if element.kind == .passthrough, let reason = element.passthroughReason {
                let label = passthroughLabel(reason)
                if unsupportedCounts[label] == nil { unsupportedOrder.append(label) }
                unsupportedCounts[label, default: 0] += 1
            }
        }

        let fonts = fontSizes.keys.sorted().map { family in
            FontUsage(
                family: family,
                pointSizes: (fontSizes[family] ?? []).map { Double($0) / 10 }.sorted(),
                runCount: fontRuns[family] ?? 0
            )
        } + fontRuns.keys.filter { fontSizes[$0] == nil }.sorted().map {
            FontUsage(family: $0, pointSizes: [], runCount: fontRuns[$0] ?? 0)
        }

        let colors = colorOrder.map { ColorUsage(color: $0.color, role: $0.role, count: colorCounts[$0] ?? 0) }
        let images = imageOrder.map {
            ImageUsage(pixelWidth: $0.width, pixelHeight: $0.height, format: $0.format, count: imageCounts[$0] ?? 0)
        }

        let textRuns = runs
            .sorted { lhs, rhs in orderBefore(lhs.element.boundsDevice, rhs.element.boundsDevice) }
            .map { TextRunInfo(elementID: $0.element.id, string: $0.element.text?.string ?? "", pointSize: pointSize(of: $0.element, in: scene), color: $0.element.text?.color ?? SceneColor(red: 0, green: 0, blue: 0)) }

        let kindCounts = scene.kindCounts
            .map { KindCount(kind: $0.key, count: $0.value) }
            .sorted { kindRank($0.kind) < kindRank($1.kind) }

        let unsupported = unsupportedOrder.map { UnsupportedGroup(label: $0, count: unsupportedCounts[$0] ?? 0) }

        var physical: CGSize?
        if let dpi = scene.deviceUnitsPerInch, dpi > 0 {
            physical = CGSize(width: scene.pageSizeDevice.width / dpi * 25.4, height: scene.pageSizeDevice.height / dpi * 25.4)
        }

        return ContentReport(
            pageSizeDevice: scene.pageSizeDevice,
            physicalSizeMM: physical,
            fonts: fonts,
            colors: colors,
            images: images,
            textRuns: textRuns,
            kindCounts: kindCounts,
            unsupported: unsupported,
            elementCount: elements.count
        )
    }

    // MARK: Findings

    private static func buildFindings(scene: Scene, elements: [Element], config: Config) -> [Finding] {
        var findings: [Finding] = []
        var nextID = 0
        func emit(_ kind: Finding.Kind, _ severity: FindingSeverity, _ ids: [Int]) {
            findings.append(Finding(id: nextID, kind: kind, severity: severity, elementIDs: ids))
            nextID += 1
        }

        let diagonal = (scene.pageSizeDevice.width * scene.pageSizeDevice.width
            + scene.pageSizeDevice.height * scene.pageSizeDevice.height).squareRoot()

        // 1 & 2. Per text run: contrast and tiny text.
        for (index, element) in elements.enumerated() where element.kind == .text {
            guard let text = element.text else { continue }
            let size = pointSize(of: element, in: scene)
            if let size, size < config.tinyTextPoint {
                emit(.tinyText(pointSize: size), .medium, [element.id])
            }
            // Contrast needs a resolvable size for the large-text threshold; use the
            // normal threshold when size is unknown (conservative).
            let bg = background(forTextIndex: index, elements: elements, config: config)
            let fg = DrawingColorMath.composite(text.color, over: bg)
            let large = size.map { isLargeText(pointSize: $0, bold: text.bold, config: config) } ?? false
            let required = large ? config.largeContrast : config.normalContrast
            let ratio = DrawingColorMath.contrastRatio(fg, bg)
            if ratio + 1e-6 < required {
                emit(.lowContrast(ratio: ratio, required: required, text: text.color, background: bg, isLarge: large), .high, [element.id])
            }
        }

        // 3. Colour-only distinction risk between adjacent fills.
        let filled = elements.filter {
            $0.kind != .text && !$0.rejectsMutation && $0.style.fill != nil
                && $0.style.fill?.gradient == nil && !$0.boundsDevice.isNull
        }.prefix(config.pairComparisonCap)
        let filledArray = Array(filled)
        let adjacency = diagonal * config.pairAdjacencyFraction
        for i in filledArray.indices {
            for j in filledArray.indices where j > i {
                let a = filledArray[i], b = filledArray[j]
                guard let ca = a.style.fill?.color, let cb = b.style.fill?.color else { continue }
                guard DrawingColorMath.distance(ca, cb) >= config.pairNormalDistinct else { continue }
                guard gap(a.boundsDevice, b.boundsDevice) <= adjacency else { continue }
                for type in DrawingColorMath.Dichromacy.allCases {
                    let sa = DrawingColorMath.simulate(ca, type)
                    let sb = DrawingColorMath.simulate(cb, type)
                    if DrawingColorMath.distance(sa, sb) <= config.pairSimulatedSame {
                        emit(.colorPair(a: ca, b: cb, under: type), .medium, [a.id, b.id])
                        break
                    }
                }
            }
        }

        // 4. Images without any nearby text label (informational).
        let textBounds = elements.filter { $0.kind == .text && !$0.boundsDevice.isNull }.map(\.boundsDevice)
        let labelGap = diagonal * config.imageLabelGapFraction
        for element in elements where element.kind == .image {
            guard !element.boundsDevice.isNull else { continue }
            let hasLabel = textBounds.contains { gap($0, element.boundsDevice) <= labelGap }
            if !hasLabel { emit(.unlabelledImage, .low, [element.id]) }
        }

        return findings
    }

    // MARK: Keys and labels

    private struct ColorKey: Hashable { var color: SceneColor; var role: ColorRole }
    private struct ImageKey: Hashable { var width: Int; var height: Int; var format: String }

    private static func imageKey(for image: SceneImage) -> ImageKey {
        if let dib = image.sourceDIB {
            return ImageKey(width: Int(dib.width), height: Int(abs(dib.height)), format: "DIB \(dib.bitCount)-bit")
        }
        if let plus = image.emfPlusImage {
            switch plus.content {
            case .bitmap(let header, _):
                let format = header.bitmapDataType == 1 ? "Bitmap (compressed)" : "Bitmap"
                return ImageKey(width: Int(header.width), height: Int(abs(header.height)), format: format)
            case .metafile(let header, _):
                return ImageKey(width: 0, height: 0, format: "Metafile (type \(header.metafileType))")
            }
        }
        return ImageKey(width: Int(image.destRectDevice.width), height: Int(image.destRectDevice.height), format: "Image")
    }

    private static func passthroughLabel(_ reason: PassthroughReason) -> String {
        switch reason {
        case .emfPlus: return "EMF+ content"
        case .comment: return "Comment record"
        case .rasterOp: return "Raster operation"
        case .unknownRecord(let type):
            return EMFRecordType.name(for: type) ?? String(format: "Record 0x%04X", type)
        case .malformed(let type):
            let name = EMFRecordType.name(for: type) ?? String(format: "Record 0x%04X", type)
            return "\(name) (malformed)"
        case .emfPlusUnsupportedBrush: return "EMF+ brush"
        case .emfPlusUnsupportedRecord(let type):
            return EMFPlusRecordType.name(for: type) ?? String(format: "EMF+ record 0x%04X", type)
        case .emfPlusUndecodable(let type):
            let name = EMFPlusRecordType.name(for: type) ?? String(format: "EMF+ record 0x%04X", type)
            return "\(name) (undecodable)"
        }
    }

    /// Reading order: top-to-bottom, then left-to-right, with a line-height band so
    /// runs on the same visual line sort by x.
    private static func orderBefore(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.isNull != b.isNull { return !a.isNull }
        let band = Swift.max(a.height, b.height) * 0.5
        if abs(a.minY - b.minY) > band { return a.minY < b.minY }
        return a.minX < b.minX
    }

    /// A stable ordering rank for element kinds in the counts list.
    private static func kindRank(_ kind: ElementKind) -> Int {
        switch kind {
        case .text: return 0
        case .image: return 1
        case .path: return 2
        case .rect: return 3
        case .roundRect: return 4
        case .ellipse: return 5
        case .polygon: return 6
        case .polyline: return 7
        case .line: return 8
        case .arc: return 9
        case .bezier: return 10
        case .group: return 11
        case .passthrough: return 12
        }
    }
}
