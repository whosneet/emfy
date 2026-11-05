import EMFRender
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app/OS/device environment for the diagnostic report (S1a-6). Only coarse,
/// non-identifying values: the app version/build, the OS version, and the device
/// class (Mac / iPhone / iPad) — never a device name, serial, host name or user.
struct DiagnosticEnvironment {
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var deviceClass: String

    @MainActor
    static func current() -> DiagnosticEnvironment {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let deviceClass = "Mac"
        #else
        let osString = "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        return DiagnosticEnvironment(
            appVersion: version,
            appBuild: build,
            osVersion: osString,
            deviceClass: deviceClass
        )
    }
}

/// The clipboard write for the diagnostic report. Platform-specific but trivial.
enum DiagnosticClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Builds and copies the diagnostic report (S1a-6). The report can only carry
/// safe, non-identifying fields: a file name, path, drawing text or user name can
/// never reach it because the callers pass only the file extension, the byte
/// count (reported as a bucket), the record-kind counts and the plain-language
/// could-not-show summaries.
enum DiagnosticReportAction {
    /// The report text for the current file — the format comes from the extension
    /// only, so the real file name never appears.
    @MainActor
    static func fileReportText(
        fileExtension: String,
        byteCount: Int64,
        recordKinds: [MetafileRenderer.RecordKindCount],
        notes: [DiagnosticNote]
    ) -> String {
        let environment = DiagnosticEnvironment.current()
        let file = DiagnosticReport.fileInfo(
            fileExtension: fileExtension,
            byteCount: byteCount,
            recordKinds: recordKinds.map { DiagnosticReport.RecordKind(name: $0.name, count: $0.count) },
            couldNotShow: notes
        )
        return DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: environment.appVersion,
            appBuild: environment.appBuild,
            osVersion: environment.osVersion,
            deviceClass: environment.deviceClass,
            file: file
        ))
    }

    /// The system-only report (no file), for the Settings "Help & diagnostics" row.
    @MainActor
    static func systemReportText() -> String {
        let environment = DiagnosticEnvironment.current()
        return DiagnosticReport.text(DiagnosticReport.Input(
            appVersion: environment.appVersion,
            appBuild: environment.appBuild,
            osVersion: environment.osVersion,
            deviceClass: environment.deviceClass,
            file: nil
        ))
    }

    /// Copies the current file's report to the clipboard and confirms with a toast.
    @MainActor
    static func copyFileReport(
        entry: RecentEntry,
        recordKinds: [MetafileRenderer.RecordKindCount],
        notes: [DiagnosticNote],
        toast: ToastCenter
    ) {
        let text = fileReportText(
            fileExtension: (entry.displayName as NSString).pathExtension,
            byteCount: entry.byteCount,
            recordKinds: recordKinds,
            notes: notes
        )
        DiagnosticClipboard.copy(text)
        toast.show("Diagnostic report copied", systemImage: "doc.on.clipboard")
    }
}
