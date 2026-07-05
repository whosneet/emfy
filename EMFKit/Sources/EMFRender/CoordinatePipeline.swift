import CoreGraphics
import EMFParse
import Foundation

/// The logical → device coordinate pipeline (primer §5), built as pure,
/// unit-testable functions over plain values — no CGContext, no DC mutation.
///
/// The composed mapping is: world transform first (logical → page), then the
/// map-mode window/viewport mapping (page → device). The final canvas fit and
/// the single y-flip for CoreGraphics' y-up space are applied separately, at
/// canvas level, by the renderer — never here.
///
/// Page → device, per the GDI mapping ([MS-EMF] §2.3.11 window/viewport
/// records; the SETVIEWPORTEXTEX/SETWINDOWEXTEX playback semantics):
///
///     device.x = (page.x − windowOrg.x) × (viewportExt.cx / windowExt.cx) + viewportOrg.x
///     device.y = (page.y − windowOrg.y) × (viewportExt.cy / windowExt.cy) + viewportOrg.y
///
/// Window/viewport EXTENTS scale only in MM_ISOTROPIC and MM_ANISOTROPIC. In
/// MM_TEXT the scale is fixed at 1 (1 logical unit = 1 device pixel, y down);
/// in the fixed metric modes the scale is derived from the header's physical
/// metrics and y is negated (those modes are y-up). ORIGINS offset in every
/// mode. This matches GDI: SetWindowExtEx/SetViewportExtEx return failure in
/// any mode other than MM_ISOTROPIC/MM_ANISOTROPIC, so the stored extents have
/// no effect on the mapping there.
enum CoordinatePipeline {

    /// A page→device scale pair. `nil` means "leave the mapping unchanged"
    /// (a zero-extent record the caller must log and skip).
    struct Scale: Equatable {
        var sx: Double
        var sy: Double
    }

    /// The page→device scale for `mapMode`, or `nil` when a required extent is
    /// zero (guarded division — the caller keeps the previous mapping and logs
    /// `.zeroExtentMapping`).
    ///
    /// - `header`: source of the physical metrics for the fixed metric modes.
    /// - `windowExt` / `viewportExt`: current DC extents (used only for the
    ///   two arbitrary-unit modes).
    static func pageToDeviceScale(
        mapMode: MapMode,
        windowExt: SizeL,
        viewportExt: SizeL,
        header: EMFHeader
    ) -> Scale? {
        switch mapMode {
        case .text, .unknown:
            // 1 logical unit = 1 device pixel, y down. Unknown modes fall back
            // to MM_TEXT (log-and-skip philosophy: draw something sane).
            return Scale(sx: 1, sy: 1)

        case .anisotropic:
            return extentScale(windowExt: windowExt, viewportExt: viewportExt)

        case .isotropic:
            guard let raw = extentScale(windowExt: windowExt, viewportExt: viewportExt) else {
                return nil
            }
            // MM_ISOTROPIC requires equal |sx| and |sy|: shrink the larger
            // magnitude toward the smaller, preserving each sign. ([MS-EMF]
            // §2.1.21 MM_ISOTROPIC — "units along both axes … equally sized".)
            let mag = min(abs(raw.sx), abs(raw.sy))
            let sxSign: Double = raw.sx < 0 ? -1 : 1
            let sySign: Double = raw.sy < 0 ? -1 : 1
            return Scale(sx: mag * sxSign, sy: mag * sySign)

        case .loMetric, .hiMetric, .loEnglish, .hiEnglish, .twips:
            return metricScale(mapMode: mapMode, header: header)
        }
    }

    /// The viewport/window extent ratio, or `nil` when any of the four extents
    /// is zero. A zero window extent is the divide-by-zero the contract guards;
    /// a zero viewport extent is rejected too — it would collapse the mapping
    /// to a line, and "keep the previous valid mapping" is the agreed reading
    /// for both.
    private static func extentScale(windowExt: SizeL, viewportExt: SizeL) -> Scale? {
        guard windowExt.cx != 0, windowExt.cy != 0,
              viewportExt.cx != 0, viewportExt.cy != 0
        else { return nil }
        return Scale(
            sx: Double(viewportExt.cx) / Double(windowExt.cx),
            sy: Double(viewportExt.cy) / Double(windowExt.cy)
        )
    }

    /// Device pixels per logical unit for the fixed metric map modes. Derived
    /// from the header's device-pixels-per-millimetre ratio; y is negated
    /// (these modes are y-up, [MS-EMF] §2.1.21). Falls back to 96 DPI when the
    /// header metrics are zero. Returns a non-nil scale in all cases (the
    /// DPI fallback removes the divide-by-zero).
    private static func metricScale(mapMode: MapMode, header: EMFHeader) -> Scale? {
        // Device pixels per millimetre from the reference device. Guard both
        // ratios; fall back to 96 DPI (25.4 mm/inch) when a metric is zero.
        let fallback = 96.0 / 25.4          // px per mm at 96 DPI
        let pxPerMmX = ratio(Double(header.device.cx), Double(header.millimeters.cx)) ?? fallback
        let pxPerMmY = ratio(Double(header.device.cy), Double(header.millimeters.cy)) ?? fallback

        // Logical-unit size in millimetres for each fixed mode.
        let mmPerUnit: Double
        switch mapMode {
        case .loMetric:  mmPerUnit = 0.1            // 0.1 mm
        case .hiMetric:  mmPerUnit = 0.01           // 0.01 mm
        case .loEnglish: mmPerUnit = 0.01 * 25.4    // 0.01 inch
        case .hiEnglish: mmPerUnit = 0.001 * 25.4   // 0.001 inch
        case .twips:     mmPerUnit = 25.4 / 1440.0  // 1/1440 inch
        default:         mmPerUnit = 0
        }

        return Scale(sx: pxPerMmX * mmPerUnit, sy: -(pxPerMmY * mmPerUnit))
    }

    /// `numerator / denominator`, or `nil` when the denominator is zero.
    private static func ratio(_ numerator: Double, _ denominator: Double) -> Double? {
        guard denominator != 0 else { return nil }
        return numerator / denominator
    }

    /// Composes the full logical → device transform for the given DC state.
    ///
    /// - `world`: the DC world transform (logical → page).
    /// - `scale`: the page → device scale from `pageToDeviceScale`.
    /// - `windowOrg` / `viewportOrg`: current DC origins.
    ///
    /// The page→device affine is the closed form of the mapping equation:
    /// `device = scale · (page − windowOrg) + viewportOrg`, i.e.
    /// `[sx 0 0 sy tx ty]` with `tx = viewportOrg.x − sx·windowOrg.x`.
    /// World is applied first: `world.concatenating(pageToDevice)` — CG's
    /// row-vector `a.concatenating(b)` means "apply a then b".
    static func resolvedTransform(
        world: CGAffineTransform,
        scale: Scale,
        windowOrg: PointL,
        viewportOrg: PointL
    ) -> CGAffineTransform {
        let tx = Double(viewportOrg.x) - scale.sx * Double(windowOrg.x)
        let ty = Double(viewportOrg.y) - scale.sy * Double(windowOrg.y)
        let pageToDevice = CGAffineTransform(
            a: CGFloat(scale.sx), b: 0,
            c: 0, d: CGFloat(scale.sy),
            tx: CGFloat(tx), ty: CGFloat(ty)
        )
        return world.concatenating(pageToDevice)
    }

    /// Builds a `CGAffineTransform` from an EMFParse `XForm` ([MS-EMF] §2.2.28):
    ///     X' = M11·X + M21·Y + Dx
    ///     Y' = M12·X + M22·Y + Dy
    /// which is exactly CG's `[a b c d tx ty]` = `[M11 M12 M21 M22 Dx Dy]`.
    static func affine(from xform: XForm) -> CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(xform.m11), b: CGFloat(xform.m12),
            c: CGFloat(xform.m21), d: CGFloat(xform.m22),
            tx: CGFloat(xform.dx), ty: CGFloat(xform.dy)
        )
    }
}
