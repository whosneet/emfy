import Foundation

/// One user-defined font substitution (S1b Settings › Rendering): when the
/// `requestedFamily` is MISSING on the system, the renderer resolves to
/// `replacementFamily` instead of falling straight to the built-in substitution
/// table. Matching is case- and space-insensitive, exactly like the built-in
/// table (`FontMapper`). An installed family is never substituted, and if the
/// replacement family is itself missing the renderer falls through to the
/// built-in table.
///
/// A value type consulted entirely at render time; it carries no system or
/// CoreText state, so it is trivially `Sendable`.
public struct FontSubstitution: Sendable, Equatable {
    /// The family name as it appears in the metafile (GDI LOGFONT face name or
    /// EMF+ EmfPlusFont family). Matched case- and space-insensitively.
    public let requestedFamily: String
    /// The family name to use instead when `requestedFamily` is missing.
    public let replacementFamily: String

    public init(requestedFamily: String, replacementFamily: String) {
        self.requestedFamily = requestedFamily
        self.replacementFamily = replacementFamily
    }
}

/// The user-configurable rendering options (owner-approved Settings group
/// "Rendering", docs/v3-plan §9.4), threaded through every public render entry
/// point as a value with a default of `.default`.
///
/// `.default` reproduces every pre-option output byte-for-byte: smooth
/// antialiasing (the file's own state, including any EMF+ hint), no user font
/// substitutions, today's EMF+ arbitration, and a WMF's embedded EMF preferred.
///
/// No global or static mutable state: the options travel with the call, because
/// the Quick Look extensions and the app render concurrently.
///
/// Where each option takes effect:
/// - `antialiasing` and `fontSubstitutions` are DRAWING options, applied at
///   render time (`EMFRenderer` / `EMFPlusPlayback` / `FontMapper`).
/// - `emfPlusArbitration` selects which record set drives an EMF+ dual file's
///   drawing. Both record sets already live in one parsed `EMFFile`, so the
///   choice is realised inside `EMFRenderer.render` (gated on the file being
///   dual); `MetafileRenderer.prepare` only reports `Prepared.hasGDICopy`.
/// - `useEmbeddedEMF` is a SELECTION option: it changes which content a WMF
///   `Prepared` carries, so it is applied in `MetafileRenderer.prepare`.
/// - `playbackRecordBudget` is a PARSE option: it caps how many records
///   `MetafileRenderer.prepare` parses and translates, so it is applied there
///   too (threaded into `EMFFile.parse` / `WMFFile.parse`).
public struct RenderOptions: Sendable, Equatable {

    /// Geometry and text antialiasing.
    public enum Antialiasing: Sendable, Equatable {
        /// Today's behaviour: CoreGraphics' default smoothing for GDI geometry
        /// and text, and the file's own EMF+ antialias/text-hint state for the
        /// EMF+ path. Byte-identical to before this option existed.
        case smooth
        /// Antialiasing off for all geometry and text in both the GDI and the
        /// EMF+ path, overriding any EMF+ SetAntiAliasMode / text-rendering hint
        /// the file carries. Bitmap interpolation is unaffected (already
        /// nearest-neighbour).
        case crisp
    }

    /// Which record set drives an EMF+ dual file's drawing.
    public enum EMFPlusArbitration: Sendable, Equatable {
        /// Today's arbitration ([MS-EMFPLUS] §1.3.1): a file with any EMF+
        /// drawing record plays in EMF+ mode.
        case emfPlus
        /// Play the GDI (EMF) records and ignore EMF+ drawing. Applies ONLY to an
        /// EMF+ *dual* file (the EmfPlusHeader Dual flag is set, [MS-EMFPLUS]
        /// §2.3.3.3); for an EMF+-only file it has no effect, because there is no
        /// complete GDI copy to fall back to.
        case gdi
    }

    /// Geometry and text antialiasing (default `.smooth`).
    public var antialiasing: Antialiasing
    /// Ordered, user-defined substitutions consulted — before the built-in
    /// table — when a requested family is missing on the system. Bounded at
    /// consumption: at most `FontMapper.userSubstitutionLimit` entries are
    /// considered and names longer than `FontMapper.familyNameLengthLimit`
    /// characters are ignored.
    public var fontSubstitutions: [FontSubstitution]
    /// EMF+ dual-file arbitration (default `.emfPlus`).
    public var emfPlusArbitration: EMFPlusArbitration
    /// Whether a WMF's complete, parseable embedded EMF supersedes its own
    /// records (default `true`, today's behaviour). When `false`, `prepare`
    /// plays the WMF records even when a usable embedded EMF reassembles, and
    /// reports `Prepared.EmbeddedEMF.declined`.
    public var useEmbeddedEMF: Bool
    /// A per-render cap on how many top-level metafile records this call parses,
    /// translates, and plays — a MEMORY budget for a sandboxed context, NOT a
    /// drawing option (M1). `nil` (the default) means no budget: every record up
    /// to the parser's own hard cap (`EMFFile`/`WMFFile.recordCountLimit`,
    /// 1,000,000) is prepared and played, exactly as before this option existed —
    /// full fidelity, which the main app uses.
    ///
    /// A sandboxed Quick Look preview / thumbnail extension passes a small,
    /// conservative value. A crafted WMF with millions of tiny records otherwise
    /// drives `WMFTranslator.translate` to ≈152 bytes PER record (≈356 MiB for a
    /// 1M-record file), which jetsam-kills the extension. With a budget,
    /// `MetafileRenderer.prepare` passes it to `WMFFile.parse` / `EMFFile.parse`
    /// as a per-call record limit (clamped to `recordCountLimit`), so only the
    /// first N records are materialised and translated; the extension renders
    /// that best partial output (primer §8 log-and-skip), never a crash or a
    /// killed process. A crafted EMF is far cheaper (payloads decode lazily), so
    /// the budget bounds it too but was not the pressing case.
    public var playbackRecordBudget: Int?

    public init(
        antialiasing: Antialiasing = .smooth,
        fontSubstitutions: [FontSubstitution] = [],
        emfPlusArbitration: EMFPlusArbitration = .emfPlus,
        useEmbeddedEMF: Bool = true,
        playbackRecordBudget: Int? = nil
    ) {
        self.antialiasing = antialiasing
        self.fontSubstitutions = fontSubstitutions
        self.emfPlusArbitration = emfPlusArbitration
        self.useEmbeddedEMF = useEmbeddedEMF
        self.playbackRecordBudget = playbackRecordBudget
    }

    /// The options that reproduce every pre-option output exactly.
    public static let `default` = RenderOptions()
}
