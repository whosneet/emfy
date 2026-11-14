import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
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
extension EmfySettings.RenderEdges: SettingsOption {
    var label: String { self == .smooth ? "Smooth" : "Crisp" }
}
extension EmfySettings.EMFPlusSource: SettingsOption {
    var label: String { self == .emfPlus ? "Show EMF+" : "Show GDI" }
}
extension SharedRenderSettings.ThumbnailBackground: SettingsOption {
    var label: String { self == .white ? "White" : "Transparent" }
}
extension SharedRenderSettings.PreviewSharpness: SettingsOption {
    var label: String { self == .standard ? "Standard" : "High" }
}

// MARK: - Thumbnail-size metrics (S1a-5)
//
// One mapping from the Thumbnail size setting to the dimensions each surface uses,
// so the Mac sidebar row, the iOS grid tile and the iOS list row all scale together.

extension EmfySettings.ThumbnailSize {
    /// The Mac sidebar row's thumbnail box.
    var sidebarThumbnail: CGSize {
        switch self {
        case .small: CGSize(width: 36, height: 27)
        case .medium: CGSize(width: 46, height: 34)
        case .large: CGSize(width: 62, height: 46)
        }
    }

    /// The iOS grid's minimum tile width (before Dynamic Type scaling).
    var gridMinWidth: CGFloat {
        switch self {
        case .small: 120
        case .medium: 158
        case .large: 196
        }
    }

    /// The iOS list row's thumbnail box.
    var listThumbnail: CGSize {
        switch self {
        case .small: CGSize(width: 44, height: 33)
        case .medium: CGSize(width: 58, height: 43)
        case .large: CGSize(width: 76, height: 57)
        }
    }
}

// Footer sentences, shared verbatim by both platforms.
private enum SettingsFooter {
    static let recentsCap = "Lowering Recents to keep may remove files Emfy received and is keeping; it’ll ask before removing any."
    static let privateMode = "Private mode keeps no history or copies of the files you open in Emfy. They aren’t added to Recents and leave no thumbnails."
    static let darkPage = "Dim lowers the page brightness in Dark Mode; Invert flips a dark drawing to light while keeping its colours."
    static let recognizeTextInPictures = "Lets Find and Copy All Text read text inside embedded pictures. Recognition runs on your device; nothing is sent anywhere."
    static let exportLimit = "Very large drawings export at a lower scale to stay within size limits."
    static let pin = "Pin a file from its context menu to keep it at the top."
    static let fullEditorOnIPhone = "Shows all editing tools on iPhone. Best on larger screens and iPhone Duo."
    static let macDiagnostics = "This copies app, system and device details only, with no file names or drawing content. A file’s own report is in the File menu and the Info panel."
    static let iOSDiagnostics = "This copies app, system and device details only, with no file names or drawing content. A file’s own report is in the viewer’s share menu and the Info panel."
}

// MARK: - Rendering group (S1b)

/// Footer sentences for the Rendering group, shared verbatim by both platforms.
private enum RenderingFooter {
    static let edges = "Crisp shows hard pixel edges, like Windows, with no smoothing."
    static let emfPlus = "This only changes files that hold both an EMF+ and a GDI version."
    static let wmf = "Some WMF files carry a fuller built-in EMF version of the drawing."
    static let fonts = "Used only when a drawing asks for a font this device doesn’t have."
    static let fontCap = "You can keep up to \(EmfySettings.fontSubstitutionRowLimit) substitutions."
    static let emptyFonts = "No font substitutions yet."
    /// Quick Look options footer (S1b-2b). Platform-specific surface name.
    #if os(macOS)
    static let quickLook = "Applies to previews and icons in Finder. Existing icons may update only when the file changes."
    #else
    static let quickLook = "Applies to previews and icons in Files. Existing icons may update only when the file changes."
    #endif
}

/// The installed font families to choose a replacement from (S1b). Enumerated on
/// the main actor because the font APIs are main-actor only; the pickers load it
/// into state from a `.task`, so the enumeration never blocks a view initialiser.
enum FontFamilyCatalog {
    @MainActor static func installedFamilies() -> [String] {
        #if os(macOS)
        let families = NSFontManager.shared.availableFontFamilies
        #else
        let families = UIFont.familyNames
        #endif
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Drives the add/edit sheet for one substitution row. A fresh `id` per
/// presentation, so re-opening always re-presents (`.sheet(item:)`).
private struct FontSubstitutionDraft: Identifiable {
    let id = UUID()
    /// The row being edited, or `nil` when adding a new one.
    var editingID: FontSubstitutionEntry.ID?
    var requested: String = ""
    var replacement: String = ""
}

/// One "requested → replacement" row label, shared by both platforms. One
/// accessibility element that reads as a sentence.
private struct SubstitutionRowLabel: View {
    let entry: FontSubstitutionEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Stack requested above replacement with a downward arrow, and drop the
                // single-line clamp, so neither name is truncated at large text (A-H2).
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.requested)
                    Image(systemName: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(entry.replacement)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Text(entry.requested)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(entry.replacement)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.requested.isEmpty ? "Unnamed font" : entry.requested), replaced by \(entry.replacement)")
    }
}

/// The add/edit sheet: a freely-typed requested family and a searchable installed
/// replacement family (S1b). Shared by both platforms; presented as a sheet so it
/// has its own `NavigationStack` for the font picker push on either platform.
private struct FontSubstitutionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var requested: String
    @State private var replacement: String
    @State private var showDiscardConfirm = false
    @FocusState private var requestedFocused: Bool
    private let isEditing: Bool
    private let initialRequested: String
    private let initialReplacement: String
    private let onSave: (String, String) -> Void

    init(draft: FontSubstitutionDraft, onSave: @escaping (String, String) -> Void) {
        _requested = State(initialValue: draft.requested)
        _replacement = State(initialValue: draft.replacement)
        initialRequested = draft.requested
        initialReplacement = draft.replacement
        isEditing = draft.editingID != nil
        self.onSave = onSave
    }

    private var trimmedRequested: String { requested.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedReplacement: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedRequested.isEmpty && !trimmedReplacement.isEmpty }

    /// Whether dismissing would discard typed input (C5e U4).
    private var hasUnsavedInput: Bool {
        requested != initialRequested || replacement != initialReplacement
    }

    private func cancelTapped() {
        if hasUnsavedInput { showDiscardConfirm = true } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Font name in the drawing", text: $requested)
                        .focused($requestedFocused)   // A-M6: initial focus here
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        #endif
                } header: {
                    Text("Requested font")
                } footer: {
                    Text("Type the font name as the drawing asks for it.")
                }
                Section("Replacement font") {
                    NavigationLink {
                        FontFamilyPicker(selection: $replacement)
                    } label: {
                        LabeledContent("Use instead") {
                            Text(replacement.isEmpty ? "Choose…" : replacement)
                                .foregroundStyle(replacement.isEmpty ? .secondary : .primary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Substitution" : "Add Substitution")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelTapped() }
                        .keyboardShortcut(.cancelAction)   // A-M6: Esc cancels
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmedRequested, trimmedReplacement)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)   // A-M6: Return saves
                }
            }
            // Land the keyboard/VoiceOver cursor in the Requested field (A-M6).
            .onAppear { requestedFocused = true }
        }
        // Block swipe-to-dismiss while there is typed input, and confirm before discarding
        // it (C5e U4).
        .interactiveDismissDisabled(hasUnsavedInput)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}

/// A searchable list of installed font families. Selecting one writes it back and
/// pops the push (S1b).
private struct FontFamilyPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var families: [String] = []
    @State private var search = ""
    #if os(macOS)
    // The arrow-key highlight on the Mac; Return commits it (A-M7).
    @State private var highlighted: String?
    #endif

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [String] {
        guard !trimmedSearch.isEmpty else { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    var body: some View {
        content
            .searchable(text: $search, prompt: "Search fonts")
            .navigationTitle("Replacement Font")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { families = FontFamilyCatalog.installedFamilies() }
    }

    @ViewBuilder
    private var content: some View {
        // When a search matches nothing, show the standard empty-search view rather
        // than a blank list (A-M7).
        if filtered.isEmpty && !trimmedSearch.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            list
        }
    }

    private func pick(_ family: String) {
        selection = family
        dismiss()
    }

    private func rowLabel(_ family: String) -> some View {
        HStack {
            Text(family)
            Spacer(minLength: 8)
            if family == selection {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    #if os(macOS)
    // A selection-driven List so the arrow keys move the highlight and Return picks it
    // (A-M7); a double-click still picks directly.
    private var list: some View {
        List(filtered, id: \.self, selection: $highlighted) { family in
            rowLabel(family)
                .accessibilityAddTraits(family == selection ? [.isSelected] : [])
                .onTapGesture(count: 2) { pick(family) }
        }
        .onKeyPress(.return) {
            if let highlighted { pick(highlighted); return .handled }
            return .ignored
        }
    }
    #else
    private var list: some View {
        List(filtered, id: \.self) { family in
            Button { pick(family) } label: {
                rowLabel(family)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(family == selection ? [.isSelected] : [])
        }
    }
    #endif
}

/// The Settings "Copy Diagnostic Report" row (S1a-6). The Settings window has no
/// toast surface and no open file, so it copies the system-only report (app,
/// system and device) and confirms inline by briefly swapping its label.
private struct DiagnosticReportRow: View {
    @State private var copied = false

    var body: some View {
        #if os(macOS)
        LabeledContent("Diagnostic report") {
            Button(copied ? "Copied" : "Copy") { copy() }
        }
        #else
        Button {
            copy()
        } label: {
            Label(copied ? "Copied" : "Copy Diagnostic Report", systemImage: copied ? "checkmark" : "doc.on.clipboard")
        }
        #endif
    }

    private func copy() {
        DiagnosticClipboard.copy(DiagnosticReportAction.systemReportText())
        copied = true
        AccessibilityAnnouncement.post("Copied")   // A-L5
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

#if os(macOS)

// MARK: - Mac: tabbed Settings window

/// Toolbar-style tabs, each sizing the window to its own content.
private struct MacSettingsTabs: View {
    var body: some View {
        TabView {
            MacGeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            #if EMFY_DMG
            // The Updates group exists only in the GitHub/DMG build (U1).
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            // The MCP-server group also exists only in the GitHub/DMG build (A3a).
            MacMCPTab()
                .tabItem { Label("MCP server", systemImage: "terminal") }
            #endif
            MacViewerTab()
                .tabItem { Label("Viewer", systemImage: "eye") }
            MacRenderingTab()
                .tabItem { Label("Rendering", systemImage: "paintbrush.pointed") }
            MacExportTab()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            MacHelpTab()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
    }
}

/// Fixed pane width so the tabs line up and the window never needs to scroll.
private let macSettingsWidth: CGFloat = 520
/// Bounded height for the Rendering tab, which — unlike the other tabs — can hold a
/// full 64-row font table and grows at large text sizes. A fixed height lets the Form
/// scroll internally so every control stays reachable, rather than the tab growing
/// until the Add button and Quick Look section fall off the bottom of the screen (A-H1).
private let macRenderingTabHeight: CGFloat = 520

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
    @State private var cap = CapReductionController()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MacOptionRow(title: "Recents to keep", value: $settings.recentsToKeep)
                Toggle("Reopen last file at launch", isOn: $settings.reopenLastFileAtLaunch)
                Toggle("Show What’s New after updates", isOn: $settings.showWhatsNewAfterUpdates)
                Toggle("Show drawings in Spotlight", isOn: $settings.showDrawingsInSpotlight)
                Toggle("Keep the opened version for Revert", isOn: $settings.keepOpenedVersionForRevert)
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
            // AI (A1a on-device + A2b providers) — hidden where no engine is available.
            AISettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Lowering the cap applies at once; one that would delete a received copy
        // confirms first (S1a-5).
        .onChange(of: settings.recentsToKeep) { old, new in
            cap.handleChange(from: old, to: new, store: store)
        }
        // Private mode toggled here reaches the store even with no library window open
        // (the Mac Settings scene is separate — S1a-5 review).
        .onChange(of: settings.privateMode) { _, on in
            store.setPrivate(on)
        }
        // The Spotlight toggle reaches the index even with no library window open (F3d).
        .onChange(of: settings.showDrawingsInSpotlight) { _, _ in
            SpotlightService.shared.settingsChanged()
        }
        .capReduction(cap, store: store, settings: settings)
    }
}

private struct MacViewerTab: View {
    @Environment(EmfySettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MacOptionRow(title: "Default zoom on open", value: $settings.defaultZoomOnOpen, segmented: true)
                MacOptionRow(title: "Page background", value: $settings.pageBackground)
                // The Mac retired its partial-support banner (0964d74); partial
                // support shows in the Info inspector, so there is no toggle here.
                // The toggle stays on iOS, where the banner still shows.
                Toggle("Recognise text in pictures", isOn: $settings.recognizeTextInPictures)
            } header: {
                Text("Viewer")
            } footer: {
                Text(SettingsFooter.recognizeTextInPictures)
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

/// The Rendering tab (S1b): edges, EMF+-dual arbitration, the WMF embedded-EMF
/// toggle, and the font substitution table. The first three use the same
/// `MacOptionRow` / `Toggle` pattern as the other tabs; the table lists
/// "requested → replacement" rows with a trailing − to delete and an Add sheet.
private struct MacRenderingTab: View {
    @Environment(EmfySettings.self) private var settings
    @State private var draft: FontSubstitutionDraft?

    private var atCap: Bool { settings.fontSubstitutions.count >= EmfySettings.fontSubstitutionRowLimit }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MacOptionRow(title: "Edges", value: $settings.renderEdges, segmented: true)
            } footer: {
                Text(RenderingFooter.edges)
            }
            Section {
                MacOptionRow(title: "EMF+ files with a GDI copy", value: $settings.emfPlusSource, segmented: true)
            } footer: {
                Text(RenderingFooter.emfPlus)
            }
            Section {
                Toggle("WMF files: use built-in EMF copy", isOn: $settings.useEmbeddedEMF)
            } footer: {
                Text(RenderingFooter.wmf)
            }
            Section {
                if settings.fontSubstitutions.isEmpty {
                    Text(RenderingFooter.emptyFonts)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.fontSubstitutions) { entry in
                        HStack {
                            Button {
                                draft = FontSubstitutionDraft(editingID: entry.id, requested: entry.requested, replacement: entry.replacement)
                            } label: {
                                SubstitutionRowLabel(entry: entry)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Edits this substitution")   // A-L3
                            Button(role: .destructive) {
                                delete(entry.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            // Name the row the button deletes, so VoiceOver isn't 64
                            // identical "Delete substitution" buttons (A-M1).
                            .accessibilityLabel("Delete substitution for \(entry.requested.isEmpty ? "unnamed font" : entry.requested)")
                        }
                    }
                }
                Button {
                    draft = FontSubstitutionDraft()
                } label: {
                    Label("Add Substitution…", systemImage: "plus")
                }
                .disabled(atCap)
                // Say why Add is unavailable at the cap (A-L4).
                .accessibilityHint(atCap ? "Limit of \(EmfySettings.fontSubstitutionRowLimit) reached" : "")
            } header: {
                Text("Font substitutions")
            } footer: {
                Text(atCap ? RenderingFooter.fontCap : RenderingFooter.fonts)
            }
            Section {
                MacOptionRow(title: "Thumbnail background", value: $settings.thumbnailBackground, segmented: true)
                MacOptionRow(title: "Preview sharpness", value: $settings.previewSharpness, segmented: true)
            } header: {
                Text("Quick Look")
            } footer: {
                Text(RenderingFooter.quickLook)
            }
        }
        .formStyle(.grouped)
        // A bounded height (not intrinsic) so the Form scrolls when a full font table
        // or large text would otherwise push controls off-screen (A-H1).
        .frame(width: macSettingsWidth, height: macRenderingTabHeight)
        .sheet(item: $draft) { draft in
            FontSubstitutionEditorSheet(draft: draft) { requested, replacement in
                apply(draft, requested: requested, replacement: replacement)
            }
        }
    }

    private func delete(_ id: FontSubstitutionEntry.ID) {
        settings.fontSubstitutions.removeAll { $0.id == id }
    }

    private func apply(_ draft: FontSubstitutionDraft, requested: String, replacement: String) {
        var table = settings.fontSubstitutions
        if let id = draft.editingID, let index = table.firstIndex(where: { $0.id == id }) {
            table[index].requested = requested
            table[index].replacement = replacement
        } else {
            table.append(FontSubstitutionEntry(requested: requested, replacement: replacement))
        }
        settings.fontSubstitutions = table
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
                LabeledContent("Contact Support") {
                    Button("Email") { if let url = EmfyLinks.contact { openURL(url) } }
                }
            }
            Section {
                DiagnosticReportRow()
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(SettingsFooter.macDiagnostics)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if EMFY_DMG
/// The MCP-server group (GitHub/DMG build only, A3a). A single opt-in toggle,
/// default OFF, that lets an AI app read drawings through Emfy's local, read-only
/// MCP server, plus a button that copies the client configuration snippet. The
/// helper refuses to serve tool calls until this is on.
private struct MacMCPTab: View {
    @Environment(EmfySettings.self) private var settings
    @State private var copied = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Allow AI apps to read drawings through Emfy’s MCP server", isOn: $settings.mcpServerEnabled)
                LabeledContent("Client configuration") {
                    Button(copied ? "Copied" : "Copy") { copyConfiguration() }
                }
            } header: {
                Text("MCP server")
            } footer: {
                Text(MCPSettingsFooter.explanation)
            }
        }
        .formStyle(.grouped)
        .frame(width: macSettingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyConfiguration() {
        let path = MCPClientConfiguration.helperPath(appBundleURL: Bundle.main.bundleURL)
        let json = MCPClientConfiguration.configJSON(helperPath: path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copied = true
        AccessibilityAnnouncement.post("Copied")
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The MCP group's single read-only explanation sentence.
private enum MCPSettingsFooter {
    static let explanation = "Emfy’s MCP server is a local, read-only helper that lets an AI app you configure read a drawing’s text, records and rendered image through Emfy. It never changes files and never uses the network. It stays off until you turn it on."
}
#endif

#else

// MARK: - iOS/iPadOS: sectioned Settings form

/// A system picker row; in a Form it renders as a navigation/menu row that reads
/// its label and value to VoiceOver.
private struct IOSOptionRow<E: SettingsOption>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    @Binding var value: E

    var body: some View {
        let picker = Picker(title, selection: $value) {
            ForEach(Array(E.allCases), id: \.self) { Text($0.label).tag($0) }
        }
        // At accessibility text sizes the inline menu row breaks the label mid-word
        // and collapses the value to "…"; the navigation-link style stacks the whole
        // label above the value instead. Default sizes keep the automatic inline style
        // unchanged (a secondary-grey value, not the tinted menu style).
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.navigationLink)
        } else {
            picker
        }
    }
}

private struct IOSSettingsForm: View {
    @Environment(RecentsStore.self) private var store
    @Environment(EmfySettings.self) private var settings
    @Environment(\.openURL) private var openURL
    // iPad supports multiple windows; iPhone does not. Used to show the iPhone-only
    // "Full editor on iPhone" toggle on iPhone (including iPhone Duo) and hide it on
    // iPad, matching the per-platform hide pattern already used in More Viewer Options.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    // The Settings sheet hosts its own removal flow (the window-level one is
    // covered by this sheet — C4a H3). Clear confirms and offers Save a Copy.
    @State private var removal = RemovalCoordinator()
    @State private var cap = CapReductionController()

    var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
        Form {
            Section {
                IOSOptionRow(title: "Default zoom on open", value: $settings.defaultZoomOnOpen)
                IOSOptionRow(title: "Page background", value: $settings.pageBackground)
                Toggle("Show partial support banner", isOn: $settings.showPartialSupportBanner)
                Toggle("Recognise text in pictures", isOn: $settings.recognizeTextInPictures)
                NavigationLink("More Viewer Options") { IOSMoreViewerOptions() }
                NavigationLink("Rendering") { IOSRenderingScreen() }
            } header: {
                Text("Viewer")
            } footer: {
                Text(SettingsFooter.recognizeTextInPictures)
            }
            Section {
                IOSOptionRow(title: "Recents to keep", value: $settings.recentsToKeep)
                Toggle("Reopen last file at launch", isOn: $settings.reopenLastFileAtLaunch)
                Toggle("Show What’s New after updates", isOn: $settings.showWhatsNewAfterUpdates)
                Toggle("Show drawings in Spotlight", isOn: $settings.showDrawingsInSpotlight)
                Toggle("Keep the opened version for Revert", isOn: $settings.keepOpenedVersionForRevert)
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
            // The full-editor toggle (E4). iPhone only — hidden on iPad, where the full
            // editor is always on, and absent from the Mac Settings window entirely.
            if !supportsMultipleWindows {
                Section {
                    Toggle("Full editor on iPhone", isOn: $settings.fullEditorOnIPhone)
                } header: {
                    Text("Editing")
                } footer: {
                    Text(SettingsFooter.fullEditorOnIPhone)
                }
                .id("settings.editing")
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
            // AI (A1a on-device + A2b providers) — hidden where no engine is available.
            AISettingsSection()
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
                    Label("Contact Support", systemImage: "envelope")
                }
                NavigationLink {
                    AboutContent()
                        .navigationTitle("About Emfy")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("About Emfy", systemImage: "info.circle")
                }
                DiagnosticReportRow()
            } header: {
                Text("Help & diagnostics")
            } footer: {
                Text(SettingsFooter.iOSDiagnostics)
            }
        }
        .recentsRemoval(removal, store: store, toast: nil)
        // Lowering the cap applies at once; one that would delete a received copy
        // confirms first (S1a-5).
        .onChange(of: settings.recentsToKeep) { old, new in
            cap.handleChange(from: old, to: new, store: store)
        }
        // Private mode toggled in More Library Options reaches the store directly.
        .onChange(of: settings.privateMode) { _, on in
            store.setPrivate(on)
        }
        // The Spotlight toggle wipes or re-syncs the index (F3d).
        .onChange(of: settings.showDrawingsInSpotlight) { _, _ in
            SpotlightService.shared.settingsChanged()
        }
        .capReduction(cap, store: store, settings: settings)
        #if DEBUG
        // The `iphone-settings` screenshot script scrolls to the Editing section so the
        // capture shows the Full-editor toggle and its footer (E4 verification d).
        .onAppear {
            guard EditorDebugLaunch.script == "iphone-settings", !supportsMultipleWindows else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation { proxy.scrollTo("settings.editing", anchor: .center) }
            }
        }
        #endif
        }
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

/// The Rendering screen (S1b): edges, EMF+-dual arbitration, the WMF embedded-EMF
/// toggle, and the font substitution table (swipe to delete, tap to edit, an Add
/// sheet). Reached from a row in the main Settings form.
private struct IOSRenderingScreen: View {
    @Environment(EmfySettings.self) private var settings
    @State private var draft: FontSubstitutionDraft?

    private var atCap: Bool { settings.fontSubstitutions.count >= EmfySettings.fontSubstitutionRowLimit }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                IOSOptionRow(title: "Edges", value: $settings.renderEdges)
            } footer: {
                Text(RenderingFooter.edges)
            }
            Section {
                IOSOptionRow(title: "EMF+ files with a GDI copy", value: $settings.emfPlusSource)
            } footer: {
                Text(RenderingFooter.emfPlus)
            }
            Section {
                Toggle("WMF files: use built-in EMF copy", isOn: $settings.useEmbeddedEMF)
            } footer: {
                Text(RenderingFooter.wmf)
            }
            Section {
                if settings.fontSubstitutions.isEmpty {
                    Text(RenderingFooter.emptyFonts)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.fontSubstitutions) { entry in
                        Button {
                            draft = FontSubstitutionDraft(editingID: entry.id, requested: entry.requested, replacement: entry.replacement)
                        } label: {
                            SubstitutionRowLabel(entry: entry)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edits this substitution")   // A-L3
                    }
                    .onDelete { offsets in
                        settings.fontSubstitutions.remove(atOffsets: offsets)
                    }
                }
                Button {
                    draft = FontSubstitutionDraft()
                } label: {
                    Label("Add Substitution", systemImage: "plus")
                }
                .disabled(atCap)
                // Say why Add is unavailable at the cap (A-L4).
                .accessibilityHint(atCap ? "Limit of \(EmfySettings.fontSubstitutionRowLimit) reached" : "")
            } header: {
                Text("Font substitutions")
            } footer: {
                Text(atCap ? RenderingFooter.fontCap : RenderingFooter.fonts)
            }
            Section {
                IOSOptionRow(title: "Thumbnail background", value: $settings.thumbnailBackground)
                IOSOptionRow(title: "Preview sharpness", value: $settings.previewSharpness)
            } header: {
                Text("Quick Look")
            } footer: {
                Text(RenderingFooter.quickLook)
            }
        }
        .navigationTitle("Rendering")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { draft in
            FontSubstitutionEditorSheet(draft: draft) { requested, replacement in
                apply(draft, requested: requested, replacement: replacement)
            }
        }
    }

    private func apply(_ draft: FontSubstitutionDraft, requested: String, replacement: String) {
        var table = settings.fontSubstitutions
        if let id = draft.editingID, let index = table.firstIndex(where: { $0.id == id }) {
            table[index].requested = requested
            table[index].replacement = replacement
        } else {
            table.append(FontSubstitutionEntry(requested: requested, replacement: replacement))
        }
        settings.fontSubstitutions = table
    }
}

#endif

#if DEBUG && os(macOS)
/// F3c screenshot (f): hosts the Mac Viewer settings tab (which carries the "Recognise text
/// in pictures" toggle) in an offscreen window and captures it via `cacheDisplay`, so the
/// toggle can be shot in-process with no Screen Recording permission. Called from a `.task`
/// on the library window, so nothing is added to its already-large view body.
enum SettingsSceneScreenshot {
    @MainActor
    @discardableResult
    static func captureViewerTab(settings: EmfySettings, to path: String) -> Bool {
        return capture(view: MacViewerTab().environment(settings).padding(.vertical, 8), to: path)
    }

    /// F3d screenshot (i): hosts the Mac General settings tab (which carries the "Show
    /// drawings in Spotlight" toggle) in an offscreen window and captures it, so the toggle
    /// can be shot in-process with no Screen Recording permission.
    @MainActor
    @discardableResult
    static func captureGeneralTab(store: RecentsStore, settings: EmfySettings, to path: String) -> Bool {
        capture(view: MacGeneralTab().environment(store).environment(settings).padding(.vertical, 8), to: path)
    }

    /// C5a screenshot: renders the What's New release notes (`Changelog.latest`) to a PNG
    /// with `ImageRenderer`, so the copy can be shot in-process with no Screen Recording
    /// permission. It mirrors `WhatsNewView` — the same icon, title and `ChangeBullet`
    /// rows, fed by the same `Changelog.latest` — but lays the bullets out in a plain
    /// (non-scrolling) stack at natural height, because `ImageRenderer` does not draw a
    /// `ScrollView`'s lazily laid-out content. The authoritative sheet capture is the iOS
    /// one; this verifies the Mac copy renders and reads.
    @MainActor
    @discardableResult
    static func captureWhatsNew(to path: String) -> Bool {
        let entry = Changelog.latest
        let content = VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("What's New in Emfy \(entry.version)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entry.changes, id: \.self) { ChangeBullet(text: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    #if EMFY_DMG
    /// A3a screenshot: hosts the GitHub/DMG-only MCP-server settings group offscreen
    /// and captures it in-process (no Screen Recording permission needed).
    @MainActor
    @discardableResult
    static func captureMCPTab(settings: EmfySettings, to path: String) -> Bool {
        capture(view: MacMCPTab().environment(settings).padding(.vertical, 8), to: path)
    }
    #endif

    @MainActor
    private static func capture<V: View>(view: V, to path: String, size: NSSize = NSSize(width: 520, height: 520)) -> Bool {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let view = window.contentView else { return false }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif
