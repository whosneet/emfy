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
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

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
                    SheetDoneToolbar { dismiss() }   // G2
                }
        }
        #endif
    }
}

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
    // The Settings sheet hosts its own removal flow, because the window-level one is
    // covered by this sheet (C4a H3, M5). Clear confirms and offers Save a Copy.
    @State private var removal = RemovalCoordinator()
    #endif

    var body: some View {
        Form {
            #if os(macOS)
            // The Mac Settings idiom: a describing label with a trailing action
            // button, not a row-wide bordered button in the grouped Form (S1 / L).
            Section("Library") {
                LabeledContent("Recent files") {
                    Button("Clear Recents…", role: .destructive) {
                        MacRecentsConfirmation.confirmClear(store: store)
                    }
                    .disabled(store.entries.isEmpty)
                }
            }
            Section("Help & diagnostics") {
                LabeledContent("What's New") {
                    Button("Show") { openWindow(id: "whats-new") }
                }
                LabeledContent("Changelog") {
                    Button("Show") { openWindow(id: "changelog") }
                }
                LabeledContent("Developer documentation") {
                    Button("Open") { if let url = EmfyLinks.gitHub { openURL(url) } }
                }
                LabeledContent("Contact the developer") {
                    Button("Email") { if let url = EmfyLinks.contact { openURL(url) } }
                }
            }
            #else
            Section("Library") {
                clearRecentsButton
            }
            Section("Help & diagnostics") {
                whatsNewRow
                changelogRow
                developerDocumentationRow
                contactRow
            }
            #endif
        }
        #if os(iOS)
        .recentsRemoval(removal, store: store, toast: nil)
        #endif
    }

    #if os(iOS)
    // MARK: - Library

    private var clearRecentsButton: some View {
        Button(role: .destructive) {
            removal.requestClear(store: store)
        } label: {
            // "…" because it confirms first (L).
            Label("Clear Recents…", systemImage: "trash")
        }
        .disabled(store.entries.isEmpty)
    }

    // MARK: - Help & diagnostics

    private var whatsNewRow: some View {
        NavigationLink {
            WhatsNewView().navigationTitle("What's New").navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("What's New", systemImage: "sparkles")
        }
    }

    private var changelogRow: some View {
        NavigationLink {
            ChangelogView().navigationTitle("Changelog").navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Changelog", systemImage: "list.bullet.rectangle")
        }
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
    #endif
}
