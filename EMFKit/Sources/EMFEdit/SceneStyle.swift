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

/// A solid fill. v1 lifts solid fills only; EMFRender's solid approximation of
/// hatch/pattern brushes is lifted as that colour (flagged on the element).
public struct SceneFill: Sendable, Equatable {
    public var color: SceneColor
    /// Even-odd (GDI ALTERNATE) vs winding (GDI WINDING).
    public var evenOdd: Bool

    public init(color: SceneColor, evenOdd: Bool) {
        self.color = color
        self.evenOdd = evenOdd
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

    /// From EMFRender's lifted stroke.
    public init(_ lifted: LiftedStroke) {
        let dash: Dash
        switch lifted.dash {
        case .solid: dash = .solid
        case .dash: dash = .dash
        case .dot: dash = .dot
        case .dashDot: dash = .dashDot
        case .dashDotDot: dash = .dashDotDot
        case .userStyle(let entries): dash = .userStyle(entries)
        }
        self.init(
            color: SceneColor(lifted.color),
            isCosmetic: lifted.isCosmetic,
            width: lifted.width,
            dash: dash,
            cap: lifted.cap,
            join: lifted.join,
            miterLimit: Double(lifted.miterLimit)
        )
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

/// An editable text run. Font family is the RESOLVED macOS family (what was
/// drawn); the logical height is unscaled so edits stay resolution-independent.
public struct SceneText: Sendable, Equatable {
    public var string: String
    public var fontFamily: String
    public var logicalHeight: Int32
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeOut: Bool
    /// Baseline rotation, tenths of a degree counterclockwise (lfEscapement).
    public var escapementTenths: Int32
    public var color: SceneColor
    /// Reference point in LOGICAL units (the run's anchor).
    public var referenceLogical: CGPoint
    public var alignRawValue: UInt32

    public init(_ lifted: LiftedText) {
        self.string = lifted.string
        self.fontFamily = lifted.fontFamily
        self.logicalHeight = lifted.logicalHeight
        self.bold = lifted.bold
        self.italic = lifted.italic
        self.underline = lifted.underline
        self.strikeOut = lifted.strikeOut
        self.escapementTenths = lifted.escapementTenths
        self.color = SceneColor(lifted.color)
        self.referenceLogical = CGPoint(x: CGFloat(lifted.referenceLogical.x), y: CGFloat(lifted.referenceLogical.y))
        self.alignRawValue = lifted.alignRawValue
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
    public var sourceDIB: DIB?

    public init(_ lifted: LiftedImage, deviceTransform: CGAffineTransform) {
        self.destOriginLogical = CGPoint(x: CGFloat(lifted.destOrigin.x), y: CGFloat(lifted.destOrigin.y))
        self.destSizeLogical = CGSize(width: CGFloat(lifted.destSize.cx), height: CGFloat(lifted.destSize.cy))
        let logicalRect = CGRect(origin: destOriginLogical, size: destSizeLogical).standardized
        self.destRectDevice = logicalRect.applying(deviceTransform)
        self.sourceDIB = lifted.sourceDIB
    }
}

extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}
