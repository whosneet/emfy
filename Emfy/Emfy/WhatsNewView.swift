import AppKit
import SwiftUI

/// An About-panel-styled window showing what changed in the installed version
/// (`Changelog.latest`): the app icon, a title, and the release's changes as a
/// bulleted list. Read-only; scrolls if the list outgrows the window.
struct WhatsNewView: View {
    private let entry = Changelog.latest

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("What's New in Emfy \(entry.version)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.changes, id: \.self) { change in
                        ChangeBullet(text: change)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One bulleted change line, shared by the What's New and Changelog views.
struct ChangeBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
