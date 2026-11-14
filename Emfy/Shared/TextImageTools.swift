import CoreGraphics
import EMFEdit
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The text-creation tool's shared geometry and defaults (E3c design call 1): it
/// builds the new text element a click/tap inserts, identical on Mac and iPad. The
/// element reads "Text", 18 pt, black, baseline-left under the pointer; the text
/// popover then opens on it and the first `setText` coalesces into one "Insert Text"
/// undo (`DocumentSession.beginInsertText`).
enum TextToolInsertion {
    /// The placeholder a freshly-inserted text element shows until the user types.
    static let placeholder = "Text"
    /// The default on-page point size for a new text run.
    static let defaultPointSize: Double = 18

    /// The new text element at `originDevice` (device space) for `scene`, plus its
    /// unique id so the caller can select it and anchor the popover.
    static func element(originDevice: CGPoint, in scene: Scene) -> (element: Element, id: Int) {
        let id = SceneFactory.nextElementID(in: scene)
        let element = SceneFactory.makeText(
            string: placeholder, originDevice: originDevice, family: preferredFamily(),
            pointSize: defaultPointSize, color: SceneColor(red: 0, green: 0, blue: 0),
            id: id, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
        return (element, id)
    }

    /// "Helvetica Neue" when installed, else "Arial" (design call 1). Queries the
    /// platform font list directly (not the SwiftUI `InstalledFonts`, so this stays
    /// compilable into the test bundle).
    static func preferredFamily() -> String {
        let preferred = "Helvetica Neue"
        #if canImport(AppKit)
        let available = NSFontManager.shared.availableFontFamilies
        #elseif canImport(UIKit)
        let available = UIFont.familyNames
        #else
        let available: [String] = []
        #endif
        return available.contains(preferred) ? preferred : "Arial"
    }
}

/// Lets assistive-technology users (VoiceOver, Switch Control, Voice Control) use the
/// shape, text and pen tools (audit R2A1). Those tools otherwise need a pointer tap on
/// the canvas to place an element, which AT users can't produce. Activating an armed
/// tool's button, or the canvas container's "Insert at centre" accessibility action,
/// inserts ONE default-size element at the centre of the visible area through the SAME
/// `ShapeToolInsertion` / `TextToolInsertion` / `PenCommit` command path (one undo
/// step) as a pointer insert; the caller then selects it and posts a layout change.
/// Pure so the insert decision is unit-tested without a canvas or assistive technology.
enum AccessibilityToolInsertion {
    /// Which armed tool an accessibility insert should serve.
    enum Tool: Equatable {
        case shape(ShapeToolKind)
        case text
        case pen
    }

    /// What the canvas should do to honour the insert.
    enum Plan {
        /// Apply a scene command (a shape or a pen stroke) and select `id`.
        case command(SceneCommand, id: Int)
        /// Begin the insert-text group for a new text element and select `id`.
        case insertText(Element, id: Int)

        /// The new element's id, for selecting it and posting a focused layout change.
        var elementID: Int {
            switch self {
            case .command(_, let id): return id
            case .insertText(_, let id): return id
            }
        }
    }

    /// The default shape/pen/text side in device units for `scene` (the 100 pt default
    /// a pointer tap places).
    static func defaultSideDevice(in scene: Scene) -> CGFloat {
        ShapeToolGeometry.pointsToDevice(
            ShapeToolGeometry.defaultSidePoints, deviceUnitsPerPoint: scene.deviceUnitsPerPoint)
    }

    /// The insert plan for the armed `tool` at `centreDevice` in `scene`, or nil when the
    /// tool can't produce a default element. For the pen — freehand drawing can't be
    /// expressed through assistive tech — this inserts a default straight stroke the user
    /// can then move, resize or delete, which the HIG prefers to a dead-end "not
    /// available" message.
    static func plan(for tool: Tool, centreDevice: CGPoint, pen: PenStyle, in scene: Scene) -> Plan? {
        switch tool {
        case .shape(let kind):
            let side = defaultSideDevice(in: scene)
            let rect = ShapeToolGeometry.defaultRect(centreDevice: centreDevice, sideDevice: side)
            let insertion = ShapeToolInsertion.command(kind: kind, rectDevice: rect, in: scene)
            return .command(insertion.command, id: insertion.id)
        case .text:
            let insertion = TextToolInsertion.element(originDevice: centreDevice, in: scene)
            return .insertText(insertion.element, id: insertion.id)
        case .pen:
            let side = defaultSideDevice(in: scene)
            let p0 = CGPoint(x: centreDevice.x - side / 2, y: centreDevice.y)
            let p1 = CGPoint(x: centreDevice.x + side / 2, y: centreDevice.y)
            guard let insertion = PenCommit.command(
                rawDevicePoints: [p0, p1], held: false,
                minSpacing: 0.5, rdpTolerance: 0.75, pen: pen, in: scene) else { return nil }
            return .command(insertion.command, id: insertion.id)
        }
    }
}

/// The image-insert tool's shared ingest + placement (E3c design call 2): it decodes
/// untrusted image bytes with the §8 caps, re-encodes pixels only (metadata stripped),
/// fits the result to 50% of the page's smaller dimension, and builds the element.
enum ImageInsertTool {
    /// The new image element for `imageData`, fitted into `pageBoundsDevice` (centred on
    /// the page, or on `centreDevice` for a drop), plus its unique id — or a typed
    /// failure the caller toasts.
    static func element(
        imageData: Data, pageBoundsDevice: CGRect, centreDevice: CGPoint?, in scene: Scene
    ) -> Result<(element: Element, id: Int), SceneImageImport.Failure> {
        switch SceneImageImport.decode(imageData) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let cg):
            let rect = SceneFactory.fitImageRect(
                imagePixelSize: CGSize(width: cg.width, height: cg.height),
                pageBoundsDevice: pageBoundsDevice, centreDevice: centreDevice)
            let id = SceneFactory.nextElementID(in: scene)
            guard let element = SceneFactory.makeImage(cgImage: cg, destRectDevice: rect, id: id) else {
                return .failure(.undecodable)
            }
            return .success((element, id))
        }
    }
}
