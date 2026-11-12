#if EMFY_DMG && os(macOS)
import SwiftUI

/// The Updates UI for the GitHub/DMG build (U1): the Settings ▸ Updates group, the
/// one-time first-launch sheet, and the Emfy ▸ Check for Updates… menu command. All
/// gated behind `EMFY_DMG`, so the sandboxed App Store build contains none of it.

extension UpdateMode {
    var menuLabel: String {
        switch self {
        case .off: "Don’t check for updates"
        case .notifyOnLaunch: "Notify me when updates are available"
        case .autoDownload: "Download updates, let me install them"
        case .autoUpdate: "Install updates automatically"
        }
    }

    /// A short label for the picker and the first-launch choices.
    var shortLabel: String {
        switch self {
        case .off: "Off"
        case .notifyOnLaunch: "Notify me"
        case .autoDownload: "Download automatically"
        case .autoUpdate: "Install automatically"
        }
    }
}

/// The Updates tab shown in the Mac Settings window (DMG build only).
struct UpdatesSettingsTab: View {
    @State private var controller = UpdateController.shared

    private var lastCheckedText: String {
        guard let date = controller.lastChecked else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Picker("Check for updates", selection: $controller.mode) {
                    ForEach(UpdateMode.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
                }
                Toggle("Include beta versions", isOn: $controller.includeBeta)
            } header: {
                Text("Updates")
            } footer: {
                Text("Emfy updates itself from signed, notarised releases on GitHub. The App Store build updates through the App Store instead.")
            }
            Section {
                LabeledContent("Status") { statusView }
                LabeledContent("Last checked") { Text(lastCheckedText).foregroundStyle(.secondary) }
                LabeledContent("Current version") { Text(controller.currentVersionString).foregroundStyle(.secondary) }
                LabeledContent("Updates") {
                    Button("Check Now") { controller.checkNow() }
                        .disabled(isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .checking, .downloading, .verifying: return true
        default: return false
        }
    }

    @ViewBuilder private var statusView: some View {
        switch controller.phase {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Emfy is up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let version):
            HStack(spacing: 8) {
                Text("Version \(version) available").fontWeight(.medium)
                Button("Download") { controller.downloadNow() }
            }
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
        case .verifying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifying…") }
        case .readyToInstall(let version):
            HStack(spacing: 8) {
                Text("Version \(version) ready").fontWeight(.medium)
                Button("Restart to Update") { controller.restartToUpdate() }
            }
        case .failed(let error):
            Label(error.userMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

/// The one-time first-launch "Keep Emfy up to date?" sheet (DMG build only).
struct UpdateFirstLaunchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller = UpdateController.shared
    @State private var choice: UpdateMode = UpdateFirstLaunch.defaultMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Keep Emfy up to date?")
                    .font(.title2).fontWeight(.semibold)
                Text("This copy of Emfy can update itself from signed, notarised releases on GitHub. Choose how you’d like updates handled — you can change this any time in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Updates", selection: $choice) {
                ForEach(UpdateMode.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Continue") {
                    controller.chooseMode(choice)
                    controller.startAutomaticCheckIfDue()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// A view modifier that shows the first-launch sheet once, from the first library
/// window to appear (DMG build only).
private struct FirstLaunchUpdatesModifier: ViewModifier {
    @State private var controller = UpdateController.shared
    @State private var showSheet = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                #if DEBUG
                if EditorDebugLaunch.isActive && !ProcessInfo.processInfo.arguments.contains("-EmfyDebugFirstLaunchUpdates") {
                    return
                }
                #endif
                if controller.shouldPromptFirstLaunch {
                    showSheet = true
                } else {
                    controller.startAutomaticCheckIfDue()
                }
            }
            .sheet(isPresented: $showSheet) {
                UpdateFirstLaunchSheet()
                    .interactiveDismissDisabled()
            }
    }
}

extension View {
    /// Presents the one-time update first-launch sheet (DMG build only), else kicks
    /// off the throttled launch check.
    func updatesFirstLaunch() -> some View {
        modifier(FirstLaunchUpdatesModifier())
    }
}

/// Adds "Check for Updates…" to the app menu (DMG build only).
struct CheckForUpdatesCommands: Commands {
    @State private var controller = UpdateController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { controller.checkNow() }
        }
    }
}
#endif
