import SwiftUI

/// First-launch state: a `ContentUnavailableView`-style centre (icon, title,
/// explanation, Open button) with the "previews work without opening Emfy" card
/// near the bottom, matching the approved iPhone-Home-Empty mockup.
struct EmptyRecentsView: View {
    let openAction: () -> Void

    var body: some View {
        // Centred when there's room; scrolls (keeping the Open button and the
        // previews card reachable) when height is tight — compact/Duo-outer
        // landscape, a third of iPad width, or large Dynamic Type.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("No recent files")
                            .font(.title2.weight(.bold))
                        Text("Open an EMF or WMF file from Files, or tap Share in Mail or Messages and choose Emfy. Compressed .emz and .wmz files work too.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(action: openAction) {
                            Label("Open from Files", systemImage: "folder")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 32)

                    Spacer(minLength: 24)

                    previewsCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var previewsCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Previews work without opening Emfy")
                    .font(.subheadline.weight(.semibold))
                Text("Metafiles show thumbnails in Files and preview in Mail and Messages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
