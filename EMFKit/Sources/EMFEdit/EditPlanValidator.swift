import CoreGraphics
import Foundation

// MARK: - Edit-plan validation (X2a)
//
// Checks a decoded `EditPlan` against the scene it would run on BEFORE anything is
// applied: every id exists and is editable, every number is finite and bounded, colours
// parse, text is capped and the operation count is capped. An invalid plan applies
// NOTHING — the view model refuses to preview or apply a plan with any problem. Deleting
// the entire drawing is allowed but flagged as a prominent warning the preview must show.
//
// Security (CLAUDE.md §8): the plan is built from untrusted model output. All of its
// numbers reach `commands(in:)` → arithmetic, so each is range-checked here first; the
// checks themselves never trap (finite guards, no force-unwrap, no unchecked maths).

/// One problem with a plan. Any problem makes the plan non-applicable.
public enum EditPlanProblem: Sendable, Equatable {
    /// The plan has no operations.
    case emptyPlan
    /// More operations than the cap (op index not meaningful).
    case tooManyOperations(count: Int, limit: Int)
    /// An operation targets no elements.
    case emptyTargetList(op: Int)
    /// A targeted element id is not in the scene.
    case elementNotFound(op: Int, id: Int)
    /// A targeted element is locked or passthrough (verbatim content).
    case elementNotEditable(op: Int, id: Int)
    /// A `setText`/`setFontSize`/`setFontFamily` targeted a non-text element.
    case notTextElement(op: Int, id: Int)
    /// A colour string did not parse.
    case invalidColor(op: Int, hex: String)
    /// A number was NaN or infinite.
    case numberNotFinite(op: Int)
    /// A move delta exceeds a sane multiple of the page.
    case moveOutOfRange(op: Int)
    /// A scale factor is not strictly positive, or exceeds the cap.
    case scaleOutOfRange(op: Int, factor: Double)
    /// A font size (points) is outside the accepted range.
    case fontSizeOutOfRange(op: Int, points: Double)
    /// A line width (points) is not strictly positive, or exceeds the cap.
    case lineWidthOutOfRange(op: Int, points: Double)
    /// A replacement string exceeds the length cap.
    case textTooLong(op: Int, length: Int, limit: Int)
}

/// A non-fatal note the preview must surface prominently.
public enum EditPlanWarning: Sendable, Equatable {
    /// The plan deletes every editable element in the drawing.
    case deletesEntireDrawing(count: Int)
}

/// The result of validating a plan.
public struct EditPlanValidation: Sendable, Equatable {
    public var problems: [EditPlanProblem]
    public var warnings: [EditPlanWarning]

    public init(problems: [EditPlanProblem], warnings: [EditPlanWarning]) {
        self.problems = problems
        self.warnings = warnings
    }

    /// A plan with no problems may be previewed and applied.
    public var isApplicable: Bool { problems.isEmpty }
}

public enum EditPlanValidator {

    /// The bounds the validator enforces. Defaults match the brief: ≤ 200 ops, text ≤
    /// 5000 chars, font 1…1000 pt, line width ≤ 1000 pt, scale (0, 1000], and a move no
    /// larger than 20× the longer page dimension.
    public struct Limits: Sendable {
        public var maxOperations: Int
        public var maxTextLength: Int
        public var minFontPoints: Double
        public var maxFontPoints: Double
        public var maxLineWidthPoints: Double
        public var maxScaleFactor: Double
        public var movePageMultiple: Double

        public init(
            maxOperations: Int = 200,
            maxTextLength: Int = 5000,
            minFontPoints: Double = 1,
            maxFontPoints: Double = 1000,
            maxLineWidthPoints: Double = 1000,
            maxScaleFactor: Double = 1000,
            movePageMultiple: Double = 20
        ) {
            self.maxOperations = maxOperations
            self.maxTextLength = maxTextLength
            self.minFontPoints = minFontPoints
            self.maxFontPoints = maxFontPoints
            self.maxLineWidthPoints = maxLineWidthPoints
            self.maxScaleFactor = maxScaleFactor
            self.movePageMultiple = movePageMultiple
        }
    }

    /// Validates `plan` against `scene`. Returns every problem found (so the UI can list
    /// them) plus any warnings.
    public static func validate(_ plan: EditPlan, in scene: Scene, limits: Limits = Limits()) -> EditPlanValidation {
        var problems: [EditPlanProblem] = []
        var warnings: [EditPlanWarning] = []

        if plan.operations.isEmpty {
            problems.append(.emptyPlan)
        }
        if plan.operations.count > limits.maxOperations {
            problems.append(.tooManyOperations(count: plan.operations.count, limit: limits.maxOperations))
        }

        let moveCap = limits.movePageMultiple * Double(max(scene.pageBoundsDevice.width, scene.pageBoundsDevice.height, 1))
        var deletedIDs = Set<Int>()

        for (index, operation) in plan.operations.enumerated() {
            switch operation {
            case .recolorFill(let ids, let color):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems)
                if color.color == nil { problems.append(.invalidColor(op: index, hex: color.hex)) }

            case .recolorStroke(let ids, let color):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems)
                if color.color == nil { problems.append(.invalidColor(op: index, hex: color.hex)) }

            case .setText(let id, let text):
                checkTargets([id], op: index, kind: .text, scene: scene, into: &problems)
                if text.count > limits.maxTextLength {
                    problems.append(.textTooLong(op: index, length: text.count, limit: limits.maxTextLength))
                }

            case .setFontSize(let id, let points):
                checkTargets([id], op: index, kind: .text, scene: scene, into: &problems)
                if !points.isFinite {
                    problems.append(.numberNotFinite(op: index))
                } else if points < limits.minFontPoints || points > limits.maxFontPoints {
                    problems.append(.fontSizeOutOfRange(op: index, points: points))
                }

            case .setFontFamily(let id, _):
                checkTargets([id], op: index, kind: .text, scene: scene, into: &problems)

            case .move(let ids, let dx, let dy):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems)
                if !dx.isFinite || !dy.isFinite {
                    problems.append(.numberNotFinite(op: index))
                } else if abs(dx) > moveCap || abs(dy) > moveCap {
                    problems.append(.moveOutOfRange(op: index))
                }

            case .scale(let ids, let factor):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems)
                if !factor.isFinite {
                    problems.append(.numberNotFinite(op: index))
                } else if factor <= 0 || factor > limits.maxScaleFactor {
                    problems.append(.scaleOutOfRange(op: index, factor: factor))
                }

            case .setLineWidth(let ids, let points):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems)
                if !points.isFinite {
                    problems.append(.numberNotFinite(op: index))
                } else if points <= 0 || points > limits.maxLineWidthPoints {
                    problems.append(.lineWidthOutOfRange(op: index, points: points))
                }

            case .align(let ids, _):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems, requireNonEmpty: true)

            case .distribute(let ids, _):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems, requireNonEmpty: true)

            case .delete(let ids):
                checkTargets(ids, op: index, kind: .any, scene: scene, into: &problems, requireNonEmpty: true)
                for id in ids where scene.element(id: id) != nil { deletedIDs.insert(id) }
            }
        }

        // Deleting the whole drawing is allowed but flagged prominently.
        let editableIDs = Set(scene.editableElements.map(\.id))
        if !editableIDs.isEmpty, editableIDs.isSubset(of: deletedIDs) {
            warnings.append(.deletesEntireDrawing(count: editableIDs.count))
        }

        return EditPlanValidation(problems: problems, warnings: warnings)
    }

    private enum TargetKind { case any, text }

    /// Appends a problem for each bad id: missing, locked/passthrough, or (for text ops)
    /// not a text run. An empty id list is a problem only when `requireNonEmpty`.
    private static func checkTargets(
        _ ids: [Int], op: Int, kind: TargetKind, scene: Scene,
        into problems: inout [EditPlanProblem], requireNonEmpty: Bool = true
    ) {
        if ids.isEmpty {
            if requireNonEmpty { problems.append(.emptyTargetList(op: op)) }
            return
        }
        for id in ids {
            guard let element = scene.element(id: id) else {
                problems.append(.elementNotFound(op: op, id: id))
                continue
            }
            if element.rejectsMutation {
                problems.append(.elementNotEditable(op: op, id: id))
                continue
            }
            if kind == .text, !(element.kind == .text && element.text != nil) {
                problems.append(.notTextElement(op: op, id: id))
            }
        }
    }
}
