import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Emfy's Settings UI (C3b scope 6), one view adapted per platform: on macOS it is
/// the content of the `Settings` scene (⌘,); on iOS it is pushed as a sheet from
/// the library's More menu, alongside About and What's New.
///
/// Only real controls ship in C3b — no placeholder or "coming soon" panes. The
/// layout is a sectioned `Form`, so S1 adds the Viewer / Export / Rendering /
/// Quick Look / Updates groups as further sections without restructuring.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        SettingsForm()
            .formStyle(.grouped)
            .scenePadding()
            .frame(width: 480, height: 420)
        #else
        NavigationStack {
            SettingsForm()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        DismissSettingsButton()
                    }
                }
        }
        #endif
    }
}

#if os(iOS)
/// The iOS sheet's Done button — the Settings screen is presented modally there.
private struct DismissSettingsButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("Done", systemImage: "checkmark") { dismiss() }
    }
}
#endif

/// The shared sectioned body: Library and Help & diagnostics. Each action branches
/// per platform (macOS windows / `NSAlert`; iOS sheets / `openURL`) but the
/// structure is one.
private struct SettingsForm: View {
    @Environment(RecentsStore.self) private var store
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(iOS)
    @State private var showClearConfirmation = false
    #endif

    var body: some View {
        Form {
            Section("Library") {
                clearRecentsButton
            }

            Section("Help & diagnostics") {
                whatsNewRow
                changelogRow
                developerDocumentationRow
                contactRow
            }
        }
        #if os(iOS)
        .alert("Clear Recents?", isPresented: $showClearConfirmation) {
            Button("Clear Recents", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every file from your recent list. The files themselves are not deleted.")
        }
        #endif
    }

    // MARK: - Library

    private var clearRecentsButton: some View {
        Button(role: .destructive) {
            #if os(macOS)
            MacRecentsConfirmation.confirmClear(store: store)
            #else
            showClearConfirmation = true
            #endif
        } label: {
            Label("Clear Recents", systemImage: "trash")
        }
        .disabled(store.entries.isEmpty)
    }

    // MARK: - Help & diagnostics

    @ViewBuilder
    private var whatsNewRow: some View {
        #if os(macOS)
        Button { openWindow(id: "whats-new") } label: {
            Label("What's New", systemImage: "sparkles")
        }
        #else
        NavigationLink {
            WhatsNewView().navigationTitle("What's New").navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("What's New", systemImage: "sparkles")
        }
        #endif
    }

    @ViewBuilder
    private var changelogRow: some View {
        #if os(macOS)
        Button { openWindow(id: "changelog") } label: {
            Label("Changelog", systemImage: "list.bullet.rectangle")
        }
        #else
        NavigationLink {
            ChangelogView().navigationTitle("Changelog").navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Changelog", systemImage: "list.bullet.rectangle")
        }
        #endif
    }

    private var developerDocumentationRow: some View {
        Button {
            if let url = EmfyLinks.gitHub { openURL(url) }
        } label: {
            Label("Developer Documentation", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    private var contactRow: some View {
        Button {
            if let url = EmfyLinks.contact { openURL(url) }
        } label: {
            Label("Contact the Developer", systemImage: "envelope")
        }
    }
}
