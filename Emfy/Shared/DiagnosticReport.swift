import Foundation

/// Builds the "Copy Diagnostic Report" text (S1a Help & diagnostics).
///
/// Privacy is **structural**: the builder is handed only safe, non-identifying
/// fields — never a file name, a path, or any drawing text — so a report cannot
/// leak them. The format is reported from the extension-derived label only. The
/// report carries app version/build, OS, device model, format, byte size,
/// picture size, record count, and every "couldn't show" note with its technical
/// detail. Australian English, plain words, ready for a support email.
struct DiagnosticReport {
    struct Input: Sendable {
        var appVersion: String
        var appBuild: String
        var osVersion: String
        var deviceModel: String
        /// Full format name, e.g. "Enhanced Metafile" (derived from the extension).
        var formatName: String
        /// Short badge, e.g. "EMF" (derived from the extension).
        var formatBadge: String
        var byteCount: Int64
        var pixelWidth: Int
        var pixelHeight: Int
        var recordCount: Int
        /// The "What Emfy couldn't show" notes (plain summary + technical detail).
        /// These are structural notes about rendering — never drawing content.
        var couldNotShow: [DiagnosticNote]
    }

    /// The plain-text report.
    static func text(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("Emfy diagnostic report")
        lines.append("")
        lines.append("App: Emfy \(input.appVersion) (\(input.appBuild))")
        lines.append("System: \(input.osVersion)")
        lines.append("Device: \(input.deviceModel)")
        lines.append("")
        lines.append("File")
        lines.append("Format: \(input.formatName) (\(input.formatBadge))")
        lines.append("Size: \(input.byteCount.formatted(RecentEntry.byteCountStyle))")
        lines.append("Picture: \(input.pixelWidth) × \(input.pixelHeight) px")
        lines.append("Records: \(input.recordCount)")
        lines.append("")
        if input.couldNotShow.isEmpty {
            lines.append("What Emfy couldn’t show: nothing — the file drew in full.")
        } else {
            lines.append("What Emfy couldn’t show")
            for note in input.couldNotShow {
                lines.append("• \(note.summary)")
                lines.append("  \(note.technicalDetail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Assembles an `Input` from a file's SAFE metadata. The format label comes
    /// from the file *extension* only — the name, the path, and any drawing text
    /// are never passed in, so they cannot appear in the report.
    static func input(
        fileExtension: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceModel: String,
        byteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        recordCount: Int,
        couldNotShow: [DiagnosticNote]
    ) -> Input {
        // `names(for:)` reads only the path extension, so a bare "x.<ext>" keeps
        // the real file name out entirely.
        let names = MetafileFormatLabel.names(for: "x.\(fileExtension)")
        return Input(
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: osVersion,
            deviceModel: deviceModel,
            formatName: names.full,
            formatBadge: names.short,
            byteCount: byteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            recordCount: recordCount,
            couldNotShow: couldNotShow
        )
    }
}
