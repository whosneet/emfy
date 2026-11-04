import EMFRender
import SwiftUI

/// Where VoiceOver focus moves as the regular-width inspector opens and closes.
enum ViewerA11yFocus: Hashable {
    case infoButton
    case inspectorHeader
}

/// The file-details panel: a trailing column at regular width (iPad, Duo inner)
/// and a bottom sheet at compact width (iPhone, Duo outer, Split View halves).
/// Content follows the approved iPhone-Info and iPad-Viewer-Inspector mockups:
/// the file name and when it was opened, a grouped details list, and a "What
/// Emfy couldn't show" section. No export rows yet — those arrive in I3.
///
/// This view deliberately has NO internal `NavigationStack`: as a column it sits
/// inside the viewer, which is already pushed on the app's NavigationStack, and a
/// nested stack there pops the outer one. A close button in the header replaces
/// the nav-bar Done; the compact sheet also swipe-dismisses.
struct FileInfoInspector: View {
    let entry: RecentEntry
    let diagnostics: ViewerDiagnostics
    let naturalSize: CGSize
    /// The live zoom percentage, shown only where it fits (regular width).
    let zoomPercent: Int
    let showZoomRow: Bool
    /// Closes the panel — dismisses the compact sheet or hides the regular column.
    let onClose: () -> Void
    /// VoiceOver focus binding so the header takes focus when the column opens.
    var headerFocus: AccessibilityFocusState<ViewerA11yFocus?>.Binding

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Form {
            // The title and "Opened …" line as a plain, full-colour row — NOT a
            // Section header (the system greys section headers).
            Section {
                header
            }
            .listRowBackground(Color.clear)

            Section {
                LabeledContent("Format", value: entry.fullFormatName)
                LabeledContent("Size", value: sizeString)
                LabeledContent("Picture size", value: pictureSizeString)
                LabeledContent("Drawn from", value: drawnFrom)
                if showZoomRow {
                    LabeledContent("Zoom", value: "\(zoomPercent)%")
                        .monospacedDigit()
                }
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))

            let notes = diagnostics.couldNotShowNotes
            if !notes.isEmpty {
                Section("What Emfy couldn't show") {
                    ForEach(Array(notes.enumerated()), id: \.offset) { item in
                        Label {
                            Text(item.element)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        // No-ops in the regular-width column; for the compact sheet they set the
        // detents and give it an opaque grouped background so the drawing behind
        // never shows through the rows.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(openedLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused(headerFocus, equals: .inspectorHeader)

            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.secondary, Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }

    // MARK: - Derived text

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
    }

    private var pictureSizeString: String {
        "\(Int(naturalSize.width.rounded())) × \(Int(naturalSize.height.rounded()))"
    }

    /// Follows the mockup: "Built-in EMF copy" for a WMF that played its embedded
    /// EMF, "WMF records" for WMF record playback, "EMF records" for a plain EMF.
    private var drawnFrom: String {
        switch diagnostics.kind {
        case .emf:
            return diagnostics.embeddedEMF == .played ? "Built-in EMF copy" : "EMF records"
        case .wmfRecords:
            return "WMF records"
        }
    }

    private var openedLine: String {
        let when = entry.openedAt
        let time = when.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(when) {
            return "Opened today at \(time)"
        }
        let date = when.formatted(date: .abbreviated, time: .shortened)
        return "Opened \(date)"
    }
}
