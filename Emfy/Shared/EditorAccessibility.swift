import CoreGraphics
import EMFEdit

/// The platform-neutral accessibility model for the editor canvas (C5g, audit finding
/// A1). Both the iOS (`UIAccessibilityElement`) and the macOS (`NSAccessibilityElement`)
/// canvases build their assistive-technology tree from this, and every custom action it
/// describes routes back through the SAME scene commands and undo as a pointer edit —
/// there is no second edit path. Pure and tested: no view, window, UIKit or AppKit
/// dependency, so the element list, labels, action→command mapping and the selection
/// cycling order are all unit-tested on scenes alone.
///
/// Visibility policy (stated for the gate): elements on a HIDDEN layer, hidden
/// elements, and passthrough content are OMITTED (not shown, or not editable). LOCKED
/// elements — an element with `locked`, or any element on a locked layer — are INCLUDED
/// and announced as locked with no actions, so a VoiceOver / Switch Control user knows
/// they are present but cannot be moved. Everything else exposes the full action set.
enum EditorAccessibility {

    // MARK: - Element descriptor

    /// One element exposed to assistive technologies, carrying everything a platform
    /// accessibility element needs: label, value, device bounds (the canvas converts
    /// these to screen/container space so the frame tracks zoom and scroll), selection
    /// and locked state, and the Voice Control input labels.
    struct ElementDescriptor: Equatable {
        var id: Int
        var kind: ElementKind
        var label: String
        var value: String
        var boundsDevice: CGRect
        var isSelected: Bool
        var isLocked: Bool
        var isText: Bool
        /// Short spoken names for Voice Control ("Tap Rectangle"): the kind, plus the
        /// text content for a run.
        var userInputLabels: [String]

        /// The custom actions offered for this element: none when locked; just Select
        /// when not selected; the full editing set (text edit, move, resize, arrange,
        /// delete) when selected.
        var actions: [Action] {
            if isLocked { return [] }
            if !isSelected { return [.select] }
            var result: [Action] = []
            if isText { result.append(.editText) }
            result += [
                .moveLeft, .moveRight, .moveUp, .moveDown,
                .moveLeftLarge, .moveRightLarge, .moveUpLarge, .moveDownLarge,
                .makeBigger, .makeSmaller,
                .bringToFront, .sendToBack, .delete,
            ]
            return result
        }
    }

    // MARK: - Actions

    /// A custom accessibility action over an element. Every action maps to a scene
    /// command (move / resize / arrange, via `command(for:elementID:in:)`), to a
    /// selection change (`select`), to the text editor (`editText`), or to the delete
    /// path (`delete`) — the same operations the pointer and keyboard drive.
    enum Action: Equatable, CaseIterable {
        case select
        case moveLeft, moveRight, moveUp, moveDown
        case moveLeftLarge, moveRightLarge, moveUpLarge, moveDownLarge
        case makeBigger, makeSmaller
        case bringToFront, sendToBack
        case delete
        case editText

        /// The user-facing action name (app-layer display text).
        var name: String {
            switch self {
            case .select: return "Select"
            case .moveLeft: return "Move left"
            case .moveRight: return "Move right"
            case .moveUp: return "Move up"
            case .moveDown: return "Move down"
            case .moveLeftLarge: return "Move left a large step"
            case .moveRightLarge: return "Move right a large step"
            case .moveUpLarge: return "Move up a large step"
            case .moveDownLarge: return "Move down a large step"
            case .makeBigger: return "Make bigger"
            case .makeSmaller: return "Make smaller"
            case .bringToFront: return "Bring to front"
            case .sendToBack: return "Send to back"
            case .delete: return "Delete"
            case .editText: return "Edit text"
            }
        }
    }

    // MARK: - Element list

    /// The editable elements exposed to assistive technologies, in reading order
    /// (top-to-bottom, then left-to-right). See the type's visibility policy for what is
    /// included.
    static func descriptors(in scene: Scene, selection: EditorSelection) -> [ElementDescriptor] {
        var out: [ElementDescriptor] = []
        for layer in scene.layers where !layer.hidden {
            let layerLocked = layer.locked
            for element in layer.elements {
                guard !element.hidden,
                      element.kind != .passthrough,
                      element.passthroughReason == nil else { continue }
                let bounds = element.selectionBoundsDevice.standardized
                guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else { continue }
                let locked = element.locked || layerLocked
                out.append(ElementDescriptor(
                    id: element.id,
                    kind: element.kind,
                    label: label(for: element),
                    value: value(for: element),
                    boundsDevice: bounds,
                    isSelected: selection.contains(element.id),
                    isLocked: locked,
                    isText: element.kind == .text && !locked,
                    userInputLabels: userInputLabels(for: element)))
            }
        }
        return out.sorted(by: inReadingOrder(scene: scene))
    }

    /// A strict reading-order comparator: elements are grouped into horizontal rows
    /// (device `minY` quantised to a cell so items roughly on a line read together),
    /// then ordered left-to-right within a row, then by id so the order is total and
    /// transitivity-safe for `sorted`.
    private static func inReadingOrder(scene: Scene) -> (ElementDescriptor, ElementDescriptor) -> Bool {
        let cell = max(1, abs(scene.pageBoundsDevice.height) / 50)
        return { a, b in
            let rowA = (a.boundsDevice.minY / cell).rounded(.down)
            let rowB = (b.boundsDevice.minY / cell).rounded(.down)
            if rowA != rowB { return rowA < rowB }
            if a.boundsDevice.minX != b.boundsDevice.minX { return a.boundsDevice.minX < b.boundsDevice.minX }
            return a.id < b.id
        }
    }

    // MARK: - Labels and values

    /// The spoken label for an element: its kind, plus its content — the text string,
    /// or a shape's fill/outline colour (e.g. "Text, Quarterly Results", "Rectangle,
    /// red fill", "Image").
    static func label(for element: Element) -> String {
        switch element.kind {
        case .text:
            let raw = element.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Text, \(raw.isEmpty ? "empty" : truncated(raw))"
        case .image:
            return "Image"
        case .rect: return shapeLabel("Rectangle", element)
        case .roundRect: return shapeLabel("Rounded rectangle", element)
        case .ellipse: return shapeLabel("Ellipse", element)
        case .line: return shapeLabel("Line", element)
        case .polygon: return shapeLabel("Polygon", element)
        case .polyline: return shapeLabel("Polyline", element)
        case .arc: return shapeLabel("Arc", element)
        case .bezier: return shapeLabel("Curve", element)
        case .path: return shapeLabel("Shape", element)
        case .group: return "Group"
        case .passthrough: return "Content"
        }
    }

    private static func shapeLabel(_ name: String, _ element: Element) -> String {
        if let fill = element.style.fill {
            return "\(name), \(colorName(fill.color)) fill"
        }
        if let stroke = element.style.stroke {
            return "\(name), \(colorName(stroke.color)) outline"
        }
        return name
    }

    /// A brief position and size for the element, in the source's device units.
    static func value(for element: Element) -> String {
        let b = element.selectionBoundsDevice.standardized
        guard !b.isNull, b.width.isFinite, b.height.isFinite else { return "" }
        func round(_ v: CGFloat) -> Int { Int(v.rounded()) }
        return "x \(round(b.minX)), y \(round(b.minY)), \(round(b.width)) by \(round(b.height))"
    }

    /// Short Voice Control names so "Tap Rectangle" or "Tap <first words>" works.
    static func userInputLabels(for element: Element) -> [String] {
        switch element.kind {
        case .text:
            let raw = element.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let words = raw.split(separator: " ").prefix(3).joined(separator: " ")
            return words.isEmpty ? ["Text"] : [words, "Text"]
        case .image: return ["Image"]
        case .rect: return ["Rectangle"]
        case .roundRect: return ["Rounded rectangle"]
        case .ellipse: return ["Ellipse"]
        case .line: return ["Line"]
        case .polygon: return ["Polygon"]
        case .polyline: return ["Polyline"]
        case .arc: return ["Arc"]
        case .bezier: return ["Curve"]
        case .path: return ["Shape"]
        case .group: return ["Group"]
        case .passthrough: return ["Content"]
        }
    }

    private static func truncated(_ string: String, max: Int = 60) -> String {
        let flattened = string.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > max else { return flattened }
        return String(flattened.prefix(max)) + "…"
    }

    // MARK: - Colour naming

    /// A table of named colours in sRGB (0…1).
    private static let namedColors: [(name: String, rgb: (Double, Double, Double))] = [
        ("black", (0, 0, 0)),
        ("white", (1, 1, 1)),
        ("grey", (0.5, 0.5, 0.5)),
        ("red", (0.85, 0.1, 0.1)),
        ("green", (0.1, 0.6, 0.2)),
        ("blue", (0.1, 0.25, 0.85)),
        ("yellow", (0.95, 0.9, 0.1)),
        ("orange", (0.95, 0.55, 0.1)),
        ("purple", (0.55, 0.15, 0.6)),
        ("brown", (0.55, 0.35, 0.18)),
        ("pink", (0.95, 0.65, 0.75)),
        ("cyan", (0.1, 0.75, 0.85)),
        ("magenta", (0.85, 0.1, 0.65)),
    ]

    /// The nearest basic colour name for a scene colour, by Euclidean distance in RGB.
    static func colorName(_ color: SceneColor) -> String {
        var best = namedColors[0].name
        var bestDistance = Double.greatestFiniteMagnitude
        for entry in namedColors {
            let dr = color.red - entry.rgb.0
            let dg = color.green - entry.rgb.1
            let db = color.blue - entry.rgb.2
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = entry.name
            }
        }
        return best
    }

    // MARK: - Action → scene command

    /// The small move step in device units: 1% of the smaller page dimension, floored at
    /// 1 so a nudge is visible on any document. The large step is 10×.
    static func smallMoveStep(in scene: Scene) -> CGFloat {
        max(1, min(abs(scene.pageBoundsDevice.width), abs(scene.pageBoundsDevice.height)) / 100)
    }
    static func largeMoveStep(in scene: Scene) -> CGFloat { smallMoveStep(in: scene) * 10 }

    /// The Make bigger / Make smaller resize factor.
    static let growFactor: CGFloat = 1.1

    /// The scene command an action issues over element `id`, or nil for actions the
    /// caller routes another way: `.select` and `.editText` change selection / open the
    /// text editor; `.delete` goes through the delete path (`DocumentSession.deleteSelection`)
    /// so the selection travels with the elements. `nil` is also returned when the
    /// element is missing or a resize has no usable bounds. The command is applied
    /// through the SAME `DocumentSession.apply` path as a pointer edit, so it is exactly
    /// one undo step.
    static func command(for action: Action, elementID id: Int, in scene: Scene) -> SceneCommand? {
        guard let element = scene.elements.first(where: { $0.id == id }) else { return nil }
        switch action {
        case .select, .editText, .delete:
            return nil
        case .moveLeft:  return move(id, dx: -smallMoveStep(in: scene), dy: 0)
        case .moveRight: return move(id, dx: smallMoveStep(in: scene), dy: 0)
        case .moveUp:    return move(id, dx: 0, dy: -smallMoveStep(in: scene))
        case .moveDown:  return move(id, dx: 0, dy: smallMoveStep(in: scene))
        case .moveLeftLarge:  return move(id, dx: -largeMoveStep(in: scene), dy: 0)
        case .moveRightLarge: return move(id, dx: largeMoveStep(in: scene), dy: 0)
        case .moveUpLarge:    return move(id, dx: 0, dy: -largeMoveStep(in: scene))
        case .moveDownLarge:  return move(id, dx: 0, dy: largeMoveStep(in: scene))
        case .makeBigger:  return scale(element, factor: growFactor)
        case .makeSmaller: return scale(element, factor: 1 / growFactor)
        case .bringToFront: return .arrange(ids: [id], .toFront)
        case .sendToBack:   return .arrange(ids: [id], .toBack)
        }
    }

    // Device `minY` is the visual TOP on both platforms (the Mac mapping folds in the
    // y-flip, the iOS one maps straight through), so "up" is a decrease in device y on
    // both — see `EditorArrange`.
    private static func move(_ id: Int, dx: CGFloat, dy: CGFloat) -> SceneCommand {
        .translate(ids: [id], dx: Double(dx), dy: Double(dy))
    }

    private static func scale(_ element: Element, factor: CGFloat) -> SceneCommand? {
        let b = element.selectionBoundsDevice.standardized
        guard !b.isNull, b.width > 0, b.height > 0 else { return nil }
        let centre = CGPoint(x: b.midX, y: b.midY)
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -centre.x, y: -centre.y)
        return .applyTransform(ids: [element.id], transform)
    }

    // MARK: - Selection cycling (keyboard)

    /// The element id to select when cycling the selection with Tab / Shift-Tab through
    /// the unlocked elements in reading order (macOS keyboard selection). `forward`
    /// advances and wraps; the first/last element is chosen when nothing is selected
    /// yet. `nil` when there is nothing selectable.
    static func cycleSelection(from current: Set<Int>, forward: Bool, in scene: Scene) -> Int? {
        let order = descriptors(in: scene, selection: EditorSelection(current))
            .filter { !$0.isLocked }
            .map(\.id)
        guard !order.isEmpty else { return nil }
        guard let currentID = order.first(where: { current.contains($0) }),
              let index = order.firstIndex(of: currentID) else {
            return forward ? order.first : order.last
        }
        let next = forward ? (index + 1) % order.count : (index - 1 + order.count) % order.count
        return order[next]
    }

    // MARK: - DEBUG dump

    /// A plain-text dump of the accessibility tree (label, value, traits, actions) for a
    /// scene's current selection — the evidence the DEBUG hook prints. It reads the SAME
    /// descriptors the live canvases build their elements from.
    static func debugDump(in scene: Scene, selection: EditorSelection) -> String {
        let descriptors = descriptors(in: scene, selection: selection)
        var lines = ["accessibility tree — \(descriptors.count) element(s), reading order:"]
        for (index, descriptor) in descriptors.enumerated() {
            var traits = [descriptor.isLocked ? "staticText(locked)" : "button"]
            if descriptor.isSelected { traits.append("selected") }
            let actions = descriptor.actions.map(\.name).joined(separator: ", ")
            lines.append("  [\(index)] \(descriptor.label)")
            lines.append("        value: \(descriptor.value)")
            lines.append("        traits: [\(traits.joined(separator: ", "))]")
            lines.append("        voiceControl: [\(descriptor.userInputLabels.joined(separator: ", "))]")
            lines.append("        actions: [\(actions)]")
        }
        return lines.joined(separator: "\n")
    }
}
