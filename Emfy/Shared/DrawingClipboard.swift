import CoreGraphics

/// What a Print / Copy / Drag of the open document should render from (F1). When the
/// document is being edited and has diverged from the opened version, the output must
/// reflect the EDITED scene (design calls 1 and 2); a canvas selection in edit mode
/// narrows Copy and drag to just those elements (a subset scene, like the E2b ghost);
/// otherwise the original prepared metafile is used. Pure, so the decision is tested
/// once and reused by every surface.
enum OutputSource: Equatable, Sendable {
    /// Render the original prepared metafile (viewer mode, or an unedited document).
    case original
    /// Render the whole edited scene (edit mode, diverged, no narrowing selection).
    case editedScene
    /// Render only these elements as a subset scene (Copy/drag with a selection).
    case selectionSubset(Set<Int>)

    /// The source for a whole-drawing output (Print always; Copy/drag with no
    /// selection): the edited scene when editing has diverged, else the original.
    static func wholeDrawing(isEditing: Bool, hasDiverged: Bool) -> OutputSource {
        isEditing && hasDiverged ? .editedScene : .original
    }

    /// The source for Copy / drag: a selection subset when editing with a non-empty
    /// selection, otherwise the whole-drawing source.
    static func forCopy(isEditing: Bool, hasDiverged: Bool, selection: Set<Int>) -> OutputSource {
        if isEditing, !selection.isEmpty { return .selectionSubset(selection) }
        return wholeDrawing(isEditing: isEditing, hasDiverged: hasDiverged)
    }
}

/// The set of representations Copy and drag place for a drawing (F1 design calls 2
/// and 3), as a pure plan computed from the document's state and the Export settings.
///
/// Copy/drag always offer the drawing as vector **PDF** and as **PNG** (at the
/// Settings default scale, reduced to the shared 32 MP area cap through
/// `ExportScale`). The original file is offered as `com.microsoft.emf` ONLY when it
/// cleanly applies — the whole drawing (no selection subset) of an unedited `.emf`
/// document — because once the drawing is edited, is a WMF, or is narrowed to a
/// selection, the bytes on disk no longer match what is being copied.
enum DrawingClipboard {
    /// The uniform type identifier for a raw EMF payload / file.
    static let emfTypeIdentifier = "com.microsoft.emf"

    /// Whether the original type cleanly represents what Copy/drag is producing.
    enum OriginalType: Equatable, Sendable {
        case emf
        case other
    }

    /// One representation to place, in priority order. PDF is first because it is the
    /// richest vector form and the one most apps prefer to paste.
    enum Representation: Equatable, Sendable {
        case pdf
        case png(width: Int, height: Int, scale: Int)
        case originalEMF
    }

    /// Whether the original bytes still represent exactly what is being copied: only
    /// an unedited, non-subset `.emf` whole drawing qualifies.
    static func includesOriginal(isEdited: Bool, isSubset: Bool, originalType: OriginalType) -> Bool {
        !isEdited && !isSubset && originalType == .emf
    }

    /// The ordered representations for Copy / drag.
    ///
    /// - `naturalSize`: the drawing's device-pixel size driving the PNG dimensions.
    /// - `pngScale`: the requested PNG multiplier (the Default PNG scale setting).
    /// - `areaCap`: the shared export area cap (`ExportScale.areaCap`).
    /// - `isEdited`/`isSubset`/`originalType`: gate whether the original EMF is added.
    static func representations(
        naturalSize: CGSize,
        pngScale: Int,
        areaCap: Int,
        isEdited: Bool,
        isSubset: Bool,
        originalType: OriginalType
    ) -> [Representation] {
        let selected = ExportScale.select(
            baseWidth: Int(naturalSize.width.rounded()),
            baseHeight: Int(naturalSize.height.rounded()),
            requested: pngScale,
            areaCap: areaCap
        )
        var reps: [Representation] = [
            .pdf,
            .png(width: selected.width, height: selected.height, scale: selected.multiplier),
        ]
        if includesOriginal(isEdited: isEdited, isSubset: isSubset, originalType: originalType) {
            reps.append(.originalEMF)
        }
        return reps
    }
}
