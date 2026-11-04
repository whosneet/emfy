import CoreGraphics
import EMFParse
import Foundation
import WMFParse

/// The open-any-metafile entry point: it takes an already-sniffed
/// `OpenedMetafile` (EMF, WMF, or placeable WMF; gzip is unwrapped upstream)
/// and renders it, dispatching to the EMF renderer, the embedded-EMF path, or
/// the WMF translation + playback.
///
/// This is the single door the app and the Quick Look extensions call. EMF
/// output is unchanged — an `.emf` input goes straight to the existing
/// `EMFRenderer` API, byte-for-byte as before.
public enum MetafileRenderer {

    // MARK: - Public API

    /// Renders `opened` into a fresh sRGB bitmap. Returns `nil` for an
    /// unrecognised format, a WMF/EMF that has no readable header, or a bitmap
    /// allocation failure — never a silently blank canvas for a parseable file.
    public static func makeImage(
        _ opened: OpenedMetafile,
        scale: CGFloat = 1
    ) -> (CGImage, EMFRenderLog)? {
        switch opened.format {
        case .emf:
            guard let file = try? EMFFile.parse(opened.data) else { return nil }
            return EMFRenderer.makeImage(file, scale: scale)
        case .wmf, .placeableWMF:
            return makeWMFImage(opened.data, scale: scale)
        case .gzip, .unknown:
            return nil
        }
    }

    /// Plays `opened` into `context`, mapping the metafile's device space onto
    /// `target`. For an unrecognised or header-less input this is a no-op (the
    /// context is untouched) and the returned log is empty.
    public static func render(
        _ opened: OpenedMetafile,
        into context: CGContext,
        target: CGRect
    ) -> EMFRenderLog {
        switch opened.format {
        case .emf:
            guard let file = try? EMFFile.parse(opened.data) else { return EMFRenderLog() }
            return EMFRenderer.render(file, into: context, target: target)
        case .wmf, .placeableWMF:
            guard let wmf = try? WMFFile.parse(opened.data) else { return EMFRenderLog() }
            if let file = embeddedEMF(of: wmf) {
                return EMFRenderer.render(file, into: context, target: target)
            }
            return renderProgram(WMFTranslator.translate(wmf), into: context, target: target)
        case .gzip, .unknown:
            return EMFRenderLog()
        }
    }

    // MARK: - WMF dispatch

    /// A complete, parseable embedded EMF plays instead of the WMF records
    /// (owner decision). Any inconsistency or a parse failure falls back to WMF.
    private static func embeddedEMF(of wmf: WMFFile) -> EMFFile? {
        guard case .reassembled(let bytes) = WMFEmbeddedEMF.reassemble(wmf),
              let file = try? EMFFile.parse(bytes)
        else { return nil }
        return file
    }

    private static func makeWMFImage(_ data: Data, scale: CGFloat) -> (CGImage, EMFRenderLog)? {
        guard let wmf = try? WMFFile.parse(data) else { return nil }
        if let file = embeddedEMF(of: wmf) {
            return EMFRenderer.makeImage(file, scale: scale)
        }
        return renderProgramToImage(WMFTranslator.translate(wmf), scale: scale)
    }

    // MARK: - WMF program playback

    /// Renders a translated WMF program into a fresh white sRGB bitmap sized
    /// from the program's device canvas (× `scale`).
    private static func renderProgramToImage(
        _ program: WMFRenderProgram,
        scale: CGFloat
    ) -> (CGImage, EMFRenderLog)? {
        // The caller-supplied scale is sanitised (not hostile file data); the
        // program canvas is already clamped by the translator.
        let safeScale = scale.isFinite && scale > 0 ? Double(scale) : 1
        let width = clampDimension(Double(program.canvasWidth) * safeScale)
        let height = clampDimension(Double(program.canvasHeight) * safeScale)
        let (w, h) = clampArea(width: width, height: height)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let log = renderProgram(program, into: context, target: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { return nil }
        return (image, log)
    }

    /// Plays a translated WMF program into `context`. The program's canvas is
    /// the device space; the preamble payloads carry the logical→device mapping,
    /// so the renderer reuses `DeviceContext`/`playGDIRecord` unchanged.
    private static func renderProgram(
        _ program: WMFRenderProgram,
        into context: CGContext,
        target: CGRect
    ) -> EMFRenderLog {
        var log = EMFRenderLog()
        let header = syntheticHeader(width: program.canvasWidth, height: program.canvasHeight)
        let base = EMFRenderer.deviceToTarget(header: header, target: target, log: &log)
        var dc = DeviceContext(header: header)

        context.saveGState()
        defer { context.restoreGState() }

        for payload in program.payloads {
            EMFRenderer.playGDIRecord(payload, into: context, dc: &dc, base: base, log: &log)
        }
        return log
    }

    /// A minimal EMF header whose bounds are the WMF device canvas (0,0)-(w-1,
    /// h-1) and whose reference-device metrics are zero, so the DC's metric map
    /// modes fall back to 96 DPI. Everything else is a drawing-irrelevant
    /// default.
    private static func syntheticHeader(width: Int, height: Int) -> EMFHeader {
        EMFHeader(
            bounds: RectL(left: 0, top: 0, right: Int32(max(1, width) - 1), bottom: Int32(max(1, height) - 1)),
            frame: RectL(left: 0, top: 0, right: 0, bottom: 0),
            recordSignature: 0x464D_4520,
            version: 0x0001_0000,
            bytes: 0,
            records: 0,
            handles: 0,
            nDescription: 0,
            offDescription: 0,
            nPalEntries: 0,
            device: SizeL(cx: 0, cy: 0),
            millimeters: SizeL(cx: 0, cy: 0),
            extension1: nil,
            extension2: nil,
            description: nil,
            variant: .base
        )
    }

    // MARK: - Canvas clamps (§8)
    //
    // Mirror EMFRenderer.makeImage's caps for the scaled WMF canvas. The
    // program canvas is already clamped by the translator at scale 1; these
    // bound the post-scale size.

    private static let canvasDimensionCap = 16_384
    private static let canvasAreaCap = 32_000_000

    private static func clampDimension(_ requested: Double) -> Int {
        guard requested.isFinite else { return canvasDimensionCap }
        let rounded = requested.rounded()
        if rounded < 1 { return 1 }
        if rounded > Double(canvasDimensionCap) { return canvasDimensionCap }
        return Int(rounded)
    }

    private static func clampArea(width: Int, height: Int) -> (width: Int, height: Int) {
        let area = width * height
        guard area > canvasAreaCap else { return (width, height) }
        let scale = (Double(canvasAreaCap) / Double(area)).squareRoot()
        return (
            max(1, Int((Double(width) * scale).rounded(.down))),
            max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }
}
