import EMFEdit
import SwiftUI

// MARK: - "Recolour…" sheet (X2a)
//
// A deterministic (no-AI) recolour of the open drawing to a palette: greyscale, colour-
// blind-safe, print, or the user's brand colours. Shows a before/after preview and the
// old→new mapping list, scoped to the selection if any (else the whole drawing). Apply is
// one grouped "Recolour" undo.

struct DrawingRecolourView: View {
    let model: DrawingRecolourModel
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            fields
            buttons
        }
        .padding(22)
        .frame(width: 520)
        #else
        // Scroll the fields and pin the actions so Apply stays reachable at large
        // accessibility text sizes and in landscape (C5e A3).
        ScrollView {
            fields
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            buttons
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.bar)
        }
        #endif
    }

    private var fields: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            header
            palettePicker
            if model.mode == .brand { brandEntry }
            previewRow
            mappingList
        }
    }

    // A segmented control truncates "Colour-blind safe" / "Brand colours" on iPhone, so it
    // falls back to a menu at compact width (C5e A3). The compact label is hand-built so the
    // mode name wraps instead of clipping top and bottom at large AX sizes (L1 review).
    @ViewBuilder
    private var palettePicker: some View {
        @Bindable var model = model
        if isCompact {
            Menu {
                Picker("Palette", selection: $model.mode) {
                    ForEach(DrawingRecolourModel.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Palette").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(model.mode.title)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
            .accessibilityIdentifier("recolourMode")
        } else {
            Picker("Palette", selection: $model.mode) {
                ForEach(DrawingRecolourModel.Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("recolourMode")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette")
                .font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recolour").font(.headline)
                Text("Applies to \(model.scopeDescription).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var brandEntry: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Enter 2–8 brand colours as hex (e.g. #1F3A93).")
                .font(.caption).foregroundStyle(.secondary)
            let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(model.brandHex.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        swatch(PlanColor.parse(model.brandHex[index]))
                        TextField("#RRGGBB", text: Binding(
                            get: { model.brandHex[index] },
                            set: { model.brandHex[index] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel("Brand colour \(index + 1)")
                    }
                }
                Button {
                    if model.brandHex.count < 8 { model.brandHex.append("") }
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .disabled(model.brandHex.count >= 8)
                .accessibilityLabel("Add brand colour")
            }
            .accessibilityIdentifier("brandColours")
        }
    }

    private var previewRow: some View {
        HStack(spacing: 16) {
            previewColumn("Before", image: model.beforeImage)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            previewColumn("After", image: model.afterImage)
        }
        .frame(maxWidth: .infinity)
    }

    private func previewColumn(_ title: String, image: CGImage?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
                }
            }
            .frame(maxWidth: 190, maxHeight: 170)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var mappingList: some View {
        if model.mappingRows.isEmpty {
            Text("No colours to change for this palette.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.mappingRows.count) colour\(model.mappingRows.count == 1 ? "" : "s") mapped")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.mappingRows) { row in
                            HStack(spacing: 8) {
                                swatch(row.from)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                swatch(row.to)
                                Text(PlanColor(row.to).hex).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func swatch(_ color: SceneColor?) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? Color.clear)
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4), lineWidth: 0.5))
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply") { model.apply(); onClose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply)
                .accessibilityIdentifier("recolourApply")
        }
        // Single-line labels that shrink rather than wrap into a hyphenated circle at the
        // largest accessibility text sizes (C5e A3 review).
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
