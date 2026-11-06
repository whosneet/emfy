import CoreGraphics
import EMFParse
import EMFRender
import Foundation

/// An RGBA colour in 0…1 components. GDI colours are opaque; the alpha channel
/// exists for EMF+ content and future edits.
public struct SceneColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From an opaque GDI `ColorRef` (0…255 → 0…1).
    public init(_ colorRef: ColorRef) {
        self.init(
            red: Double(colorRef.red) / 255,
            green: Double(colorRef.green) / 255,
            blue: Double(colorRef.blue) / 255,
            alpha: 1
        )
    }

    /// From an EMF+ ARGB colour (0…255 → 0…1, alpha carried).
    public init(_ argb: EMFPlusARGB) {
        self.init(
            red: Double(argb.red) / 255,
            green: Double(argb.green) / 255,
            blue: Double(argb.blue) / 255,
            alpha: Double(argb.alpha) / 255
        )
    }

    /// The nearest opaque `ColorRef` (alpha dropped) — for GDI re-emit (E1b).
    public var colorRef: ColorRef {
        ColorRef(
            red: UInt8((red * 255).rounded().clamped(0, 255)),
            green: UInt8((green * 255).rounded().clamped(0, 255)),
            blue: UInt8((blue * 255).rounded().clamped(0, 255))
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A fill. GDI content lifts a solid colour; EMF+ content lifts a solid colour or
/// a linear gradient. Hatch/path-gradient/texture brushes are not lifted here —
/// those ops lift as passthrough. `color` is the representative solid (a
/// gradient's first stop) used when `gradient` is nil.
public struct SceneFill: Sendable, Equatable {
    public var color: SceneColor
    /// Even-odd (GDI ALTERNATE / EMF+ Alternate) vs winding fill.
    public var evenOdd: Bool
    /// An EMF+ linear gradient; nil for a solid fill (GDI or EMF+).
    public var gradient: SceneGradient?

    public init(color: SceneColor, evenOdd: Bool, gradient: SceneGradient? = nil) {
        self.color = color
        self.evenOdd = evenOdd
        self.gradient = gradient
    }

    /// From an EMF+ lifted fill.
    public init(_ plus: PlusFill, evenOdd: Bool) {
        switch plus {
        case .solid(let argb):
            self.init(color: SceneColor(argb), evenOdd: evenOdd)
        case .linearGradient(let g):
            let representative = g.stops.first.map { SceneColor($0.color) } ?? SceneColor(red: 0, green: 0, blue: 0)
            self.init(color: representative, evenOdd: evenOdd, gradient: SceneGradient(g))
        }
    }
}

/// An EMF+ linear gradient ([MS-EMFPLUS] §2.2.2.24): colour stops along an axis
/// whose endpoints are in the scene's DEVICE space (the renderer applies the
/// device→target fit). Drawn with clamp semantics, matching playback.
public struct SceneGradient: Sendable, Equatable {
    public struct Stop: Sendable, Equatable {
        public var location: Double
        public var color: SceneColor
        public init(location: Double, color: SceneColor) {
            self.location = location
            self.color = color
        }
    }
    public var stops: [Stop]
    public var startDevice: CGPoint
    public var endDevice: CGPoint
    /// WrapMode tiles rather than clamps — flagged for E1b; the render clamps.
    public var tilesWrap: Bool

    public init(stops: [Stop], startDevice: CGPoint, endDevice: CGPoint, tilesWrap: Bool) {
        self.stops = stops
        self.startDevice = startDevice
        self.endDevice = endDevice
        self.tilesWrap = tilesWrap
    }

    public init(_ plus: PlusGradient) {
        self.init(
            stops: plus.stops.map { Stop(location: $0.location, color: SceneColor($0.color)) },
            startDevice: plus.startDevice,
            endDevice: plus.endDevice,
            tilesWrap: plus.tilesWrap
        )
    }
}

/// A resolved stroke. Width and dash lengths are the pen's own units; the final
/// device width is derived at draw time from the element transform, exactly as
/// EMFRender does, so the scene is resolution-independent.
public struct SceneStroke: Sendable, Equatable {
    public enum Dash: Sendable, Equatable {
        case solid
        case dash, dot, dashDot, dashDotDot
        case userStyle([UInt32])
    }

    public var color: SceneColor
    /// One device pixel wide regardless of transform (PS_COSMETIC / width 0).
    public var isCosmetic: Bool
    /// Width in logical units; meaningful only when `isCosmetic` is false.
    public var width: Double
    public var dash: Dash
    public var cap: CGLineCap
    public var join: CGLineJoin
    public var miterLimit: Double

    public init(color: SceneColor, isCosmetic: Bool, width: Double, dash: Dash, cap: CGLineCap, join: CGLineJoin, miterLimit: Double) {
        self.color = color
        self.isCosmetic = isCosmetic
        self.width = width
        self.dash = dash
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
    }

    /// From EMFRender's lifted GDI stroke.
    public init(_ lifted: LiftedStroke) {
        self.init(
            color: SceneColor(lifted.color),
            isCosmetic: lifted.isCosmetic,
            width: lifted.width,
            dash: Dash(lifted.dash),
            cap: lifted.cap,
            join: lifted.join,
            miterLimit: Double(lifted.miterLimit)
        )
    }

    /// From an EMF+ lifted stroke (never cosmetic — EMF+ pens carry a width).
    public init(_ plus: PlusStroke) {
        self.init(
            color: SceneColor(plus.color),
            isCosmetic: false,
            width: plus.width,
            dash: Dash(plus.dash),
            cap: plus.cap,
            join: plus.join,
            miterLimit: plus.miterLimit
        )
    }
}

extension SceneStroke.Dash {
    /// Maps EMFRender's lifted dash (shared by the GDI and EMF+ pens) to the
    /// scene dash.
    init(_ lifted: LiftedStroke.Dash) {
        switch lifted {
        case .solid: self = .solid
        case .dash: self = .dash
        case .dot: self = .dot
        case .dashDot: self = .dashDot
        case .dashDotDot: self = .dashDotDot
        case .userStyle(let entries): self = .userStyle(entries)
        }
    }
}

/// The paint of a drawing element.
public struct SceneStyle: Sendable, Equatable {
    public var fill: SceneFill?
    public var stroke: SceneStroke?
    /// 0…1; 1 for GDI content. EMF+ opacity lives here when lifted later.
    public var opacity: Double

    public init(fill: SceneFill? = nil, stroke: SceneStroke? = nil, opacity: Double = 1) {
        self.fill = fill
        self.stroke = stroke
        self.opacity = opacity
    }
}

/// An editable text run. `fontFamily` is the RESOLVED macOS family (what was
/// drawn); `requestedFamily` is the face the FILE asked for, so the exporter can
/// re-emit it. GDI runs carry `logicalHeight` (unscaled); EMF+ runs carry
/// `emSize` + `emSizeUnit` ([MS-EMFPLUS] §2.1.1.32). `isEMFPlus` marks the
/// source so the renderer replays EMF+ runs and the exporter picks the encoder.
public struct SceneText: Sendable, Equatable {
    public var string: String
    public var fontFamily: String
    public var requestedFamily: String
    public var logicalHeight: Int32
    /// EMF+ em size (0 for GDI content).
    public var emSize: Double
    /// EMF+ size unit ([MS-EMFPLUS] §2.1.1.32; 0 for GDI content).
    public var emSizeUnit: UInt32
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeOut: Bool
    /// Baseline rotation, tenths of a degree counterclockwise (lfEscapement).
    public var escapementTenths: Int32
    public var color: SceneColor
    /// The text reference point in the element's PRE-transform coordinate space:
    /// the drawn device point is `referenceLogical.applying(element.transform)`,
    /// one convention for both engines. GDI content stores the logical reference
    /// and `transform` is logical→device; EMF+ content stores the run's WORLD-space
    /// reference (the importer inverts world→device from the lifted device origin)
    /// and `transform` is the EMF+ world→device. A device-space edit post-composes
    /// into `transform`, so the drawn point moves/scales/rotates with the edit and
    /// both the GDI and EMF+ synthesisers re-emit it by drawing through `transform`.
    public var referenceLogical: CGPoint
    public var alignRawValue: UInt32
    /// True for an EMF+ DrawString run.
    public var isEMFPlus: Bool

    public init(_ lifted: LiftedText) {
        self.string = lifted.string
        self.fontFamily = lifted.fontFamily
        self.requestedFamily = lifted.requestedFamily
        self.logicalHeight = lifted.logicalHeight
        self.emSize = 0
        self.emSizeUnit = 0
        self.bold = lifted.bold
        self.italic = lifted.italic
        self.underline = lifted.underline
        self.strikeOut = lifted.strikeOut
        self.escapementTenths = lifted.escapementTenths
        self.color = SceneColor(lifted.color)
        self.referenceLogical = CGPoint(x: CGFloat(lifted.referenceLogical.x), y: CGFloat(lifted.referenceLogical.y))
        self.alignRawValue = lifted.alignRawValue
        self.isEMFPlus = false
    }

    public init(_ plus: PlusText) {
        self.string = plus.string
        self.fontFamily = plus.resolvedFamily
        self.requestedFamily = plus.requestedFamily
        self.logicalHeight = 0
        self.emSize = plus.emSize
        self.emSizeUnit = plus.sizeUnit
        self.bold = plus.bold
        self.italic = plus.italic
        self.underline = plus.underline
        self.strikeOut = plus.strikeOut
        self.escapementTenths = 0
        self.color = SceneColor(plus.color)
        self.referenceLogical = plus.layoutRectDevice.origin
        self.alignRawValue = plus.stringAlignment
        self.isEMFPlus = true
    }
}

/// An editable image reference. The source DIB bytes are retained so E1b can
/// re-encode them (as compressed PNG, per the E0 owner decision). The
/// destination is kept both in LOGICAL units (for GDI re-emit) and resolved to
/// DEVICE space (for layout/hit-test).
public struct SceneImage: Sendable, Equatable {
    public var destOriginLogical: CGPoint
    public var destSizeLogical: CGSize
    public var destRectDevice: CGRect
    /// The device-space destination as four corners (upper-left, upper-right,
    /// lower-right, lower-left) when a rotation/shear edit made the placement
    /// non-axis-aligned; nil means the destination is the axis-aligned
    /// `destRectDevice` (`destRectDevice` always holds the corners' bounding box).
    /// EMF+ export writes a parallelogram (EmfPlusDrawImagePoints) when present;
    /// GDI/WMF export can only axis-align it and warns (`imageRotated`).
    public var destCornersDevice: [CGPoint]?
    /// The source GDI DIB (GDI content); nil for EMF+ images.
    public var sourceDIB: DIB?
    /// The source EMF+ image object (EMF+ content); nil for GDI images. Holds the
    /// raw bitmap/metafile bytes so E1b can re-encode it (as compressed PNG).
    public var emfPlusImage: EMFPlusImage?
    /// The source crop rectangle in the image's own units (EMF+ content); `.null`
    /// for GDI images.
    public var srcRect: CGRect

    public init(_ lifted: LiftedImage, deviceTransform: CGAffineTransform) {
        self.destOriginLogical = CGPoint(x: CGFloat(lifted.destOrigin.x), y: CGFloat(lifted.destOrigin.y))
        self.destSizeLogical = CGSize(width: CGFloat(lifted.destSize.cx), height: CGFloat(lifted.destSize.cy))
        let logicalRect = CGRect(origin: destOriginLogical, size: destSizeLogical).standardized
        self.destRectDevice = logicalRect.applying(deviceTransform)
        self.destCornersDevice = nil
        self.sourceDIB = lifted.sourceDIB
        self.emfPlusImage = nil
        self.srcRect = .null
    }

    /// From an EMF+ lifted image: the destination is already in DEVICE space.
    public init(_ plus: PlusImage) {
        self.destRectDevice = plus.destRectDevice
        self.destOriginLogical = plus.destRectDevice.origin
        self.destSizeLogical = plus.destRectDevice.size
        // A source DrawImagePoints carried a parallelogram; keep it so re-export
        // re-emits the exact placement rather than its bounding box.
        self.destCornersDevice = plus.destCornersDevice
        self.sourceDIB = nil
        self.emfPlusImage = plus.image
        self.srcRect = plus.srcRect
    }
}

extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}
