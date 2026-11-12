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
