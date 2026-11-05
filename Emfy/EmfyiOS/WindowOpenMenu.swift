import SwiftUI
import UIKit

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

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        context.coordinator.update(entryID: entryID, onOpen: onOpen, onRemove: onRemove)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(entryID: entryID, onOpen: onOpen, onRemove: onRemove)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        private var entryID = UUID()
        private var onOpen: () -> Void = {}
        private var onRemove: () -> Void = {}

        func update(entryID: UUID, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
            self.entryID = entryID
            self.onOpen = onOpen
            self.onRemove = onRemove
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
            return UIMenu(children: [newWindow, remove])
        }
    }
}
