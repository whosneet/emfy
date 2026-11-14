import CoreGraphics
import CoreText
import EMFParse
import Foundation

// MARK: - Step-through replay (F5)
//
// Partial playback renders a metafile "through record N only": every record up
// to and including index N in `EMFFile.records` plays, nothing after. The
// record inspector's scrubber uses it to step through a drawing a record at a
// time, and the DC panel reads the state the DC holds AFTER record N.
//
// This is a GDI-path feature. An EMF+ drawing file plays its EMF+ records out of
// EMR_COMMENT carriers ([MS-EMFPLUS] §2.3.3), so a GDI `records` index does not
// slice the EMF+ stream; such files render in full (N is ignored) and report it
// via `supportsPartial`. Full-render behaviour is unchanged — the existing
// `EMFRenderer.render`/`makeImage` are untouched, so every committed snapshot is
// byte-identical.

// MARK: - DC state after a record (the inspector's DC panel)

/// A read-only, value-type description of the playback device-context state
/// AFTER a given record — what the F5 inspector's DC panel shows. Built from
/// the live `DeviceContext` after partial playback, it exposes only readable
/// GDI state (current pen/brush/font, text colour/alignment, map mode,
/// window/viewport, world transform, a clip summary, the current position) with
/// no CoreGraphics/CoreText reference members, so it crosses actor boundaries
/// freely.
public struct PlaybackState: Sendable, Equatable {

    /// The selected pen.
    public enum Pen: Sendable, Equatable {
        /// PS_NULL / NULL_PEN — the stroke half of a shape is skipped.
        case none
        /// A stroking pen: solid colour, whether it is one device pixel
        /// (cosmetic), its logical width, and a short dash-style name.
        case stroke(color: ColorRef, cosmetic: Bool, width: Double, dash: String)
    }

    /// The selected brush.
    public enum Brush: Sendable, Equatable {
        /// BS_NULL / NULL_BRUSH — the fill half of a shape is skipped.
        case none
        case solid(ColorRef)
        /// A DIB pattern brush (EMR_CREATEDIBPATTERNBRUSHPT / EMR_CREATEMONOBRUSH),
        /// with its tile's pixel dimensions for the inspector's DC panel.
        case pattern(width: Int, height: Int)
    }

    /// The selected font, when one has been selected.
    public struct Font: Sendable, Equatable {
        /// The resolved macOS family (CTFontCopyFamilyName).
        public let family: String
        /// The ORIGINAL requested face name (LOGFONT faceName), empty for a stock
        /// font.
        public let requestedFamily: String
        /// Signed logical height (§2.2.13): < 0 em, > 0 cell, 0 default.
        public let logicalHeight: Int32
        public let bold: Bool
        public let italic: Bool
        public let underline: Bool
        public let strikeOut: Bool
    }

    /// A compact summary of the current clipping region.
    public enum Clip: Sendable, Equatable {
        /// No clip — the whole canvas.
        case none
        /// `primitiveCount` intersected clip primitives are in effect.
        case region(primitiveCount: Int)
    }

    /// The current world transform's six affine components (a, b, c, d, tx, ty).
    public struct Transform: Sendable, Equatable {
        public let a, b, c, d, tx, ty: Double
    }

    public let mapMode: MapMode
    public let windowOrigin: PointL
    public let windowExtent: SizeL
    public let viewportOrigin: PointL
    public let viewportExtent: SizeL
    public let worldTransform: Transform
    public let backgroundMode: BackgroundMode
    public let polyFillMode: PolygonFillMode
    public let rop2: UInt32
    public let miterLimit: UInt32
    public let currentPosition: PointL
    public let textColor: ColorRef
    public let backgroundColor: ColorRef
    public let textAlign: TextAlign
    public let pen: Pen
    public let brush: Brush
    public let font: Font?
    public let clip: Clip
    /// Depth of the SaveDC stack.
    public let saveDepth: Int
    /// Number of live object-table entries.
    public let objectCount: Int
}

extension DeviceContext {
    /// Builds a `PlaybackState` from the live DC — the state after the records
    /// played so far. Reads only; no interpretation.
    func playbackState() -> PlaybackState {
        PlaybackState(
            mapMode: state.mapMode,
            windowOrigin: state.windowOrg,
            windowExtent: state.windowExt,
            viewportOrigin: state.viewportOrg,
            viewportExtent: state.viewportExt,
            worldTransform: PlaybackState.Transform(
                a: state.world.a, b: state.world.b, c: state.world.c,
                d: state.world.d, tx: state.world.tx, ty: state.world.ty
            ),
            backgroundMode: state.bkMode,
            polyFillMode: state.polyFillMode,
            rop2: state.rop2Raw,
            miterLimit: state.miterLimit,
            currentPosition: state.currentPosition,
            textColor: state.textColor,
            backgroundColor: state.bkColor,
            textAlign: state.textAlign,
            pen: Self.describe(state.pen),
            brush: Self.describe(state.brush),
            font: state.font.map(Self.describe),
            clip: state.clip.isEmpty ? .none : .region(primitiveCount: state.clip.primitiveCount),
            saveDepth: saveDepth,
            objectCount: objectCount
        )
    }

    private static func describe(_ pen: ResolvedPen) -> PlaybackState.Pen {
        switch pen {
        case .none:
            return .none
        case .stroke(let stroke):
            return .stroke(
                color: stroke.color,
                cosmetic: stroke.isCosmetic,
                width: stroke.width,
                dash: dashName(stroke.lineStyle)
            )
        }
    }

    private static func describe(_ brush: ResolvedBrush) -> PlaybackState.Brush {
        switch brush {
        case .none: return .none
        case .solid(let color): return .solid(color)
        case .pattern(let pattern):
            return .pattern(width: Int(pattern.dib.width), height: abs(Int(pattern.dib.height)))
        }
    }

    private static func describe(_ font: ResolvedFont) -> PlaybackState.Font {
        let family = CTFontCopyFamilyName(font.base) as String
        let traits = CTFontGetSymbolicTraits(font.base)
        return PlaybackState.Font(
            family: family,
            requestedFamily: font.requestedFamily,
            logicalHeight: font.logicalHeight,
            bold: traits.contains(.traitBold),
            italic: traits.contains(.traitItalic),
            underline: font.underline,
            strikeOut: font.strikeOut
        )
    }

    private static func dashName(_ style: ResolvedLineStyle) -> String {
        switch style {
        case .solid: return "solid"
        case .dash: return "dash"
        case .dot: return "dot"
        case .dashDot: return "dash-dot"
        case .dashDotDot: return "dash-dot-dot"
        case .userStyle: return "custom"
        }
    }
}

extension ClipRegion {
    /// The number of intersected clip primitives — for the DC panel summary.
    var primitiveCount: Int { primitives.count }
}

// MARK: - EMFRenderer partial playback

extension EMFRenderer {

    /// Plays `file`'s records into `context` up to AND INCLUDING `throughRecordIndex`
    /// (an index into `file.records`; 0 is EMR_HEADER), mapping the file's device
    /// space onto `target`. Records after the index are not played.
    ///
    /// GDI only: a file whose EMF+ stream carries drawing records renders in full
    /// (a GDI record index cannot slice the EMF+ stream) — use a
    /// `MetafilePartialPlayer`, whose `supportsPartial` says whether stepping is
    /// available. `throughRecordIndex` is clamped to the record range.
    public static func render(
        _ file: EMFFile,
        into context: CGContext,
        target: CGRect,
        throughRecordIndex limit: Int,
        options: RenderOptions = .default
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let plus = file.emfPlusStream()
        for diagnostic in plus.diagnostics {
            log.noteEMFPlusStreamIssue(EMFPlusStreamIssueKind(diagnostic))
        }
        let forceGDI = options.emfPlusArbitration == .gdi && (plus.header?.isDual ?? false)
        if !forceGDI, plus.records.contains(where: \.isDrawing) {
            // EMF+ drives output; a GDI record index is not a meaningful slice.
            return render(file, into: context, target: target, options: options)
        }
        _ = renderGDIPartial(file, into: context, target: target, through: limit, options: options, log: &log)
        return log
    }

    /// Renders `file` through `throughRecordIndex` into a fresh bitmap sized from
    /// the header bounds (× `scale`), on `background`. Returns `nil` only on a
    /// bitmap allocation failure. GDI only (see `render(…throughRecordIndex:)`).
    public static func makeImage(
        _ file: EMFFile,
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default,
        throughRecordIndex limit: Int
    ) -> (CGImage, EMFRenderLog)? {
        let bounds = file.header.bounds
        let deviceWidth = Double(Int64(bounds.right) - Int64(bounds.left) + 1)
        let deviceHeight = Double(Int64(bounds.bottom) - Int64(bounds.top) + 1)
        let (width, height) = canvasPixelSize(deviceWidth: deviceWidth, deviceHeight: deviceHeight, scale: scale)
        guard let context = bitmapContext(width: width, height: height, background: background) else {
            return nil
        }
        let log = render(
            file, into: context,
            target: CGRect(x: 0, y: 0, width: width, height: height),
            throughRecordIndex: limit, options: options
        )
        guard let image = context.makeImage() else { return nil }
        return (image, log)
    }

    /// The DC state AFTER `throughRecordIndex`, for the inspector's DC panel.
    /// Plays through the record into a throwaway 1×1 context so the current
    /// position, clip, and object table reflect actual playback, not just a
    /// state-only walk.
    public static func playbackState(
        of file: EMFFile,
        throughRecordIndex limit: Int,
        options: RenderOptions = .default
    ) -> PlaybackState {
        let target = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let context = bitmapContext(width: 1, height: 1, background: .transparent) else {
            // Allocation failure: return the initial GDI defaults rather than crash.
            return DeviceContext(header: file.header, fontSubstitutions: options.fontSubstitutions).playbackState()
        }
        var log = EMFRenderLog()
        let dc = renderGDIPartial(file, into: context, target: target, through: limit, options: options, log: &log)
        return dc.playbackState()
    }

    /// The shared GDI partial-playback loop: plays records `1...min(limit, last)`
    /// into `context` and returns the resulting DC (so callers can read the state
    /// after the last played record). No observer is attached — partial playback
    /// never imports. The context's gstate is saved and restored around the loop,
    /// exactly like `render`.
    @discardableResult
    static func renderGDIPartial(
        _ file: EMFFile,
        into context: CGContext,
        target: CGRect,
        through limit: Int,
        options: RenderOptions,
        log: inout EMFRenderLog
    ) -> DeviceContext {
        let base = deviceToTarget(header: file.header, target: target, log: &log)
        var dc = DeviceContext(header: file.header, fontSubstitutions: options.fontSubstitutions)
        context.saveGState()
        defer { context.restoreGState() }
        if options.antialiasing == .crisp {
            context.setShouldAntialias(false)
        }
        let last = file.records.count - 1
        let upper = min(limit, last)
        if upper >= 1 {
            for index in 1 ... upper {
                playGDIRecord(file.payload(of: file.records[index]), into: context, dc: &dc, base: base, log: &log)
            }
        }
        return dc
    }

    /// A fresh sRGB 8-bit premultiplied-alpha bitmap context. `.white` fills the
    /// page opaque white first (matching `makeImage`); `.transparent` leaves it
    /// clear. Shared by the partial-playback image paths.
    static func bitmapContext(width: Int, height: Int, background: RenderBackground) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        if background == .white {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }
}

// MARK: - Checkpointed partial-playback player

/// An interactive step-through player for the record inspector. Caching a
/// rendered raster plus a full `DeviceContext` snapshot at regular "clean"
/// record boundaries, a step to record N re-renders only from the nearest cached
/// checkpoint ≤ N instead of from the start — so stepping across a large file
/// stays well under a frame even though a from-scratch render is O(N).
///
/// Fixed to one canvas size and one set of render options for its lifetime (the
/// inspector rebuilds it when either changes). GDI only; `supportsPartial` is
/// false for an EMF+ drawing file, which `step` renders in full.
public final class MetafilePartialPlayer {

    /// The number of records in the file (`EMFFile.records.count`); valid step
    /// indices are `0 ..< recordCount`.
    public let recordCount: Int
    /// Whether per-record stepping is available. False for an EMF+ drawing file
    /// (rendered in full regardless of the requested index).
    public let supportsPartial: Bool
    /// The canvas size in pixels the player renders at.
    public let pixelSize: CGSize

    private let file: EMFFile
    private let options: RenderOptions
    private let background: RenderBackground
    private let scale: CGFloat
    private let width: Int
    private let height: Int
    private let target: CGRect
    private let stride: Int

    private struct CachedCheckpoint {
        let index: Int
        let image: CGImage
        let dc: DeviceContext.Checkpoint
        /// Bytes this checkpoint's raster occupies, for the LRU byte budget (P10).
        let cost: Int
        /// Last-use tick, bumped when this checkpoint resumes a step, so the LRU eviction
        /// keeps the checkpoints a scrubbing session actually revisits.
        var lastUsed: Int
    }
    /// Cached checkpoints, kept sorted by ascending record index.
    private var checkpoints: [CachedCheckpoint] = []
    /// Total bytes of the cached checkpoint rasters, bounded by `memoryBudget` (P10): each
    /// checkpoint holds a FULL-canvas image, so at a 64-record stride a large file could cache
    /// thousands of multi-MB rasters — gigabytes. The byte budget caps that, evicting the
    /// least-recently-used checkpoint; eviction only slows a step (it re-renders from an earlier
    /// checkpoint), never changes a pixel.
    private var currentCost = 0
    private var useTick = 0
    private let memoryBudget: Int

    /// - Parameters:
    ///   - checkpointStride: cache a checkpoint every this-many records (at a
    ///     clean path boundary). Smaller strides cost memory for faster steps.
    ///   - checkpointMemoryBudget: the cap on total cached checkpoint bytes (P10).
    public init(
        file: EMFFile,
        scale: CGFloat = 1,
        background: RenderBackground = .white,
        options: RenderOptions = .default,
        checkpointStride: Int = 64,
        checkpointMemoryBudget: Int = 128 * 1024 * 1024
    ) {
        self.file = file
        self.options = options
        self.background = background
        self.scale = scale
        self.stride = max(1, checkpointStride)
        self.memoryBudget = max(1, checkpointMemoryBudget)
        self.recordCount = file.records.count

        let bounds = file.header.bounds
        let deviceWidth = Double(Int64(bounds.right) - Int64(bounds.left) + 1)
        let deviceHeight = Double(Int64(bounds.bottom) - Int64(bounds.top) + 1)
        let (w, h) = EMFRenderer.canvasPixelSize(deviceWidth: deviceWidth, deviceHeight: deviceHeight, scale: scale)
        self.width = w
        self.height = h
        self.target = CGRect(x: 0, y: 0, width: w, height: h)
        self.pixelSize = CGSize(width: w, height: h)

        let plus = file.emfPlusStream()
        let forceGDI = options.emfPlusArbitration == .gdi && (plus.header?.isDual ?? false)
        self.supportsPartial = !(!forceGDI && plus.records.contains(where: \.isDrawing))
    }

    /// Renders the drawing through record `index` (clamped to the record range)
    /// and returns the image plus the DC state after that record. For an EMF+
    /// drawing file (`supportsPartial == false`) the image is the full render and
    /// the state is a best-effort GDI walk.
    public func step(throughRecordIndex index: Int) -> (image: CGImage?, state: PlaybackState) {
        let limit = max(0, min(index, recordCount - 1))

        guard supportsPartial else {
            let image = EMFRenderer.makeImage(file, scale: scale, background: background, options: options)?.0
            return (image, EMFRenderer.playbackState(of: file, throughRecordIndex: limit, options: options))
        }
        guard let context = EMFRenderer.bitmapContext(width: width, height: height, background: .transparent) else {
            return (nil, EMFRenderer.playbackState(of: file, throughRecordIndex: limit, options: options))
        }
        context.interpolationQuality = .none

        var log = EMFRenderLog()
        let base = EMFRenderer.deviceToTarget(header: file.header, target: target, log: &log)
        var dc = DeviceContext(header: file.header, fontSubstitutions: options.fontSubstitutions)

        var start = 1
        if let checkpoint = nearestCheckpoint(atOrBefore: limit) {
            // Resume from the cached raster + DC snapshot.
            context.draw(checkpoint.image, in: target)
            dc.restore(checkpoint.dc)
            start = checkpoint.index + 1
        } else if background == .white {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(target)
        }

        context.saveGState()
        if options.antialiasing == .crisp {
            context.setShouldAntialias(false)
        }
        if start <= limit {
            for recordIndex in start ... limit {
                EMFRenderer.playGDIRecord(file.payload(of: file.records[recordIndex]), into: context, dc: &dc, base: base, log: &log)
            }
        }
        context.restoreGState()

        let image = context.makeImage()
        cacheCheckpointIfDue(at: limit, image: image, dc: dc)
        return (image, dc.playbackState())
    }

    private func nearestCheckpoint(atOrBefore index: Int) -> CachedCheckpoint? {
        var bestPos: Int?
        for (pos, checkpoint) in checkpoints.enumerated() where checkpoint.index <= index {
            bestPos = pos
        }
        guard let bestPos else { return nil }
        useTick &+= 1
        checkpoints[bestPos].lastUsed = useTick
        return checkpoints[bestPos]
    }

    /// Caches a checkpoint at `index` when it lands on a stride boundary, at a
    /// clean path boundary, with a valid image, and is not already cached — then evicts the
    /// least-recently-used checkpoints until the total raster bytes fit the budget (P10).
    private func cacheCheckpointIfDue(at index: Int, image: CGImage?, dc: DeviceContext) {
        guard let image, index >= stride, index % stride == 0, dc.isAtCleanPathBoundary,
              !checkpoints.contains(where: { $0.index == index })
        else { return }
        let cost = max(1, image.bytesPerRow * image.height)
        guard cost <= memoryBudget else { return }   // one checkpoint over the whole budget: skip
        useTick &+= 1
        checkpoints.append(CachedCheckpoint(index: index, image: image, dc: dc.checkpoint(), cost: cost, lastUsed: useTick))
        currentCost += cost
        checkpoints.sort { $0.index < $1.index }
        evictUntilWithinBudget()
    }

    /// Drops the least-recently-used checkpoints until the resident raster bytes are within
    /// the budget. A step that lands past an evicted checkpoint simply re-renders from an
    /// earlier one — identical pixels, a little more work.
    private func evictUntilWithinBudget() {
        while currentCost > memoryBudget, checkpoints.count > 1,
              let lru = checkpoints.indices.min(by: { checkpoints[$0].lastUsed < checkpoints[$1].lastUsed }) {
            currentCost -= checkpoints[lru].cost
            checkpoints.remove(at: lru)
        }
    }
}
