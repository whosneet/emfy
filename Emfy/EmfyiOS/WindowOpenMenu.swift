import SwiftUI
import UIKit

/// Sets the host window scene's minimum size on iPad only (R2; audit L-A), so a
/// resizable iPad window can't shrink below where the compact layout works — but it is
/// small enough (320×400) to allow the iPadOS 26 half-width and portrait halves, which
/// the old 600×480 blocked. Applied ONLY for the `.pad` idiom: iPhone (including the
/// iOS 27 iPhone Mirroring window) must never be constrained, so the restriction is
/// skipped there even if `sizeRestrictions` is non-nil. Attached as a hidden background
/// view so it rides along with the library window and re-applies on (re)attach.
struct SceneMinimumSize: UIViewRepresentable {
    let minimumSize: CGSize

    final class MinSizeView: UIView {
        var minimumSize: CGSize = .zero
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            // iPad only — never constrain iPhone or iPhone Mirroring (L-A).
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            window?.windowScene?.sizeRestrictions?.minimumSize = minimumSize
        }
    }

    func makeUIView(context: Context) -> MinSizeView {
        let view = MinSizeView()
        view.minimumSize = minimumSize
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: MinSizeView, context: Context) {
        uiView.minimumSize = minimumSize
        uiView.apply()
    }
}

/// The user activity that carries a selected entry into a freshly-opened window.
enum WindowOpenActivity {
    static let type = "com.avneetsingh.emfy.openInNewWindow"

    static func make(_ entryID: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.userInfo = ["entryID": entryID.uuidString]
        return activity
    }

    static func entryID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?["entryID"] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Wraps a recents grid tile so its tap opens the file and its long press shows a
/// UIKit context menu whose "Open in New Window" uses `UIWindowScene.ActivationAction`.
/// That action shows the "Open" alternate (and opens in the current window) on
/// displays that can't host a second window — the iPhone and the iPhone Duo outer
/// display — and creates a window carrying the entry where they can (the Duo inner
/// display in a Split View half) — Axiom iphone-duo.md. The tap and the long press
/// live on one UIKit view so they coordinate (tap cancels when the menu opens).
///
/// Used only by the compact grid; the regular-width list keeps the SwiftUI
/// `openWindow` path, since iPad and the Duo inner display always support a second
/// window. VoiceOver is served by the tile's own label plus the default/custom
/// actions added alongside this overlay.
struct TileOpenInteraction: UIViewRepresentable {
    let entryID: UUID
    /// Tap, and the "Open" alternate — show the file in the current window.
    let onOpen: () -> Void
    let onRemove: () -> Void
    /// Pin/Unpin (S1a-5). `canPin` is false for a session-only Private entry, which
    /// can't be pinned; `isPinned` chooses the title.
    var isPinned: Bool = false
    var canPin: Bool = true
    var onPin: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        pushState(context)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        pushState(context)
    }

    private func pushState(_ context: Context) {
        context.coordinator.update(
            entryID: entryID, onOpen: onOpen, onRemove: onRemove,
            isPinned: isPinned, canPin: canPin, onPin: onPin
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        private var entryID = UUID()
        private var onOpen: () -> Void = {}
        private var onRemove: () -> Void = {}
        private var isPinned = false
        private var canPin = true
        private var onPin: () -> Void = {}

        func update(
            entryID: UUID, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void,
            isPinned: Bool, canPin: Bool, onPin: @escaping () -> Void
        ) {
            self.entryID = entryID
            self.onOpen = onOpen
            self.onRemove = onRemove
            self.isPinned = isPinned
            self.canPin = canPin
            self.onPin = onPin
        }

        @objc func handleTap() { onOpen() }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.makeMenu()
            }
        }

        private func makeMenu() -> UIMenu {
            let openHere = UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { [onOpen] _ in
                onOpen()
            }
            let remove = UIAction(
                title: "Remove from Recents",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [onRemove] _ in
                onRemove()
            }
            let id = entryID
            // iOS 15+. Shows `openHere` where a second window can't be created
            // (iPhone, Duo outer), and creates a window carrying the entry elsewhere.
            let newWindow = UIWindowScene.ActivationAction(
                title: "Open in New Window",
                image: UIImage(systemName: "square.on.square.badge.person.crop"),
                identifier: nil,
                discoverabilityTitle: nil,
                attributes: [],
                alternate: openHere
            ) { _ in
                UIWindowScene.ActivationConfiguration(userActivity: WindowOpenActivity.make(id))
            }
            var children: [UIMenuElement] = [newWindow]
            if canPin {
                children.append(UIAction(
                    title: isPinned ? "Unpin" : "Pin",
                    image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
                ) { [onPin] _ in onPin() })
            }
            children.append(remove)
            return UIMenu(children: children)
        }
    }
}
