import Foundation

/// A non-fatal observation from opening a metafile — either from the signature
/// sniff or from the gzip unwrap. Advisory (§8): never changes the format.
public enum MetafileDiagnostic: Sendable, Equatable {
    case sniff(MetafileSniffDiagnostic)
    case gzip(GzipDiagnostic)
}

/// The one error opening a metafile throws, and only for a gzip wrapper that
/// cannot be unwrapped. A non-gzip input never throws — an unrecognised file is
/// reported as `.unknown`, not an error.
public enum MetafileOpenError: Error, Sendable, Equatable {
    /// The gzip wrapper was malformed; carries the underlying gzip failure.
    case gzip(GzipError)
    /// The gzip payload is itself gzip. One level of unwrapping only; nested
    /// gzip is refused (§8, primer §8 v1.5).
    case nestedGzip
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
    /// Throws only `MetafileOpenError`, and only for a gzip input that fails to
    /// inflate or that wraps another gzip. Any non-gzip input — including
    /// unrecognised bytes — returns without throwing.
    public static func open(_ data: Data) throws(MetafileOpenError) -> OpenedMetafile {
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
            inflated = try GzipInflate.inflate(data)
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
