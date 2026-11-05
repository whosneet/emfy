import Foundation

/// Builds the "Copy Diagnostic Report" text (S1a Help & diagnostics).
///
/// Privacy is **structural**: the builder is handed only safe, non-identifying
/// fields — never a file name, a path, a user name, or any drawing text — so a
/// report cannot leak them. The format comes from the file extension only; the
/// size is reported as a coarse bucket, never the exact byte count; records are
/// reported as counts grouped by type; and the "couldn't show" notes are the
/// plain-language summaries only (counts and kinds), never the technical lines
/// that can name a font the file asked for. Australian English, plain words,
/// ready for a support email.
struct DiagnosticReport {

    /// The most record kinds the report lists in full before summarising the rest
    /// as "and N other kinds" (S-L6).
    static let maxRecordKinds = 30

    /// One record-type tally: a record name and how many of that kind appear.
    /// Structure only.
    struct RecordKind: Sendable, Equatable {
        var name: String
        var count: Int
    }

    /// The safe, file-scoped half of a report. Every field is non-identifying.
    struct FileInfo: Sendable {
        /// Full format name, e.g. "Enhanced Metafile" (from the extension only).
        var formatName: String
        /// Short badge, e.g. "EMF" (from the extension only).
        var formatBadge: String
        /// Exact bytes in; reported only as a coarse bucket.
        var byteCount: Int64
        /// Record counts grouped by type.
        var recordKinds: [RecordKind]
        /// The "What Emfy couldn't show" notes — summaries used only.
        var couldNotShow: [DiagnosticNote]
    }

    struct Input: Sendable {
        var appVersion: String
        var appBuild: String
        var osVersion: String
        /// The device class only — "Mac", "iPhone" or "iPad", never a device name.
        var deviceClass: String
        /// The current file, or `nil` for a system-only report (the Settings row
        /// with no file open).
        var file: FileInfo?
    }

    /// The plain-text report.
    static func text(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("Emfy diagnostic report")
        lines.append("")
        lines.append("App: Emfy \(input.appVersion) (\(input.appBuild))")
        lines.append("System: \(input.osVersion)")
        lines.append("Device: \(input.deviceClass)")

        guard let file = input.file else { return lines.joined(separator: "\n") }

        lines.append("")
        lines.append("File")
        lines.append("Format: \(file.formatName) (\(file.formatBadge))")
        lines.append("Size: \(byteSizeBucket(file.byteCount))")
        lines.append("")
        lines.append("Records by kind")
        if file.recordKinds.isEmpty {
            lines.append("• none recorded")
        } else {
            let sorted = file.recordKinds.sorted(by: recordKindOrder)
            // Cap the list so a pathological file with hundreds of record types can't
            // bloat a support email; the tail is summarised as a count (S-L6).
            for kind in sorted.prefix(maxRecordKinds) {
                lines.append("• \(kind.name): \(kind.count)")
            }
            let remaining = sorted.count - min(sorted.count, maxRecordKinds)
            if remaining > 0 {
                lines.append("• and \(remaining) other kind\(remaining == 1 ? "" : "s")")
            }
        }
        lines.append("")
        if file.couldNotShow.isEmpty {
            lines.append("What Emfy couldn’t show: nothing — the file drew in full.")
        } else {
            lines.append("What Emfy couldn’t show")
            for note in file.couldNotShow {
                // The summary only: a short count/kind line. The technical detail
                // is deliberately omitted — it can name a font the file requested.
                lines.append("• \(note.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Assembles a `FileInfo` from a file's SAFE metadata. The format label comes
    /// from the file *extension* only — the name, the path, and any drawing text
    /// are never passed in, so they cannot appear in the report.
    static func fileInfo(
        fileExtension: String,
        byteCount: Int64,
        recordKinds: [RecordKind],
        couldNotShow: [DiagnosticNote]
    ) -> FileInfo {
        // `names(for:)` reads only the path extension, so a bare "x.<ext>" keeps
        // the real file name out entirely.
        let names = MetafileFormatLabel.names(for: "x.\(fileExtension)")
        return FileInfo(
            formatName: names.full,
            formatBadge: names.short,
            byteCount: byteCount,
            recordKinds: recordKinds,
            couldNotShow: couldNotShow
        )
    }

    /// A coarse size band, never the exact byte count: an exact size is a weak
    /// fingerprint of a specific file, and the report only needs the order of
    /// magnitude (S1a-6 privacy).
    static func byteSizeBucket(_ bytes: Int64) -> String {
        switch bytes {
        case ..<0: return "unknown"
        case 0 ..< 10_240: return "under 10 KB"
        case 10_240 ..< 102_400: return "10 KB to 100 KB"
        case 102_400 ..< 1_048_576: return "100 KB to 1 MB"
        case 1_048_576 ..< 10_485_760: return "1 MB to 10 MB"
        case 10_485_760 ..< 104_857_600: return "10 MB to 100 MB"
        default: return "over 100 MB"
        }
    }

    /// Most frequent first, then by name — the useful order for a support report.
    private static func recordKindOrder(_ a: RecordKind, _ b: RecordKind) -> Bool {
        a.count != b.count ? a.count > b.count : a.name < b.name
    }
}
