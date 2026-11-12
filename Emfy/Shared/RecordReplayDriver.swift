import CoreGraphics
import EMFRender
import Observation

// MARK: - Record step-through replay driver (F5c)
//
// Drives the record inspector's dedicated replay canvas. The heavy work — building
// the `MetafilePartialPlayer`, the one `observe` pass for the per-record outline
// geometry, and every `step(through:)` render — runs on a background actor so the
// main thread never blocks; results are published back to the `@MainActor`
// `@Observable` driver the replay view and the inspector read.
//
// Rapid scrubbing coalesces: each request bumps a generation counter and only the
// latest completed render is applied, so dragging the scrubber across a large file
// renders just the frames that land.

/// The one-time data the inspector needs for a loaded drawing: the record list, the
/// drawing-record indices and per-record device outlines (from `observe`), whether
/// per-record stepping is available, and the replay canvas pixel/device geometry.
struct RecordReplayData: @unchecked Sendable {
    let refs: [RecordRef]
    let drawingIndices: [Int]
    /// Record index → unioned device-space bounds of the op(s) drawn by that record,
    /// for the current-record outline. GDI only.
    let perRecordDeviceBounds: [Int: CGRect]
    /// Pre-computed one-line summaries by record index, built off-main.
    let summaries: [Int: String]
    let supportsPartial: Bool
    let pixelSize: CGSize
    let deviceBounds: CGRect
}

/// One rendered step: the raster and the DC state after the record (both nil for a
/// non-steppable file, which never configures the driver).
struct RecordStepResult: @unchecked Sendable {
    let image: CGImage?
    let state: PlaybackState?
}

/// Owns the non-`Sendable` `MetafilePartialPlayer` on a background actor, so every
/// render stays off the main thread. Built from the `Sendable` `Prepared`.
actor RecordReplayEngine {
    private let prepared: MetafileRenderer.Prepared
    private let options: RenderOptions
    private let scale: CGFloat
    private var player: MetafilePartialPlayer?

    init(prepared: MetafileRenderer.Prepared, options: RenderOptions, scale: CGFloat) {
        self.prepared = prepared
        self.options = options
        self.scale = scale
    }

    private func makePlayer() -> MetafilePartialPlayer? {
        if let player { return player }
        player = prepared.makePartialPlayer(scale: scale, background: .white, options: options)
        return player
    }

    /// Builds the record list, the observe-derived outlines and drawing indices, the
    /// summaries, and the replay geometry. One pass, off-main.
    func prepareData() -> RecordReplayData {
        let player = makePlayer()
        let refs = prepared.recordRefs()

        var summaries: [Int: String] = [:]
        for ref in refs {
            if let summary = prepared.recordSummary(at: ref.index), !summary.isEmpty {
                summaries[ref.index] = summary
            }
        }

        // Per-record device outlines + the drawing-record indices come from the one
        // observe pass (the same interpreter the viewer draws with — no re-decode).
        var perRecord: [Int: CGRect] = [:]
        var drawing = Set<Int>()
        let observation = MetafileRenderer.observe(prepared, options: options)
        for op in observation.ops {
            let box = op.deviceGeometry.boundingBoxOfPath
            for index in op.recordIndices {
                drawing.insert(index)
                guard box.isFinite, !box.isEmpty else { continue }
                perRecord[index] = perRecord[index].map { $0.union(box) } ?? box
            }
        }

        return RecordReplayData(
            refs: refs,
            drawingIndices: drawing.sorted(),
            perRecordDeviceBounds: perRecord,
            summaries: summaries,
            supportsPartial: player?.supportsPartial ?? false,
            pixelSize: player?.pixelSize ?? prepared.deviceBounds.size,
            deviceBounds: prepared.deviceBounds
        )
    }

    /// Renders through `index` and returns the raster plus the DC state after it.
    func step(through index: Int) -> RecordStepResult {
        guard let player = makePlayer() else {
            return RecordStepResult(image: nil, state: prepared.playbackState(throughRecordIndex: index, options: options))
        }
        let result = player.step(throughRecordIndex: index)
        return RecordStepResult(image: result.image, state: result.state)
    }
}

/// The step-through replay driver the inspector and the dedicated replay canvas read.
/// Holds the latest rendered image, the DC state and the current record's device
/// outline, sequencing background renders and coalescing rapid scrubbing.
@MainActor
@Observable
final class RecordReplayDriver {
    /// The latest rendered raster, or nil before the first step / on a render failure.
    private(set) var image: CGImage?
    /// The canvas size in pixels the raster is rendered at.
    private(set) var pixelSize: CGSize = CGSize(width: 1, height: 1)
    /// The device-space page rectangle, for mapping outlines into the raster.
    private(set) var deviceBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The current record's device-space outline, or nil when the record draws nothing.
    private(set) var outlineDeviceRect: CGRect?
    /// A monotonically increasing token the replay view watches to re-fit on new content.
    private(set) var contentToken = 0

    @ObservationIgnored private var engine: RecordReplayEngine?
    @ObservationIgnored private var contentID: Int?
    @ObservationIgnored private var perRecordDeviceBounds: [Int: CGRect] = [:]
    @ObservationIgnored private(set) var summaries: [Int: String] = [:]
    @ObservationIgnored private var generation = 0
    /// Median step time (ms) and first→last span (ms), for the WS-A perf log.
    @ObservationIgnored private var stepTimesMS: [Double] = []

    /// Configures the driver for a loaded drawing, populating `model` off-main and
    /// then rendering the initial (full-drawing) step. A re-configure for the same
    /// content id is a no-op that keeps the current frame.
    func configure(
        prepared: MetafileRenderer.Prepared,
        options: RenderOptions,
        scale: CGFloat,
        contentID: Int,
        model: RecordInspectorModel
    ) {
        guard self.contentID != contentID else { return }
        self.contentID = contentID
        let engine = RecordReplayEngine(prepared: prepared, options: options, scale: scale)
        self.engine = engine
        deviceBounds = prepared.deviceBounds
        image = nil
        stepTimesMS = []
        Task { [weak self, weak model] in
            let data = await engine.prepareData()
            guard let self, self.contentID == contentID else { return }
            self.perRecordDeviceBounds = data.perRecordDeviceBounds
            self.summaries = data.summaries
            self.pixelSize = data.pixelSize
            self.deviceBounds = data.deviceBounds
            model?.setContent(
                refs: data.refs,
                drawingIndices: data.drawingIndices,
                supportsPartial: data.supportsPartial,
                isEMF: true,
                contentID: contentID
            )
            self.request(index: model?.selectedIndex ?? 0, model: model)
        }
    }

    /// Requests a render through `index`, coalescing: only the latest request's result
    /// is applied. Updates the outline immediately (cheap) and the raster/state when
    /// the background render lands.
    func request(index: Int, model: RecordInspectorModel?) {
        guard let engine else { return }
        outlineDeviceRect = perRecordDeviceBounds[index]
        generation &+= 1
        let token = generation
        Task { [weak self, weak model] in
            let start = ContinuousClock.now
            let result = await engine.step(through: index)
            guard let self, token == self.generation else { return }
            let components = start.duration(to: .now).components
            let elapsed = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15   // ms
            self.stepTimesMS.append(elapsed)
            self.image = result.image
            self.contentToken &+= 1
            model?.setState(result.state)
        }
    }

    /// The device outline for a record index, for the replay view's highlight.
    func outline(for index: Int) -> CGRect? { perRecordDeviceBounds[index] }

    /// Forces the next `configure` to rebuild (e.g. after a render-options change that
    /// keeps the same content id).
    func invalidate() { contentID = nil }

    #if DEBUG
    /// Steps through every record once, sequentially, timing each — the WS-A step-through
    /// perf measurement. Returns the median step (ms), the first→last span (ms) and the
    /// number of steps. Must be called after `configure`'s data has loaded.
    func runPerf(count: Int) async -> (median: Double, span: Double, count: Int) {
        guard let engine else { return (0, 0, 0) }
        var times: [Double] = []
        let overallStart = ContinuousClock.now
        for index in 0 ..< max(1, count) {
            let start = ContinuousClock.now
            _ = await engine.step(through: index)
            let components = start.duration(to: .now).components
            times.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
        }
        let spanComponents = overallStart.duration(to: .now).components
        let span = Double(spanComponents.seconds) * 1000 + Double(spanComponents.attoseconds) / 1e15
        let sorted = times.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return (median, span, times.count)
    }
    #endif
}

private extension CGRect {
    var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite }
}
