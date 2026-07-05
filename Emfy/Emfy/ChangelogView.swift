import SwiftUI

/// A scrollable, newest-first list of every released version and its changes.
/// Reuses `ChangeBullet` from the What's New view for consistent formatting.
struct ChangelogView: View {
    private let entries = Changelog.entries

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Emfy Changelog")
                    .font(.title.weight(.semibold))

                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Version \(entry.version) (Build \(entry.build)) — \(entry.date)")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entry.changes, id: \.self) { change in
                                ChangeBullet(text: change)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
