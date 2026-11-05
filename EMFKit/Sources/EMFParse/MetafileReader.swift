import Foundation

/// A non-fatal observation from opening a metafile — either from the signature
/// sniff or from the gzip unwrap. Advisory (§8): never changes the format.
public enum MetafileDiagnostic: Sendable, Equatable {
    case sniff(MetafileSniffDiagnostic)
    case gzip(GzipDiagnostic)
}

/// The errors opening a metafile throws. A non-gzip input within the size cap
/// never throws — an unrecognised file is reported as `.unknown`, not an error.
public enum MetafileOpenError: Error, Sendable, Equatable {
    /// The gzip wrapper was malformed; carries the underlying gzip failure.
    case gzip(GzipError)
    /// The gzip payload is itself gzip. One level of unwrapping only; nested
    /// gzip is refused (§8, primer §8 v1.5).
    case nestedGzip
    /// The raw input exceeded the front-door size cap and was refused before any
    /// parse or inflate (§8). `limit` is the ceiling that was applied.
    case inputTooLarge(limit: Int)
}

/// The front door: raw file bytes in, a detected format and the bytes to parse
/// out, after unwrapping a gzip (.emz / .wmz) wrapper at most once.
///
/// For W2 this lives in EMFParse (not EMFRender): it needs no rendering, and
/// keeping it here lets `emfy-dump` reach it without a new dependency. Plan §2
/// hands the open-any-metafile entry point to EMFRender once WMFParse exists
/// (W3/W4); EMFRender gets nothing in W2. WMF results carry the format and
/// bytes only — nothing parses WMF yet.
public struct OpenedMetafile: Sendable, Equatable {
    /// The format of `data`. Never `.gzip` — a gzip wrapper is always unwrapped.
    public let format: MetafileFormat
    /// The bytes to hand to a parser: the inflated payload for a gzip input,
    /// otherwise the original input.
    public let data: Data
    /// True when the input was gzip-wrapped and `data` is the inflated payload.
    public let wasDecompressed: Bool
    /// Advisory observations from the sniff and any gzip unwrap, in order.
    public let diagnostics: [MetafileDiagnostic]

    // MARK: - Ceilings (§8)

    /// Front-door cap on the raw bytes handed to `open` (§8). It bounds both a
    /// plain (uncompressed) metafile and a gzip wrapper before either is parsed or
    /// inflated. The cap must clear any plausible real input: the largest real
    /// metafile seen across the corpora is ~14.1 MiB, and a plain file equivalent
    /// to the largest allowed `.emz`/`.wmz` can be as large as the inflate output
    /// ceiling (64 MiB on macOS). macOS sets 128 MiB — 2× that output ceiling and
    /// ~9× the largest real file — so legitimate inputs have wide headroom while a
    /// multi-hundred-MB/GB blob is refused before `EMFFile.parse` copies it into
    /// its normalised buffer (the real memory cost §8 bounds). iOS, whose Quick
    /// Look extension runs under a ~30 MB budget (I4), sets 48 MiB — 2× the iOS
    /// 24 MiB inflate ceiling, still far above any real metafile.
    #if os(iOS)
    public static let defaultInputByteCeiling = 48 * 1024 * 1024
    #else
    public static let defaultInputByteCeiling = 128 * 1024 * 1024
    #endif

    /// The inflate output ceiling `open` applies to a gzip wrapper, mirroring
    /// GzipInflate's platform default so this public entry point can name it as a
    /// default argument. Override per call via `gzipOutputCeiling`.
    public static let defaultGzipOutputCeiling = GzipInflate.defaultOutputCeiling

    init(
        format: MetafileFormat,
        data: Data,
        wasDecompressed: Bool,
        diagnostics: [MetafileDiagnostic]
    ) {
        self.format = format
        self.data = data
        self.wasDecompressed = wasDecompressed
        self.diagnostics = diagnostics
    }

    /// Sniffs `data`, unwraps a gzip wrapper once if present, and reports the
    /// resulting format plus the bytes to parse.
    ///
    /// Refuses an input larger than `inputByteCeiling` with `.inputTooLarge`
    /// before any work (§8). Otherwise throws only for a gzip input that fails to
    /// inflate (past `gzipOutputCeiling`) or that wraps another gzip. Any non-gzip
    /// input within the cap — including unrecognised bytes — returns without
    /// throwing. The two ceilings default to the platform values and can be
    /// overridden (e.g. to the tighter iOS budget from a macOS test).
    public static func open(
        _ data: Data,
        inputByteCeiling: Int = defaultInputByteCeiling,
        gzipOutputCeiling: Int = defaultGzipOutputCeiling
    ) throws(MetafileOpenError) -> OpenedMetafile {
        guard data.count <= inputByteCeiling else {
            throw .inputTooLarge(limit: inputByteCeiling)
        }

        let signature = MetafileSignature.detect(data)
        var diagnostics = signature.diagnostics.map(MetafileDiagnostic.sniff)

        guard signature.format == .gzip else {
            return OpenedMetafile(
                format: signature.format,
                data: data,
                wasDecompressed: false,
                diagnostics: diagnostics
            )
        }

        let inflated: GzipInflate.Result
        do {
            inflated = try GzipInflate.inflate(data, ceiling: gzipOutputCeiling)
        } catch {
            throw .gzip(error)
        }
        diagnostics.append(contentsOf: inflated.diagnostics.map(MetafileDiagnostic.gzip))

        // One level of unwrapping only: refuse a gzip-inside-gzip payload (§8).
        let innerSignature = MetafileSignature.detect(inflated.data)
        guard innerSignature.format != .gzip else {
            throw .nestedGzip
        }
        diagnostics.append(contentsOf: innerSignature.diagnostics.map(MetafileDiagnostic.sniff))

        return OpenedMetafile(
            format: innerSignature.format,
            data: inflated.data,
            wasDecompressed: true,
            diagnostics: diagnostics
        )
    }
}
