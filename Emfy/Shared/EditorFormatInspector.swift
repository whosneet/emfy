import CoreGraphics
import EMFEdit
import SwiftUI

// The Format inspector UI (E2c, design calls 1–3), modelled on Keynote/Pages/Freeform.
// In edit mode with a selection it replaces Info with a Format panel (a segmented
// Format | Info control switches between them). Every section reads its value from
// `FormatInspectorModel` and emits one `SceneCommand` per edit through
// `DocumentSession.apply`, coalescing a continuous drag/scrub into a single undo.
//
// Kept in Shared (it imports EMFEdit) so the EMFEdit-free Mac pane can host it by
// name without importing EMFEdit itself.

/// Which panel the inspector shows while a selection exists.
enum InspectorTab: Hashable { case format, info }

/// The inspector shown in edit mode with a selection: a Format | Info segmented
/// control over either the Format sections or the caller's Info view (design call 1).
struct EditorInspectorPanel<Info: View>: View {
    let session: DocumentSession
    let editorModel: EditorModel
    let onClose: () -> Void
    @ViewBuilder let info: () -> Info

    @State private var tab: InspectorTab = .format

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Format").tag(InspectorTab.format)
                    Text("Info").tag(InspectorTab.info)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if tab == .format {
                FormatSections(session: session, editorModel: editorModel)
            } else {
                info()
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close inspector")
    }
}

/// The Format sections (Fill, Stroke, Opacity, Text) for the current selection. Only
/// the sections relevant to the selection appear; a mixed selection shows an
/// indeterminate state and applying sets the value on every supporting element
/// (design call 2).
struct FormatSections: View {
    let session: DocumentSession
    let editorModel: EditorModel

    // One gesture counter per continuous control, bumped when a drag/scrub ends so the
    // next interaction is a new undo entry; during a drag the key is constant, so the
    // run coalesces to one entry (design call 3).
    @State private var opacityGesture = 0
    @State private var strokeWidthGesture = 0
    // Live, editable values so a slider/field tracks the pointer without waiting for
    // the model to round-trip through the scene.
    @State private var liveOpacity: Double = 1
    @State private var liveStrokeWidth: Double = 1

    private var model: FormatInspectorModel {
        guard session.editing == .editing, let scene = session.editingScene else {
            return FormatInspectorModel(selected: [])
        }
        let ids = editorModel.selection.ids
        return FormatInspectorModel(selected: scene.elements.filter { ids.contains($0.id) })
    }

    var body: some View {
        // Observe edits and selection so the panel re-derives (editVersion covers scene
        // mutations; selection drives which elements are shown).
        let _ = session.editVersion
        let model = self.model
        ScrollViewReader { proxy in
            Form {
                if model.isEmpty {
                    Section { Text("No Selection").foregroundStyle(.secondary) }
                } else {
                    fillSection(model)
                    strokeSection(model)
                    opacitySection(model)
                    if let text = model.text {
                        TextSection(session: session, text: text, transform: transform(of: text.id))
                            .id("format.text")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .onAppear {
                syncLiveValues(model)
                #if DEBUG
                if EditorDebugLaunch.scrollInspectorToText, model.text != nil {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo("format.text", anchor: .top)
                    }
                }
                #endif
            }
            .onChange(of: editorModel.selection) { _, _ in syncLiveValues(self.model) }
        }
    }

    private func transform(of id: Int) -> CGAffineTransform {
        session.editingScene?.elements.first { $0.id == id }?.transform ?? .identity
    }

    /// Pulls the live slider/field values from the model when the selection changes, so
    /// they start from the shown value.
    private func syncLiveValues(_ model: FormatInspectorModel) {
        if case .uniform(let value) = model.opacity { liveOpacity = value } else { liveOpacity = 1 }
        if case .uniform(_, let width, _, _) = model.stroke { liveStrokeWidth = width } else { liveStrokeWidth = 1 }
    }

    // MARK: Fill

    @ViewBuilder
    private func fillSection(_ model: FormatInspectorModel) -> some View {
        Section("Fill") {
            switch model.fill {
            case .gradient:
                LabeledContent("Fill", value: "Gradient")
                Button("Replace with Colour") { applyFill(.black, model: model) }
                noFillButton(model)
            case .mixed:
                LabeledContent("Fill", value: "Mixed")
                ColorPicker("Colour", selection: fillColorBinding(model, current: .gray), supportsOpacity: true)
                noFillButton(model)
            case .none:
                LabeledContent("Fill", value: "None")
                ColorPicker("Colour", selection: fillColorBinding(model, current: .black), supportsOpacity: true)
            case .color(let colour):
                ColorPicker("Colour", selection: fillColorBinding(model, current: Color(colour)), supportsOpacity: true)
                noFillButton(model)
            }
        }
    }

    /// The Fill ▸ None action: clears the fill of every selected element.
    private func noFillButton(_ model: FormatInspectorModel) -> some View {
        Button("No Fill", role: .destructive) {
            session.apply(model.clearFillCommand())
        }
    }

    private func fillColorBinding(_ model: FormatInspectorModel, current: Color) -> Binding<Color> {
        Binding(
            get: { current },
            set: { applyFill($0, model: model) }
        )
    }

    /// Applies a picked colour: the RGB becomes an opaque fill, and the picked alpha is
    /// honoured as the element opacity (design call 2), both in one coalesced undo.
    private func applyFill(_ colour: Color, model: FormatInspectorModel) {
        let rgba = colour.rgbaComponents
        // Both sub-commands share one coalescing key, so a ColorPicker scrub (colour +
        // the alpha→opacity it drives) collapses to a single undo entry (design call 3).
        let key = SceneCoalescingKey("fill")
        session.apply(model.fillColorCommand(SceneColor(red: rgba.red, green: rgba.green, blue: rgba.blue), evenOdd: false), coalescing: key)
        session.apply(model.opacityCommand(rgba.alpha), coalescing: key)
        liveOpacity = rgba.alpha
    }

    // MARK: Stroke

    @ViewBuilder
    private func strokeSection(_ model: FormatInspectorModel) -> some View {
        Section("Stroke") {
            switch model.stroke {
            case .none:
                LabeledContent("Stroke", value: "None")
                Button("Add Stroke") {
                    session.apply(model.strokeCommand(color: SceneColor(red: 0, green: 0, blue: 0), width: max(1, liveStrokeWidth)))
                }
            case .mixed:
                LabeledContent("Stroke", value: "Mixed")
                strokeEditors(model, colour: .gray)
            case .uniform(let colour, _, _, let dash):
                strokeEditors(model, colour: Color(colour))
                if dash != .solid {
                    LabeledContent("Dash", value: dashLabel(dash))
                }
                Button("Remove Stroke", role: .destructive) { session.apply(model.clearStrokeCommand()) }
            }
        }
    }

    @ViewBuilder
    private func strokeEditors(_ model: FormatInspectorModel, colour: Color) -> some View {
        ColorPicker("Colour", selection: Binding(
            get: { colour },
            set: { picked in
                let rgba = picked.rgbaComponents
                session.apply(model.strokeCommand(color: SceneColor(red: rgba.red, green: rgba.green, blue: rgba.blue), width: liveStrokeWidth), coalescing: SceneCoalescingKey("stroke-color"))
            }
        ), supportsOpacity: false)

        HStack {
            Text("Width")
            Spacer()
            TextField("Width", value: Binding(
                get: { liveStrokeWidth },
                set: { liveStrokeWidth = max(0, $0); applyStrokeWidth(model) }
            ), format: .number)
            .labelsHidden()
            .frame(width: 60)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .multilineTextAlignment(.trailing)
            Stepper("Width", value: Binding(
                get: { liveStrokeWidth },
                set: { liveStrokeWidth = max(0, $0); applyStrokeWidth(model) }
            ), in: 0...200, step: 0.5, onEditingChanged: { if !$0 { strokeWidthGesture += 1 } })
            .labelsHidden()
        }
    }

    private func applyStrokeWidth(_ model: FormatInspectorModel) {
        let colour: SceneColor
        if case .uniform(let c, _, _, _) = model.stroke { colour = c } else { colour = SceneColor(red: 0, green: 0, blue: 0) }
        session.apply(model.strokeCommand(color: colour, width: liveStrokeWidth), coalescing: SceneCoalescingKey("stroke-width-\(strokeWidthGesture)"))
    }

    private func dashLabel(_ dash: SceneStroke.Dash) -> String {
        switch dash {
        case .solid: return "Solid"
        case .dash: return "Dashed"
        case .dot: return "Dotted"
        case .dashDot: return "Dash-dot"
        case .dashDotDot: return "Dash-dot-dot"
        case .userStyle: return "Custom"
        }
    }

    // MARK: Opacity

    @ViewBuilder
    private func opacitySection(_ model: FormatInspectorModel) -> some View {
        Section("Opacity") {
            HStack {
                Slider(value: Binding(
                    get: { liveOpacity },
                    set: { liveOpacity = $0; session.apply(model.opacityCommand($0), coalescing: SceneCoalescingKey("opacity-\(opacityGesture)")) }
                ), in: 0...1, onEditingChanged: { if !$0 { opacityGesture += 1 } })
                Text("\(Int((liveOpacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            if case .mixed = model.opacity {
                Text("Mixed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Colour bridging

extension Color {
    /// The sRGB components of a SwiftUI `Color`, 0…1, via the platform colour type.
    var rgbaComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        #if os(macOS)
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return (Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent), Double(converted.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }

    /// A SwiftUI `Color` from a scene colour (sRGB, alpha honoured).
    init(_ colour: SceneColor) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue, opacity: colour.alpha)
    }
}
