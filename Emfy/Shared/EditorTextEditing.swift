import CoreGraphics
import EMFEdit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The Format inspector's Text section and the double-click/tap text-edit popover
// (E2c, design call 2 Text + call 5). Kept with the other EMFEdit-importing editor UI
// so the Mac pane stays EMFEdit-free. Both the inspector's content field and the
// popover emit one `setText`; the font controls emit one `setFont`, with the point
// size converted to the run's logical height (`FontSizeConversion`).

/// The Text section (iOS): content, font family, size (pt), Bold and Italic wrapped in
/// a Form `Section`. The macOS Format panel hosts `TextSectionRows` directly in its
/// own card instead (see `FormatSections`). Shown only when the selection is exactly
/// one text element.
struct TextSection: View {
    let session: DocumentSession
    let text: InspectorText
    /// The element transform, for the point-size ⇄ logical-height conversion.
    let transform: CGAffineTransform

    var body: some View {
        Section("Text") {
            TextSectionRows(session: session, text: text, transform: transform)
        }
    }
}

/// The Text section's controls, without a `Section` wrapper so the macOS Format panel
/// can place them in its hand-built card (see `FormatSections`).
struct TextSectionRows: View {
    let session: DocumentSession
    let text: InspectorText
    /// The element transform, for the point-size ⇄ logical-height conversion.
    let transform: CGAffineTransform

    @State private var liveContent: String = ""
    @State private var liveSize: Double = 12

    var body: some View {
        Group {
            TextField("Text", text: $liveContent, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit { commitText() }

            FontFamilyField(family: text.family) { picked in
                apply(family: picked)
            }

            HStack {
                Text("Size")
                Spacer()
                TextField("Size", value: Binding(
                    get: { liveSize },
                    set: { liveSize = max(1, $0); applyFont() }
                ), format: .number)
                .labelsHidden()
                .frame(width: 56)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .multilineTextAlignment(.trailing)
                Stepper("Size", value: Binding(
                    get: { liveSize },
                    set: { liveSize = max(1, $0); applyFont() }
                ), in: 1...1000, step: 1)
                .labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { text.bold }, set: { _ in toggleBold() })) {
                    Image(systemName: "bold")
                }
                Toggle(isOn: Binding(get: { text.italic }, set: { _ in toggleItalic() })) {
                    Image(systemName: "italic")
                }
            }
            .toggleStyle(.button)
        }
        .onAppear { liveContent = text.content; liveSize = Double(text.pointSize) }
        .onChange(of: text.id) { _, _ in liveContent = text.content; liveSize = Double(text.pointSize) }
        .onChange(of: text.content) { _, new in if new != liveContent { liveContent = new } }
        .onChange(of: text.pointSize) { _, new in liveSize = Double(new) }
    }

    private func commitText() {
        session.apply(.setText(id: text.id, TextSanitizer.sanitize(liveContent)))
    }

    private func apply(family: String) {
        session.apply(FontSizeConversion.fontCommand(id: text.id, family: family, points: liveSize, transform: transform, bold: text.bold, italic: text.italic))
    }

    private func applyFont() {
        session.apply(FontSizeConversion.fontCommand(id: text.id, family: text.family, points: liveSize, transform: transform, bold: text.bold, italic: text.italic))
    }

    private func toggleBold() {
        session.apply(FontSizeConversion.fontCommand(id: text.id, family: text.family, points: liveSize, transform: transform, bold: !text.bold, italic: text.italic))
    }

    private func toggleItalic() {
        session.apply(FontSizeConversion.fontCommand(id: text.id, family: text.family, points: liveSize, transform: transform, bold: text.bold, italic: !text.italic))
    }
}

/// A searchable font-family picker: shows the current family and opens a searchable
/// list of installed families (design call 2 Text).
struct FontFamilyField: View {
    let family: String
    let onSelect: (String) -> Void

    @State private var presented = false
    @State private var query = ""

    var body: some View {
        Button {
            presented = true
        } label: {
            LabeledContent("Font") {
                HStack(spacing: 4) {
                    Text(family).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented) {
            NavigationStack {
                List(filteredFamilies, id: \.self) { name in
                    Button {
                        onSelect(name)
                        presented = false
                    } label: {
                        HStack {
                            Text(name).font(.custom(name, size: 15))
                            Spacer()
                            if name == family { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $query, placement: .automatic, prompt: "Fonts")
                .overlay {
                    if filteredFamilies.isEmpty {
                        ContentUnavailableView.search(text: query)   // C5e U5
                    }
                }
                .navigationTitle("Font")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .frame(minWidth: 260, minHeight: 320)
        }
    }

    private var filteredFamilies: [String] {
        let all = InstalledFonts.families
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The installed font families on this platform.
enum InstalledFonts {
    static var families: [String] {
        #if os(macOS)
        return NSFontManager.shared.availableFontFamilies.sorted()
        #else
        return UIFont.familyNames.sorted()
        #endif
    }
}

// MARK: - Double-click / tap text popover (design call 5)

/// The popover shown when a text element is double-clicked (Mac) or double-tapped
/// (iPad): a text field that commits ONE `setText` on Return or click-away and cancels
/// on Esc. User text is sanitised before it becomes a command (§8).
struct TextEditPopover: View {
    let request: TextEditRequest
    /// Commits the (sanitised) text as one `setText`.
    let onCommit: (String) -> Void
    /// Dismisses without changing the run.
    let onCancel: () -> Void
    /// Closes the popover (clears the request).
    let onClose: () -> Void

    @State private var text: String
    @State private var resolved = false
    @FocusState private var focused: Bool

    init(request: TextEditRequest, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.request = request
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onClose = onClose
        _text = State(initialValue: request.initialText)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .focused($focused)
                .onSubmit { resolve(commit: true) }
                .onKeyPress(.escape) { resolve(commit: false); return .handled }
            HStack {
                Button("Cancel") { resolve(commit: false) }
                Spacer()
                Button("Done") { resolve(commit: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { focused = true }
        // Click-away (dismiss without Done/Cancel) commits, per design call 5.
        .onDisappear { if !resolved { onCommit(TextSanitizer.sanitize(text)) } }
    }

    private func resolve(commit: Bool) {
        guard !resolved else { return }
        resolved = true
        if commit { onCommit(TextSanitizer.sanitize(text)) } else { onCancel() }
        onClose()
    }
}
