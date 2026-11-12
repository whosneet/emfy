import SwiftUI

// MARK: - AI title/tags display (A1b Part 1)
//
// The AI title as a SECONDARY line under a recents file name (the file is never
// renamed), and the tag chips shown in the viewer's Info segment. Both are gated by
// `DrawingTitleTagPolicy.shouldDisplay` — nothing shows while AI is off or in Private
// mode, even if metadata is stored.

/// The AI title line under a recents tile/row, or nothing when there's no title or AI
/// display is off.
struct RecentAITitleLine: View {
    @Environment(EmfySettings.self) private var settings
    let entry: RecentEntry
    var lineLimit = 1

    var body: some View {
        if DrawingTitleTagPolicy.shouldDisplay(aiEnabled: settings.useOnDeviceAI, privateMode: settings.privateMode),
           let title = entry.aiTitle, !title.isEmpty {
            Label(title, systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }
}

/// The viewer Info segment's AI title + tag chips for the open drawing, or nothing
/// when none are stored or AI display is off.
struct DrawingAITagsSection: View {
    @Environment(EmfySettings.self) private var settings
    let entry: RecentEntry

    private var shouldShow: Bool {
        DrawingTitleTagPolicy.shouldDisplay(aiEnabled: settings.useOnDeviceAI, privateMode: settings.privateMode)
            && entry.aiTitleTags != nil
    }

    var body: some View {
        if shouldShow, let titleTags = entry.aiTitleTags {
            Section {
                if !titleTags.title.isEmpty {
                    LabeledContent("AI title", value: titleTags.title)
                }
                if !titleTags.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags").foregroundStyle(.secondary)
                        TagChipFlow(tags: titleTags.tags)
                    }
                }
            } header: {
                Label("AI tags", systemImage: "tag")
            }
        }
    }
}

/// Small capsule chips that wrap onto as many lines as needed (the Info tag list).
struct TagChipFlow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// A minimal flow layout (macOS 14 / iOS 17 `Layout`): lays subviews left-to-right,
/// wrapping to a new line when the next subview would overflow the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, min(x - spacing, maxWidth))
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
