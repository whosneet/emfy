import SwiftUI

/// The About sheet presented from the library More menu: the About content inside
/// its own navigation stack with a Done button.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AboutContent()
                .navigationTitle("About Emfy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    SheetDoneToolbar { dismiss() }   // G2
                }
        }
    }
}

/// The About content (S1a-6): the app icon, name, installed version and build,
/// Arrley's attribution, the MIT licence line, and a link to the public repo.
/// System fonts and text styles throughout, so it reads in Dark Mode and scales to
/// the largest Dynamic Type size (the ScrollView carries any overflow). Used both
/// inside `AboutView`'s sheet and pushed from Settings › Help & diagnostics.
struct AboutContent: View {
    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // The mark is black ink on a transparent ground; template rendering
                // tints it with the label colour so it reads in both appearances
                // (it was invisible on the dark About background otherwise).
                Image("EmfyIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                Text("Emfy")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)   // A6
                Text(versionLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("A free, open-source viewer for EMF and WMF metafiles on Mac, iPhone and iPad.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(spacing: 4) {
                    Text("Made by Arrley Pty Ltd")
                    Text("MIT licensed. Copyright © 2026 Arrley Pty Ltd.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

                if let url = EmfyLinks.gitHub {
                    Link("github.com/whosneet/emfy", destination: url)
                        .font(.footnote)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }
}
