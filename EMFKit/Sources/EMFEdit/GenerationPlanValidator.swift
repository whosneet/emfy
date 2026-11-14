import CoreGraphics
import Foundation

// MARK: - Generation-plan validation (X2d)
//
// Checks a decoded `GenerationPlan` BEFORE any geometry is built: the element count is
// capped, every coordinate is finite and in-page, every size is positive, colours resolve,
// text is capped and font sizes are bounded. An invalid plan creates NOTHING — the view
// model refuses to preview or create a scene from a plan with any problem.
//
// Security (CLAUDE.md §8): the plan is built from untrusted model output. Every number
// reaches the scene-builder's arithmetic, so each is range-checked here first; the checks
// never trap (finite guards, no force-unwrap, no unchecked maths).

/// One problem with a generation plan. Any problem makes the plan non-applicable.
public enum GenerationPlanProblem: Sendable, Equatable {
    /// The plan has no operations.
    case emptyPlan
    /// More operations than the cap.
    case tooManyElements(count: Int, limit: Int)
    /// An operation holds a NaN or infinite coordinate.
    case coordinateNotFinite(op: Int)
    /// An operation's coordinate falls outside the page.
    case coordinateOutOfPage(op: Int)
    /// A width/height was not strictly positive (or a line/arrow had zero length).
    case nonPositiveSize(op: Int)
    /// A polyline/polygon had too few points (polyline needs 2, polygon needs 3).
    case tooFewPoints(op: Int)
    /// A colour string did not resolve to a hex value or a known colour word.
    case invalidColor(op: Int, raw: String)
    /// A font size (points) is outside the accepted range.
    case fontSizeOutOfRange(op: Int, points: Double)
    /// A text string exceeds the length cap.
    case textTooLong(op: Int, length: Int, limit: Int)
    /// A stroke width was not finite, was negative, or exceeded the cap.
    case strokeWidthOutOfRange(op: Int, points: Double)
    /// A corner radius was not finite, was negative, or exceeded the page extent.
    case cornerRadiusInvalid(op: Int)
    /// A polyline/polygon had more points than the cap.
    case tooManyPoints(op: Int, count: Int, limit: Int)
    /// A font family name exceeded the length cap.
    case fontFamilyTooLong(op: Int, length: Int, limit: Int)
}

/// The result of validating a generation plan.
public struct GenerationPlanValidation: Sendable, Equatable {
    public var problems: [GenerationPlanProblem]

    public init(problems: [GenerationPlanProblem]) { self.problems = problems }

    /// A plan with no problems may be previewed and created.
    public var isApplicable: Bool { problems.isEmpty }
}

public enum GenerationPlanValidator {

    /// The bounds the validator enforces. Defaults match the brief: ≤ 300 elements, text ≤
    /// 500 chars, font 4…200 pt, and coordinates within the page plus a small margin.
    public struct Limits: Sendable {
        public var maxElements: Int
        public var maxTextLength: Int
        public var minFontPoints: Double
        public var maxFontPoints: Double
        /// How far outside the page an element may bleed, as a fraction of the page extent.
        public var pageMargin: Double
        /// The largest stroke width (points) an op may carry.
        public var maxStrokeWidthPoints: Double
        /// The most points a single polyline/polygon may have.
        public var maxPointsPerPolyline: Int
        /// The longest font family name (characters) a text op may carry.
        public var maxFontFamilyLength: Int

        public init(
            maxElements: Int = 300,
            maxTextLength: Int = 500,
            minFontPoints: Double = 4,
            maxFontPoints: Double = 200,
            pageMargin: Double = 0.05,
            maxStrokeWidthPoints: Double = 1000,
            maxPointsPerPolyline: Int = 1000,
            maxFontFamilyLength: Int = 100
        ) {
            self.maxElements = maxElements
            self.maxTextLength = maxTextLength
            self.minFontPoints = minFontPoints
            self.maxFontPoints = maxFontPoints
            self.pageMargin = pageMargin
            self.maxStrokeWidthPoints = maxStrokeWidthPoints
            self.maxPointsPerPolyline = maxPointsPerPolyline
            self.maxFontFamilyLength = maxFontFamilyLength
        }
    }

    /// Validates `plan`. Returns every problem found so the UI can list them.
    public static func validate(_ plan: GenerationPlan, limits: Limits = Limits()) -> GenerationPlanValidation {
        var problems: [GenerationPlanProblem] = []

        if plan.operations.isEmpty { problems.append(.emptyPlan) }
        if plan.operations.count > limits.maxElements {
            problems.append(.tooManyElements(count: plan.operations.count, limit: limits.maxElements))
        }

        let extent = plan.page.extent
        let margin = limits.pageMargin
        let minX = -margin * Double(extent.width), maxX = (1 + margin) * Double(extent.width)
        let minY = -margin * Double(extent.height), maxY = (1 + margin) * Double(extent.height)
        let maxW = (1 + margin) * Double(extent.width), maxH = (1 + margin) * Double(extent.height)

        /// Whether (x, y) is on-page (within the margin).
        func inPage(_ x: Double, _ y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }

        let maxExtent = max(maxW, maxH)

        for (index, op) in plan.operations.enumerated() {
            switch op {
            case let .rectangle(x, y, w, h, fill, stroke, strokeWidth),
                 let .ellipse(x, y, w, h, fill, stroke, strokeWidth):
                checkBox(x, y, w, h, op: index, maxW: maxW, maxH: maxH, inPage: inPage, into: &problems)
                checkColor(fill, op: index, into: &problems)
                checkColor(stroke, op: index, into: &problems)
                checkStrokeWidth(strokeWidth, op: index, limits: limits, into: &problems)

            case let .roundedRectangle(x, y, w, h, radius, fill, stroke, strokeWidth):
                checkBox(x, y, w, h, op: index, maxW: maxW, maxH: maxH, inPage: inPage, into: &problems)
                if !radius.isFinite || radius < 0 || radius > maxExtent {
                    problems.append(.cornerRadiusInvalid(op: index))
                }
                checkColor(fill, op: index, into: &problems)
                checkColor(stroke, op: index, into: &problems)
                checkStrokeWidth(strokeWidth, op: index, limits: limits, into: &problems)

            case let .line(from, to, stroke, strokeWidth), let .arrow(from, to, stroke, strokeWidth):
                if !from.isFinite || !to.isFinite {
                    problems.append(.coordinateNotFinite(op: index))
                } else {
                    if !inPage(from.x, from.y) || !inPage(to.x, to.y) { problems.append(.coordinateOutOfPage(op: index)) }
                    if from == to { problems.append(.nonPositiveSize(op: index)) }
                }
                checkColor(stroke, op: index, into: &problems)
                checkStrokeWidth(strokeWidth, op: index, limits: limits, into: &problems)

            case let .polyline(points, stroke, strokeWidth):
                checkPoints(points, op: index, minimum: 2, limits: limits, inPage: inPage, into: &problems)
                checkColor(stroke, op: index, into: &problems)
                checkStrokeWidth(strokeWidth, op: index, limits: limits, into: &problems)

            case let .polygon(points, fill, stroke, strokeWidth):
                checkPoints(points, op: index, minimum: 3, limits: limits, inPage: inPage, into: &problems)
                checkColor(fill, op: index, into: &problems)
                checkColor(stroke, op: index, into: &problems)
                checkStrokeWidth(strokeWidth, op: index, limits: limits, into: &problems)

            case let .text(x, y, _, _, string, color, fontSize, fontFamily):
                if !x.isFinite || !y.isFinite {
                    problems.append(.coordinateNotFinite(op: index))
                } else if !inPage(x, y) {
                    problems.append(.coordinateOutOfPage(op: index))
                }
                if !fontSize.isFinite {
                    problems.append(.coordinateNotFinite(op: index))
                } else if fontSize < limits.minFontPoints || fontSize > limits.maxFontPoints {
                    problems.append(.fontSizeOutOfRange(op: index, points: fontSize))
                }
                if string.count > limits.maxTextLength {
                    problems.append(.textTooLong(op: index, length: string.count, limit: limits.maxTextLength))
                }
                if let fontFamily, fontFamily.count > limits.maxFontFamilyLength {
                    problems.append(.fontFamilyTooLong(op: index, length: fontFamily.count, limit: limits.maxFontFamilyLength))
                }
                checkColor(color, op: index, into: &problems)
            }
        }

        return GenerationPlanValidation(problems: problems)
    }

    // MARK: Helpers

    private static func checkBox(
        _ x: Double, _ y: Double, _ w: Double, _ h: Double, op: Int,
        maxW: Double, maxH: Double, inPage: (Double, Double) -> Bool,
        into problems: inout [GenerationPlanProblem]
    ) {
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite else {
            problems.append(.coordinateNotFinite(op: op)); return
        }
        if w <= 0 || h <= 0 || w > maxW || h > maxH { problems.append(.nonPositiveSize(op: op)) }
        if !inPage(x, y) || !inPage(x + w, y + h) { problems.append(.coordinateOutOfPage(op: op)) }
    }

    private static func checkPoints(
        _ points: [GenPoint], op: Int, minimum: Int, limits: Limits,
        inPage: (Double, Double) -> Bool, into problems: inout [GenerationPlanProblem]
    ) {
        if points.count < minimum { problems.append(.tooFewPoints(op: op)); return }
        if points.count > limits.maxPointsPerPolyline {
            problems.append(.tooManyPoints(op: op, count: points.count, limit: limits.maxPointsPerPolyline))
        }
        if points.contains(where: { !$0.isFinite }) { problems.append(.coordinateNotFinite(op: op)); return }
        if points.contains(where: { !inPage($0.x, $0.y) }) { problems.append(.coordinateOutOfPage(op: op)) }
    }

    /// Bounds an optional stroke width: finite, non-negative, within the cap.
    private static func checkStrokeWidth(
        _ width: Double?, op: Int, limits: Limits, into problems: inout [GenerationPlanProblem]
    ) {
        guard let width else { return }
        if !width.isFinite || width < 0 || width > limits.maxStrokeWidthPoints {
            problems.append(.strokeWidthOutOfRange(op: op, points: width))
        }
    }

    private static func checkColor(_ color: GenColor?, op: Int, into problems: inout [GenerationPlanProblem]) {
        guard let color else { return }
        if color.color == nil { problems.append(.invalidColor(op: op, raw: color.raw)) }
    }
}
