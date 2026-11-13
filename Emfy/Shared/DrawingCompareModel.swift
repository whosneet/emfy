import CoreGraphics
import EMFEdit
import Foundation
import Observation

// MARK: - The "Compare two versions" view-model (X1b item 1)
//
// Compares the open drawing against a baseline (the opened-version snapshot on the Mac,
// or a user-picked file) and drives the compare sheet: the element-level change list
// (DrawingComparison), a pixel-level change mask (DrawingPixelDiff), and the two
// rendered images for the side-by-side, overlay/onion-skin and highlight-differences
// modes. All heavy work runs off the main actor; the view reads the app-typed outputs.

@MainActor
@Observable
final class DrawingCompareModel {

    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide, overlay, highlight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sideBySide: return "Side by side"
            case .overlay: return "Overlay"
            case .highlight: return "Differences"
            }
        }
    }

    enum Phase: Equatable { case idle, comparing, ready, failed(String) }

    private(set) var phase: Phase = .idle
    var mode: Mode = .sideBySide
    /// Onion-skin blend for the overlay mode: 0 = baseline only, 1 = current only.
    var onionValue: Double = 0.5
    /// The selected change, highlighted on the canvas.
    var selectedChangeID: Int?

    private(set) var changes: [DrawingComparison.ElementChange] = []
    private(set) var addedCount = 0
    private(set) var removedCount = 0
    private(set) var changedCount = 0
    /// Changed-pixel regions in the CURRENT image's pixel space.
    private(set) var pixelRegions: [CGRect] = []
    private(set) var changedFraction: Double = 0
    private(set) var baselineImage: CGImage?
    private(set) var currentImage: CGImage?
    /// The current drawing's device-space page, for mapping a change's device bounds
    /// onto the displayed image.
    private(set) var pageBoundsDevice: CGRect = .zero
    private(set) var baselineLabel = "Opened version"
    let currentLabel = "This version"

    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .comparing }

    /// True when the two versions are identical at the element level.
    var isEmptyDiff: Bool { phase == .ready && changes.isEmpty }

    /// Starts a comparison of `current` against `baseline`. `baselineLabel` names the
    /// baseline in the UI ("Opened version" or the picked file name).
    func compare(current: Scene, baseline: Scene, baselineLabel: String) {
        self.baselineLabel = baselineLabel
        self.pageBoundsDevice = current.pageBoundsDevice
        phase = .comparing
        selectedChangeID = nil
        changes = []
        pixelRegions = []
        task?.cancel()
        task = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                Self.computeCompare(current: current, baseline: baseline)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let computed else {
                self.phase = .failed("Emfy couldn’t render the two versions to compare.")
                return
            }
            let comparison = computed.comparison
            self.changes = comparison.changes
            self.addedCount = comparison.addedCount
            self.removedCount = comparison.removedCount
            self.changedCount = comparison.changedCount
            self.currentImage = computed.current
            self.baselineImage = computed.baseline
            self.pixelRegions = computed.regions
            self.changedFraction = computed.changedFraction
            self.phase = .ready
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func select(changeID: Int?) { selectedChangeID = changeID }

    /// The device bounds of the selected change, for the canvas highlight; nil when
    /// nothing is selected.
    var selectedChangeBounds: CGRect? {
        guard let id = selectedChangeID,
              let change = changes.first(where: { $0.id == id }),
              !change.boundsDevice.isNull else { return nil }
        return change.boundsDevice
    }

    // MARK: Off-main computation

    /// The result of a comparison, carried across the detached boundary. `@unchecked
    /// Sendable`: `CGImage` is an immutable value.
    private struct Computed: @unchecked Sendable {
        let comparison: DrawingComparison
        let current: CGImage
        let baseline: CGImage
        let regions: [CGRect]
        let changedFraction: Double
    }

    nonisolated private static func computeCompare(current: Scene, baseline: Scene) -> Computed? {
        let comparison = DrawingComparison(old: baseline, new: current)
        guard let currentImage = SceneRenderer.makeImage(current, scale: 2),
              let baselineImage = SceneRenderer.makeImage(baseline, scale: 2) else { return nil }
        let diff = DrawingPixelDiff.compare(old: baselineImage, new: currentImage, channelTolerance: 10, cellSize: 24)
        return Computed(
            comparison: comparison, current: currentImage, baseline: baselineImage,
            regions: diff?.regions ?? [], changedFraction: diff?.changedFraction ?? 0)
    }

    // MARK: Device → display mapping

    /// Maps a device-space rect (current scene page) into `displayRect` — the on-screen
    /// frame the current image is drawn in (aspect-fit, top-left origin).
    func displayRect(forDevice device: CGRect, in displayRect: CGRect) -> CGRect {
        guard pageBoundsDevice.width > 0, pageBoundsDevice.height > 0 else { return .zero }
        let sx = displayRect.width / pageBoundsDevice.width
        let sy = displayRect.height / pageBoundsDevice.height
        return CGRect(
            x: displayRect.minX + (device.minX - pageBoundsDevice.minX) * sx,
            y: displayRect.minY + (device.minY - pageBoundsDevice.minY) * sy,
            width: device.width * sx, height: device.height * sy)
    }

    /// Maps a changed-pixel region (current image pixel space) into `displayRect`.
    func displayRect(forPixel pixel: CGRect, in displayRect: CGRect) -> CGRect {
        guard let image = currentImage, image.width > 0, image.height > 0 else { return .zero }
        let sx = displayRect.width / CGFloat(image.width)
        let sy = displayRect.height / CGFloat(image.height)
        return CGRect(
            x: displayRect.minX + pixel.minX * sx,
            y: displayRect.minY + pixel.minY * sy,
            width: pixel.width * sx, height: pixel.height * sy)
    }
}
