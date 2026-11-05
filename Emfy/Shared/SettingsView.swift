import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Emfy's Settings UI (S1a-2 / S1a-3). Every control reads and writes
/// `EmfySettings`; **nothing in the app acts on the settings yet** — the
/// behavioural wiring lands in S1a-4…S1a-6. On macOS it's the `Settings` scene
/// (⌘,) as a tabbed window; on iOS it's the sheet the library's More menu
/// presents.
struct SettingsView: View {
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        MacSettingsTabs()
        #else
        NavigationStack {
            IOSSettingsForm()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    SheetDoneToolbar { dismiss() }   // G2
                }
        }
        #endif
    }
}

// MARK: - Option display labels
//
// The user-facing label for each setting option lives here, in the UI layer, so
// the model stays free of presentation. Sentence case, Australian English.

/// A settings enum the pickers can list and label.
protocol SettingsOption: CaseIterable, Hashable, Sendable {
    var label: String { get }
}

extension EmfySettings.DefaultZoom: SettingsOption {
    var label: String { self == .fit ? "Fit" : "Actual size" }
}
extension EmfySettings.PageBackground: SettingsOption {
    var label: String {
        switch self {
        case .whitePage: "White page"
        case .checkerboard: "Checkerboard"
        case .matchAppearance: "Match appearance"
        }
    }
}
extension EmfySettings.DarkPageMode: SettingsOption {
    var label: String {
        switch self {
        case .off: "Off"
        case .dim: "Dim"
        case .invert: "Invert"
        }
    }
}
extension EmfySettings.OpenFilesIn: SettingsOption {
    var label: String { self == .frontWindow ? "Front window" : "New window" }
}
extension EmfySettings.MacScrollAction: SettingsOption {
    var label: String { self == .pan ? "Scroll to pan" : "Scroll to zoom" }
}
extension EmfySettings.SortOrder: SettingsOption {
    var label: String {
        switch self {
        case .date: "Date"
        case .name: "Name"
        case .size: "Size"
        }
    }
}
extension EmfySettings.RecentsLayout: SettingsOption {
    var label: String { self == .grid ? "Grid" : "List" }
}
extension EmfySettings.ThumbnailSize: SettingsOption {
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
extension EmfySettings.PNGScale: SettingsOption {
    var label: String { "\(rawValue)×" }
}
extension EmfySettings.PNGBackground: SettingsOption {
    var label: String { self == .white ? "White" : "Transparent" }
}
extension EmfySettings.ExportFormat: SettingsOption {
    var label: String { self == .png ? "PNG" : "PDF" }
}
extension EmfySettings.RecentsCap: SettingsOption {
    var label: String { "\(rawValue)" }
}

// Footer sentences, shared verbatim by both platforms.
private enum SettingsFooter {
    static let recentsCap = "Lowering Recents to keep may remove files Emfy received and is keeping; it’ll ask before removing any."
    static let privateMode = "Private mode keeps no history — files you open aren’t added to Recents and leave no thumbnails."
    static let darkPage = "Dim lowers the page brightness in Dark Mode; Invert flips a dark drawing to light while keeping its colours."
    static let exportLimit = "Very large drawings export at a lower scale to stay within size limits."
    static let pin = "Pin a file from its context menu to keep it at the top."
    static let macDiagnostics = "Copy Diagnostic Report is available from the File menu and the Info panel when a file is open."
    static let iOSDiagnostics = "Copy Diagnostic Report is available from the Info panel or the More menu when a file is open."
}

#if os(macOS)

// MARK: - Mac: tabbed Settings window

/// Toolbar-style tabs, each sizing the window to its own content.
private struct MacSettingsTabs: View {
    var body: some View {
        TabView {
            MacGeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacViewerTab()
                .tabItem { Label("Viewer", systemImage: "eye") }
            MacExportTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            MacHelpTab()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
    }
}

/// Fixed pane width so the tabs line up and the window never needs to scroll.
private let macSettingsWidth: CGFloat = 520

/// A describing label with a trailing fixed-width picker (C4b row idiom). Menu
/// style by default; segmented for two or three short choices.
private struct MacOptionRow<E: SettingsOption>: View {
    let title: String
    @Binding var value: E
    var segmented: Bool = false

    var body: some View {
        LabeledContent(title) { control }
    }

    @ViewBuilder private var control: some View {
        let picker = Picker(title, selection: $value) {
            ForEach(Array(E.allCases), id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()

        if segmented {
            picker.pickerStyle(.segmented).fixedSize()
        } else {
            picker.pickerStyle(.menu).fixedSize()
        }
    }
}

private struct MacGeneralTab: View {
    @Environment(RecentsStore.self) private var store
    @Environment(EmfySettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MacOptionRow(title: "Recents to keep", value: $settings.recentsToKeep)
                Toggle("Reopen last file at launch", isOn: $settings.reopenLastFileAtLaunch)
                Toggle("Show What’s New after updates", isOn: $settings.showWhatsNewAfterUpdates)
                LabeledContent("Recent files") {
                    Button("Clear Recents…", role: .destructive) {
                        MacRecentsConfirmation.confirmClear(store: store)
                    }
                    .disabled(store.entries.isEmpty)
                }
            } header: {
                Text("Library")
            } footer: {
                Text(SettingsFooter.recentsCap)
            }
            Section {
                MacOptionRow(title: "Sort recents by", value: $settings.sortRecentsBy, segmented: true)
                MacOptionRow(title: "Thumbnail size", value: $settings.thumbnailSize, segmented: true)
                Toggle("Private mode", isOn: $settings.privateMode)
            } header: {
                Text("Library extras")
            } footer: {
                Text(SettingsFooter.privateMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacViewerTab: View {
    @Environment(EmfySettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Viewer") {
                MacOptionRow(title: "Default zoom on open", value: $settings.defaultZoomOnOpen, segmented: true)
                MacOptionRow(title: "Page background", value: $settings.pageBackground)
                // The Mac retired its partial-support banner (0964d74); partial
                // support shows in the Info inspector, so there is no toggle here.
                // The toggle stays on iOS, where the banner still shows.
            }
            Section {
                MacOptionRow(title: "Page in Dark Mode", value: $settings.darkPageMode, segmented: true)
                Toggle("Page shadow", isOn: $settings.pageShadow)
                MacOptionRow(title: "Open files in", value: $settings.openFilesIn, segmented: true)
                MacOptionRow(title: "Trackpad and mouse scroll", value: $settings.macScrollAction)
            } header: {
                Text("Viewer extras")
            } footer: {
                Text(SettingsFooter.darkPage)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacExportTab: View {
    @Environment(EmfySettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MacOptionRow(title: "Default PNG scale", value: $settings.defaultPNGScale, segmented: true)
                MacOptionRow(title: "PNG background", value: $settings.pngBackground, segmented: true)
                MacOptionRow(title: "Default export format", value: $settings.defaultExportFormat, segmented: true)
            } header: {
                Text("Export")
            } footer: {
                Text(SettingsFooter.exportLimit)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacHelpTab: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Help") {
                LabeledContent("What’s New") {
                    Button("Show") { openWindow(id: "whats-new") }
                }
                LabeledContent("Changelog") {
                    Button("Show") { openWindow(id: "changelog") }
                }
                LabeledContent("Developer documentation") {
                    Button("Open") { if let url = EmfyLinks.gitHub { openURL(url) } }
                }
                LabeledContent("Contact the developer") {
                    Button("Email") { if let url = EmfyLinks.contact { openURL(url) } }
                }
            }
            Section("Diagnostics") {
                Text(SettingsFooter.macDiagnostics)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#else

// MARK: - iOS/iPadOS: sectioned Settings form

/// A system picker row; in a Form it renders as a navigation/menu row that reads
/// its label and value to VoiceOver.
private struct IOSOptionRow<E: SettingsOption>: View {
    let title: String
    @Binding var value: E

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(Array(E.allCases), id: \.self) { Text($0.label).tag($0) }
        }
    }
}

private struct IOSSettingsForm: View {
    @Environment(RecentsStore.self) private var store
    @Environment(EmfySettings.self) private var settings
    @Environment(\.openURL) private var openURL
    // The Settings sheet hosts its own removal flow (the window-level one is
    // covered by this sheet — C4a H3). Clear confirms and offers Save a Copy.
    @State private var removal = RemovalCoordinator()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Viewer") {
                IOSOptionRow(title: "Default zoom on open", value: $settings.defaultZoomOnOpen)
                IOSOptionRow(title: "Page background", value: $settings.pageBackground)
                Toggle("Show partial support banner", isOn: $settings.showPartialSupportBanner)
                NavigationLink("More Viewer Options") { IOSMoreViewerOptions() }
            }
            Section {
                IOSOptionRow(title: "Recents to keep", value: $settings.recentsToKeep)
                Toggle("Reopen last file at launch", isOn: $settings.reopenLastFileAtLaunch)
                Toggle("Show What’s New after updates", isOn: $settings.showWhatsNewAfterUpdates)
                Button(role: .destructive) {
                    removal.requestClear(store: store)
                } label: {
                    Label("Clear Recents…", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
                NavigationLink("More Library Options") { IOSMoreLibraryOptions() }
            } header: {
                Text("Library")
            } footer: {
                Text(SettingsFooter.recentsCap)
            }
            Section {
                IOSOptionRow(title: "Default PNG scale", value: $settings.defaultPNGScale)
                IOSOptionRow(title: "PNG background", value: $settings.pngBackground)
                IOSOptionRow(title: "Default export format", value: $settings.defaultExportFormat)
            } header: {
                Text("Export")
            } footer: {
                Text(SettingsFooter.exportLimit)
            }
            Section {
                NavigationLink {
                    WhatsNewView().navigationTitle("What’s New").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("What’s New", systemImage: "sparkles")
                }
                NavigationLink {
                    ChangelogView().navigationTitle("Changelog").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Changelog", systemImage: "list.bullet.rectangle")
                }
                Button {
                    if let url = EmfyLinks.gitHub { openURL(url) }
                } label: {
                    Label("Developer Documentation", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    if let url = EmfyLinks.contact { openURL(url) }
                } label: {
                    Label("Contact the Developer", systemImage: "envelope")
                }
            } header: {
                Text("Help & diagnostics")
            } footer: {
                Text(SettingsFooter.iOSDiagnostics)
            }
        }
        .recentsRemoval(removal, store: store, toast: nil)
    }
}

private struct IOSMoreViewerOptions: View {
    @Environment(EmfySettings.self) private var settings
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                IOSOptionRow(title: "Page in Dark Mode", value: $settings.darkPageMode)
            } footer: {
                Text(SettingsFooter.darkPage)
            }
            Section {
                Toggle("Page shadow", isOn: $settings.pageShadow)
                // Only where the system can open a second window (iPad, not iPhone).
                if supportsMultipleWindows {
                    IOSOptionRow(title: "Open files in", value: $settings.openFilesIn)
                }
            }
        }
        .navigationTitle("Viewer Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IOSMoreLibraryOptions: View {
    @Environment(EmfySettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                IOSOptionRow(title: "Sort recents by", value: $settings.sortRecentsBy)
                IOSOptionRow(title: "Layout", value: $settings.recentsLayout)
                IOSOptionRow(title: "Thumbnail size", value: $settings.thumbnailSize)
            } footer: {
                Text(SettingsFooter.pin)
            }
            Section {
                Toggle("Private mode", isOn: $settings.privateMode)
            } footer: {
                Text(SettingsFooter.privateMode)
            }
        }
        .navigationTitle("Library Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
