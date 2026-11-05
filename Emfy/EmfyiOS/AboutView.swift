import SwiftUI

/// The About sheet: the app icon, the installed version, Arrley's attribution
/// line, and the copyright. Dynamic Type throughout; a Done button dismisses.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image("EmfyIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .accessibilityHidden(true)

                    Text("Emfy")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)   // A6
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("A free, open-source viewer for EMF and WMF metafiles on Mac, iPhone and iPad.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    VStack(spacing: 4) {
                        Text("Product of Arrley, built by Neet Singh in Sydney, Australia.")
                        Text("Copyright © 2026 Arrley Pty Ltd. MIT licensed.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .navigationTitle("About Emfy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
