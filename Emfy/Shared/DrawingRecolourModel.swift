import CoreGraphics
import EMFEdit
import Foundation
import Observation

// MARK: - Recolour to a palette (X2a)
//
// The "Recolour…" sheet's view-model: a deterministic (no-AI) recolour of the open
// drawing to a palette — greyscale, colour-blind-safe, print, or the user's brand
// colours. Scope is the current selection if any, else the whole drawing. It shows a
// before/after preview and the old→new mapping list, and applies as ONE grouped
// "Recolour" undo through DocumentSession.applyGroupedCommands (the same path a user edit
// takes). Pure palette maths lives in EMFEdit's `PaletteRecolour`; this model only drives
// the UI and the preview.

@MainActor
@Observable
final class DrawingRecolourModel {

    /// The selectable modes (the brand mode carries the user's entered colours).
    enum Mode: Equatable, Hashable, CaseIterable {
        case greyscale, colourBlindSafe, print, brand

        var title: String {
            switch self {
            case .greyscale: return "Greyscale"
            case .colourBlindSafe: return "Colour-blind safe"
            case .print: return "Print"
            case .brand: return "Brand colours"
            }
        }
    }

    /// One old→new swatch pair for the mapping list.
    struct MappingRow: Identifiable, Equatable {
        let id = UUID()
        var from: SceneColor
        var to: SceneColor
    }

    var mode: Mode = .greyscale { didSet { if mode != oldValue { recompute() } } }
    /// Brand hex strings the user enters (2–8 used; invalid/blank ignored).
    var brandHex: [String] = ["", ""] { didSet { if mode == .brand { recompute() } } }

    private(set) var beforeImage: CGImage?
    private(set) var afterImage: CGImage?
    private(set) var mappingRows: [MappingRow] = []
    /// The scope description ("the whole drawing" / "N selected elements").
    private(set) var scopeDescription = "the whole drawing"

    @ObservationIgnored private weak var session: DocumentSession?
    @ObservationIgnored private var scene: Scene?
    @ObservationIgnored private var ids: Set<Int>?

    /// The parsed brand colours (2–8), or empty when fewer than two are valid.
    var brandColours: [SceneColor] {
        let parsed = brandHex.compactMap { PlanColor.parse($0) }
        return parsed.count >= 2 ? Array(parsed.prefix(8)) : []
    }

    /// Whether Apply is available: there is at least one colour change to make, and (for
    /// brand) at least two valid brand colours.
    var canApply: Bool {
        if mode == .brand, brandColours.count < 2 { return false }
        return !mappingRows.isEmpty
    }

    /// Points the model at the open drawing; enters edit mode so element ids match what
    /// will be applied, then builds the first preview. `selection` scopes the recolour.
    func start(session: DocumentSession, selection: Set<Int>) async {
        self.session = session
        if session.editing != .editing { await session.beginEditing() }
        guard session.editing == .editing, let scene = session.editingScene else { return }
        self.scene = scene
        let scoped = selection.intersection(Set(scene.editableElements.map(\.id)))
        self.ids = scoped.isEmpty ? nil : scoped
        scopeDescription = scoped.isEmpty
            ? "the whole drawing"
            : "\(scoped.count) selected element\(scoped.count == 1 ? "" : "s")"
        recompute()
    }

    private var paletteMode: PaletteRecolourMode {
        switch mode {
        case .greyscale: return .greyscale
        case .colourBlindSafe: return .colourBlindSafe
        case .print: return .print
        case .brand: return .brand(colours: brandColours)
        }
    }

    private func recompute() {
        guard let scene else { return }
        let mode = paletteMode
        let ids = self.ids
        mappingRows = PaletteRecolour.mapping(for: scene, ids: ids, mode: mode).map {
            MappingRow(from: $0.from, to: $0.to)
        }
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.render(scene: scene, ids: ids, mode: mode)
            }.value
            guard let self else { return }
            self.beforeImage = rendered.before
            self.afterImage = rendered.after
        }
    }

    /// Applies the recolour as one grouped "Recolour" undo. A no-op when nothing changes.
    func apply() {
        guard let scene, let session, session.editing == .editing else { return }
        let commands = PaletteRecolour.commands(for: scene, ids: ids, mode: paletteMode)
        guard !commands.isEmpty else { return }
        session.applyGroupedCommands(commands, name: .group("edit.action.recolour"))
    }

    private struct Rendered: @unchecked Sendable { let before: CGImage?; let after: CGImage? }

    nonisolated private static func render(scene: Scene, ids: Set<Int>?, mode: PaletteRecolourMode) -> Rendered {
        let before = SceneRenderer.makeImage(scene, scale: 2)
        var history = SceneHistory(scene: scene)
        for command in PaletteRecolour.commands(for: scene, ids: ids, mode: mode) { try? history.apply(command) }
        let after = SceneRenderer.makeImage(history.scene, scale: 2)
        return Rendered(before: before, after: after)
    }
}
