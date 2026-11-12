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

/// Which panel the inspector shows in edit mode (design call 1; Layers added E3d).
enum InspectorTab: Hashable { case format, layers, info }

/// The inspector shown in edit mode: a Format | Layers | Info segmented control over the
/// Format sections, the Layers panel, or the caller's Info view (design call 1; E3d).
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
                    Text("Layers").tag(InspectorTab.layers)
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

            switch tab {
            case .format: FormatSections(session: session, editorModel: editorModel)
            case .layers: LayersSection(session: session, editorModel: editorModel)
            case .info: info()
            }
        }
        .onAppear {
            #if DEBUG
            if EditorDebugLaunch.forceLayersTab { tab = .layers }
            #endif
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
            sections(model)
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

    #if os(macOS)
    // On macOS the Format panel lives in the window's inspector column, whose hosting
    // view renders in the VibrantDark appearance. SwiftUI's `.formStyle(.grouped)`
    // section cards resolve OPAQUE WHITE there in Dark Mode (the hosting view is
    // correctly dark, but the grouped card background does not follow it, and neither
    // `.listRowBackground` nor `.scrollContentBackground(.hidden)` overrides it). So
    // the panel is laid out by hand with explicit semantic backgrounds, which DO follow
    // the window's appearance — no hard-coded light/dark colours. iOS keeps the Form.
    @ViewBuilder
    private func sections(_ model: FormatInspectorModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isEmpty {
                    Text("No Selection").foregroundStyle(.secondary)
                } else {
                    card("Fill") { fillRows(model) }
                    card("Stroke") { strokeRows(model) }
                    card("Opacity") { opacityRows(model) }
                    if let text = model.text {
                        card("Text") {
                            TextSectionRows(session: session, text: text, transform: transform(of: text.id))
                        }
                        .id("format.text")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One titled section card: an uppercase caption header over a rounded container
    /// filled with `.controlBackgroundColor`, a semantic colour that follows the
    /// window's appearance (dark in Dark Mode, light in Light).
    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color(nsColor: .labelColor))
                .buttonStyle(.link)
        }
    }
    #else
    @ViewBuilder
    private func sections(_ model: FormatInspectorModel) -> some View {
        Form {
            if model.isEmpty {
                Section { Text("No Selection").foregroundStyle(.secondary) }
            } else {
                Section("Fill") { fillRows(model) }
                Section("Stroke") { strokeRows(model) }
                Section("Opacity") { opacityRows(model) }
                if let text = model.text {
                    TextSection(session: session, text: text, transform: transform(of: text.id))
                        .id("format.text")
                }
            }
        }
    }
    #endif

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
    private func fillRows(_ model: FormatInspectorModel) -> some View {
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
    private func strokeRows(_ model: FormatInspectorModel) -> some View {
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
    private func opacityRows(_ model: FormatInspectorModel) -> some View {
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

// MARK: - Layers panel (E3d)

/// The Layers panel: the scene's layers top-first, each with an eye/lock toggle, its name
/// and element count; selecting a row makes it active, "+"/"−" add above / delete the
/// active layer, drag reorders, and a footnote reminds that hidden layers still draw in
/// other apps (design §2–3). One `SceneCommand` per edit through `DocumentSession.apply`.
struct LayersSection: View {
    let session: DocumentSession
    let editorModel: EditorModel

    @State private var editingLayerID: Int?
    @State private var editingName: String = ""
    @State private var pendingDelete: PendingLayerDelete?

    /// A non-empty layer the "−" button is asking to delete.
    private struct PendingLayerDelete: Identifiable {
        let id: Int
        let name: String
        let count: Int
    }

    private var scene: EMFEdit.Scene? {
        guard session.editing == .editing else { return nil }
        return session.editingScene
    }

    var body: some View {
        // Re-derive on every scene edit (editVersion) so a hide/lock/rename/reorder shows.
        let _ = session.editVersion
        if let scene {
            let activeID = editorModel.resolvedActiveLayerID(in: scene)
            VStack(spacing: 0) {
                header(scene: scene)
                Divider()
                List {
                    // Top layer first (the back-to-front array reversed).
                    ForEach(scene.layers.reversed()) { layer in
                        row(layer, activeID: activeID)
                    }
                    .onMove { move(from: $0, to: $1, scene: scene) }
                }
                #if os(macOS)
                .listStyle(.inset)
                #else
                .listStyle(.plain)
                #endif
                .scrollContentBackground(.hidden)
                if scene.layers.contains(where: \.hidden) {
                    Text("Hidden layers still appear in other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            .confirmationDialog(
                pendingDelete.map { LayerDeletion.confirmationMessage(name: $0.name, elementCount: $0.count) } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let pending = pendingDelete {
                    Button("Delete Layer", role: .destructive) {
                        session.apply(.deleteLayer(id: pending.id))
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                }
            }
        } else {
            Text("No Layers").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header (+ / −)

    @ViewBuilder
    private func header(scene: EMFEdit.Scene) -> some View {
        HStack(spacing: 10) {
            Text("Layers").font(.headline)
            Spacer()
            Button { addLayer(scene: scene) } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Layer")
            Button { deleteActiveLayer(scene: scene) } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel("Delete Layer")
            .disabled(scene.layers.count <= 1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ layer: EMFEdit.Layer, activeID: Int?) -> some View {
        let isActive = layer.id == activeID
        HStack(spacing: 8) {
            Button { session.apply(.setLayerHidden(id: layer.id, !layer.hidden)) } label: {
                Image(systemName: layer.hidden ? "eye.slash" : "eye")
                    .foregroundStyle(layer.hidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(layer.hidden ? "Show Layer" : "Hide Layer")

            Button { session.apply(.setLayerLocked(id: layer.id, !layer.locked)) } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(layer.locked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(layer.locked ? "Unlock Layer" : "Lock Layer")

            if editingLayerID == layer.id {
                TextField("Layer name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename() }
                    #if os(macOS)
                    .onExitCommand { editingLayerID = nil }
                    #endif
            } else {
                Text(layer.name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 6)
            Text("\(layer.elements.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        #if os(macOS)
        .onTapGesture(count: 2) { beginRename(layer) }
        #endif
        .onTapGesture { editorModel.activeLayerID = layer.id }
        .contextMenu {
            Button("Rename") { beginRename(layer) }
        }
    }

    // MARK: Actions

    private func beginRename(_ layer: EMFEdit.Layer) {
        editingName = layer.name
        editingLayerID = layer.id
        editorModel.activeLayerID = layer.id
    }

    private func commitRename() {
        defer { editingLayerID = nil }
        guard let id = editingLayerID, let name = LayerName.sanitised(editingName) else { return }
        session.apply(.renameLayer(id: id, name))
    }

    /// Adds a new "Layer N" directly above the active layer and makes it active (design §3).
    private func addLayer(scene: EMFEdit.Scene) {
        let activeID = editorModel.resolvedActiveLayerID(in: scene)
        let order = activeID.flatMap { scene.layerOrder(ofLayer: $0) }.map { $0 + 1 } ?? scene.layers.count
        let name = LayerName.nextDefault(existing: scene.layers.map(\.name))
        let newID = scene.nextLayerID
        session.apply(.addLayer(name: name, at: order))
        editorModel.activeLayerID = newID
    }

    /// Deletes the active layer, confirming first when it still holds elements (design §3).
    private func deleteActiveLayer(scene: EMFEdit.Scene) {
        guard scene.layers.count > 1,
              let activeID = editorModel.resolvedActiveLayerID(in: scene),
              let order = scene.layerOrder(ofLayer: activeID) else { return }
        let layer = scene.layers[order]
        if LayerDeletion.needsConfirmation(elementCount: layer.elements.count) {
            pendingDelete = PendingLayerDelete(id: activeID, name: layer.name, count: layer.elements.count)
        } else {
            session.apply(.deleteLayer(id: activeID))
        }
    }

    /// Maps a move within the top-first display order back to the back-to-front layer id
    /// list `reorderLayers` expects.
    private func move(from source: IndexSet, to destination: Int, scene: EMFEdit.Scene) {
        var displayed = Array(scene.layers.reversed())
        displayed.move(fromOffsets: source, toOffset: destination)
        session.apply(.reorderLayers(displayed.reversed().map(\.id)))
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
