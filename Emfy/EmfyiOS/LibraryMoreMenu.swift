#if os(iOS)
import SwiftUI

/// The shared library More menu (C4a H1): extracted from the compact grid so the
/// regular-width iPad sidebar can reach Settings, About, What's New, Changelog,
/// Contact, GitHub and Clear Recents too. Both `RecentsGrid` and `RegularSidebarList`
/// use it, driving the same `RecentsSheet` host (`librarySheets`).
struct LibraryMoreMenu: View {
    @Environment(\.openURL) private var openURL
    @Binding var activeSheet: RecentsSheet?
    let entriesEmpty: Bool
    /// Starts the Clear Recents confirmation (routed through the RemovalCoordinator).
    let onClear: () -> Void

    var body: some View {
        Menu {
            Button { activeSheet = .settings } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button { activeSheet = .about } label: {
                Label("About Emfy", systemImage: "info.circle")
            }
            Button { activeSheet = .whatsNew } label: {
                Label("What's New", systemImage: "sparkles")
            }
            Button { activeSheet = .changelog } label: {
                Label("Changelog", systemImage: "list.bullet.rectangle")
            }
            Divider()
            Button {
                if let url = EmfyLinks.contact { openURL(url) }
            } label: {
                Label("Contact Support", systemImage: "envelope")
            }
            Button {
                if let url = EmfyLinks.gitHub { openURL(url) }
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Divider()
            Button(role: .destructive, action: onClear) {
                // "…" because it confirms first (L).
                Label("Clear Recents…", systemImage: "trash")
            }
            .disabled(entriesEmpty)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("libraryMore")
    }
}

extension View {
    /// Hosts the shared library sheets (Settings, About, What's New, Changelog) for a
    /// `RecentsSheet` binding, so both the grid and the regular-width sidebar present
    /// the same screens (C4a H1).
    ///
    /// A sheet is a separate hosting view; the Settings screen reads `RecentsStore`
    /// and `EmfySettings` from the environment, so they are re-injected here rather
    /// than relying on the presenting column's injection surviving the app-switcher
    /// snapshot re-layout (C1).
    func librarySheets(
        _ activeSheet: Binding<RecentsSheet?>,
        store: RecentsStore,
        settings: EmfySettings
    ) -> some View {
        sheet(item: activeSheet) { sheet in
            switch sheet {
            case .about: AboutView()
            case .whatsNew: InfoSheet(title: "What's New") { WhatsNewView() }
            case .changelog: InfoSheet(title: "Changelog") { ChangelogView() }
            case .settings:
                SettingsView()
                    .environment(store)
                    .environment(settings)
                    // The AI providers section reads AIProviderStore as a non-optional
                    // environment value; a sheet is a separate hosting view, so inject it
                    // here too or that read traps (U3).
                    .environment(AIProviderStore.shared)
            }
        }
    }
}
#endif
