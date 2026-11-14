import SwiftUI

// MARK: - The per-provider consent screen (A2b)
//
// Shown the first time a provider would receive drawing data, and on Test connection.
// It states plainly which provider (name + host) will receive data, EXACTLY what is
// sent, what is NEVER sent, that the provider's own policy then applies, and offers
// Allow / Don't Allow. Allow records the purpose's exact categories in `AIConsentStore`.
// The content comes entirely from `AIConsentSheetContent`, so the screen and the stored
// grant can't drift (CLAUDE.md §8 / v3-plan §10.1).

struct AIConsentSheet: View {
    let content: AIConsentSheetContent
    let onAllow: () -> Void
    let onDeny: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: Shared content

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Send this drawing to \(content.providerName)?")
                .font(.headline)
                .multilineTextAlignment(.center)
            if !content.host.isEmpty {
                Text(content.host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryBlock(
                title: "What’s sent",
                systemImage: "arrow.up.circle",
                tint: .orange,
                items: content.sent)
            categoryBlock(
                title: "Never sent",
                systemImage: "xmark.circle",
                tint: .secondary,
                items: content.neverSent)
            Text(content.policyNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func categoryBlock(title: String, systemImage: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func allow() { onAllow(); dismiss() }
    private func deny() { onDeny(); dismiss() }

    // MARK: Mac

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 20) {
            header
            ScrollView { lists.padding(.horizontal, 4) }
                .frame(maxHeight: 320)
            HStack {
                Button("Don’t Allow") { deny() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow") { allow() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
    #else

    // MARK: iOS

    private var iosBody: some View {
        NavigationStack {
            Group {
                // iOS 26's safeAreaBar supplies the glass bar treatment; older systems keep
                // the safeAreaInset path with an explicit .bar background (C5e G4).
                if #available(iOS 26.0, *) {
                    iosScrollBody.safeAreaBar(edge: .bottom) { bottomButtons }
                } else {
                    iosScrollBody.safeAreaInset(edge: .bottom) { bottomButtons.background(.bar) }
                }
            }
            .navigationTitle("Allow sending?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var iosScrollBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                lists
            }
            .padding()
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            Button(action: allow) {
                Text("Allow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Don’t Allow", role: .cancel) { deny() }
                .frame(maxWidth: .infinity)
        }
        .padding()
    }
    #endif
}

// MARK: - Presentation helper

extension View {
    /// Presents the consent screen whenever `provider` is non-nil. Allow records the
    /// purpose's categories in the store and calls `onAllow`; an interactive dismiss or
    /// Don't Allow calls `onDeny`. The provider config is the sheet's identity, so a
    /// different provider re-presents.
    func aiConsentSheet(
        provider: AIProviderConfig?,
        purpose: AIConsentPurpose,
        store: AIProviderStore?,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) -> some View {
        // A read-only mirror of `provider`; SwiftUI writes nil only on interactive
        // dismissal, which we treat as Don't Allow. The Allow/Deny buttons clear the
        // source state directly (via the callbacks), so the setter isn't re-entered.
        let binding = Binding<AIProviderConfig?>(
            get: { provider },
            set: { if $0 == nil { onDeny() } }
        )
        return sheet(item: binding) { config in
            AIConsentSheet(
                content: AIConsentSheetContent.make(provider: config, purpose: purpose),
                onAllow: {
                    store?.grantConsent(config.id, purpose: purpose)
                    onAllow()
                },
                onDeny: onDeny)
        }
    }
}
