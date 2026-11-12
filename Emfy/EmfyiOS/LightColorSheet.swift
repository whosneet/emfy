import EMFEdit
import SwiftUI

/// The light editor's Colour sheet (E4 design call 2): eight preset swatches (black,
/// white, system blue, red, green, orange, purple, yellow) plus a system
/// `ColorPicker`. A pick applies to the selection through
/// `DocumentSession.applyColor`, which routes each element to its paint channel —
/// `setFill` for closed shapes and text (a run's fill is its glyph colour),
/// `setStroke` for lines and paths (`LightColorRouter`).
///
/// Undo: each swatch tap is one undo step (a fresh coalescing key per tap); a
/// ColorPicker scrub coalesces into a single step (one constant key for the drag).
struct LightColorSheet: View {
    let session: DocumentSession
    /// The selection to recolour, captured when the sheet opened.
    let selection: Set<Int>

    @Environment(\.dismiss) private var dismiss
    @State private var pickerColor: Color = .black
    /// Bumped per swatch tap so each tap is a distinct undo entry (its own key).
    @State private var swatchTick = 0

    /// The eight preset swatches, in the design's order.
    private static let swatches: [(name: String, color: Color)] = [
        ("Black", .black), ("White", .white), ("Blue", .blue), ("Red", .red),
        ("Green", .green), ("Orange", .orange), ("Purple", .purple), ("Yellow", .yellow),
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Self.swatches.indices, id: \.self) { index in
                        swatchButton(Self.swatches[index])
                    }
                }

                Divider()

                ColorPicker("Custom colour", selection: $pickerColor, supportsOpacity: false)
                    .font(.body)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // A ColorPicker scrub streams many changes; one constant key coalesces them
            // into a single undo step.
            .onChange(of: pickerColor) { _, colour in
                apply(colour, coalescing: SceneCoalescingKey("lightColorPicker"))
            }
        }
    }

    private func swatchButton(_ swatch: (name: String, color: Color)) -> some View {
        Button {
            // A fresh key per tap, so each swatch is its own undo entry.
            apply(swatch.color, coalescing: SceneCoalescingKey("lightSwatch-\(swatchTick)"))
            swatchTick += 1
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
    }

    private func apply(_ colour: Color, coalescing key: SceneCoalescingKey) {
        let rgba = colour.rgbaComponents
        session.applyColor(
            SceneColor(red: rgba.red, green: rgba.green, blue: rgba.blue),
            to: selection, coalescing: key
        )
    }
}
