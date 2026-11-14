import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Routes externally-opened files (Finder, Files, Mail, Messages, the File ▸ Open
/// panel) to the right window and keeps track of which library window is front
/// (v3-plan §9.1, §11.2). One shared instance owns the window registry; each
/// `LibraryWindow` registers a selector and reports when it becomes key.
///
/// The policy itself is the pure, tested `OpenRouting`: an external open lands in
/// the front window and is added to Recents; only when no window exists at all is
/// the open held until one appears, so a cold-launch open never spawns a second
/// window alongside the one SwiftUI restores.
@MainActor
@Observable
final class OpenCoordinator {
    static let shared = OpenCoordinator()

    /// Each window's "select this entry" closure, keyed by the window's id.
    @ObservationIgnored private var selectors: [UUID: (UUID) -> Void] = [:]
    /// Each window's Clear-Recents save guard, keyed by the window's id. The menu-bar
    /// Clear Menu and the Settings Clear Recents are app-global and bypass the per-window
    /// `RemovalCoordinator`; they run the FRONT window's guard here before clearing, so an
    /// open, dirty WMF/WMZ isn't silently thrown away by a clear (item 0 / R2U3).
    @ObservationIgnored private var clearGuards: [UUID: () async -> Bool] = [:]
    /// Window ids in activation order; the last is the front (key) window.
    @ObservationIgnored private var order: [UUID] = []
    /// Entries awaiting a window — populated only when none is registered yet
    /// (cold launch); drained by the next window to register.
    @ObservationIgnored private var pending: [UUID] = []

    /// Opens a new library window showing an entry, wired by the app from a view that
    /// holds `openWindow` (macOS). Used when an App Intent routes an open but no window
    /// is registered to receive it (SI1). `nil` on iOS, where a scene always registers
    /// (or is created on a cold launch and drains `pending`).
    @ObservationIgnored var openNewWindow: ((UUID) -> Void)?

    private var frontWindowID: UUID? { order.last }

    // MARK: - Window registry

    /// A window announces itself and how to select an entry within it. Draining
    /// here lets a cold-launch open land in the first window that appears.
    func register(windowID: UUID, select: @escaping (UUID) -> Void) {
        selectors[windowID] = select
        order.removeAll { $0 == windowID }
        order.append(windowID)
        drainPending()
    }

    func unregister(windowID: UUID) {
        selectors[windowID] = nil
        clearGuards[windowID] = nil
        order.removeAll { $0 == windowID }
    }

    /// A window installs its Clear-Recents save guard (its `LibraryWindowModel.guardClear`).
    /// Removed by `unregister` when the window closes.
    func setClearGuard(windowID: UUID, _ guardClear: @escaping () async -> Bool) {
        clearGuards[windowID] = guardClear
    }

    /// Runs the front window's Clear-Recents save guard, returning whether the clear may
    /// proceed. With no window (or none with a guard installed) the clear proceeds — there
    /// is no open document whose edits a clear could lose (item 0 / R2U3).
    func frontClearGuard() async -> Bool {
        guard let id = frontWindowID, let guardClear = clearGuards[id] else { return true }
        return await guardClear()
    }

    /// Marks a window front when it becomes key, so external opens route to it.
    func markFront(windowID: UUID) {
        guard selectors[windowID] != nil else { return }
        order.removeAll { $0 == windowID }
        order.append(windowID)
    }

    // MARK: - Routing

    /// Routes an entry opened by an App Intent (SI1): selects it in the front window
    /// when one exists; else — macOS — opens a new window showing it (so "Open Drawing"
    /// works with every window closed); else holds it for the next window to register
    /// (the cold-launch path, which on iOS is the scene SwiftUI creates). Replaces the
    /// former `selectInFront`, whose queued open was never drained when no iOS scene had
    /// registered or no Mac window was open — the intent did nothing.
    func routeFromIntent(_ entryID: UUID) {
        if let id = frontWindowID, let select = selectors[id] {
            select(entryID)
        } else if let openNewWindow {
            openNewWindow(entryID)
        } else {
            pending.append(entryID)
        }
    }

    #if os(macOS)
    /// Routes an opened entry from the menu bar: into the front window when one
    /// exists, else opens a new library window showing it — so ⌘O and Open Recent
    /// work with every window closed rather than queuing invisibly (C4a M5). When
    /// `inNewWindow` is set (the "Open files in → New window" setting, S1a-4b),
    /// it always spawns a new window instead of reusing the front one.
    func route(_ entryID: UUID, openWindow: OpenWindowAction, inNewWindow: Bool = false) {
        if inNewWindow {
            openWindow(id: "library", value: LibraryWindowValue(entryID: entryID))
        } else if let id = frontWindowID, let select = selectors[id] {
            select(entryID)
        } else {
            openWindow(id: "library", value: LibraryWindowValue(entryID: entryID))
        }
    }

    /// Imports each URL into Recents (off-main) and routes it (front window, or a new
    /// window when none is open or the setting asks for one). Used by the macOS
    /// File ▸ Open panel; Finder opens arrive via `onOpenURL`.
    func open(urls: [URL], store: RecentsStore, openWindow: OpenWindowAction, inNewWindow: Bool = false) {
        Task { @MainActor in
            for url in urls {
                guard let entryID = await store.handleOpenedURL(url) else { continue }
                route(entryID, openWindow: openWindow, inNewWindow: inNewWindow)
            }
        }
    }
    #endif

    private func drainPending() {
        guard !pending.isEmpty, let id = frontWindowID, let select = selectors[id] else { return }
        let items = pending
        pending.removeAll()
        for entryID in items { select(entryID) }
    }
}

#if os(macOS)
import UniformTypeIdentifiers

extension OpenCoordinator {
    /// File ▸ Open (⌘O): an `NSOpenPanel` limited to the metafile types, routed to
    /// the front window, or a new window when none is open (C4a M5).
    func presentOpenPanel(store: RecentsStore, openWindow: OpenWindowAction, inNewWindow: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MetafileTypes.readableContentTypes
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls, store: store, openWindow: openWindow, inNewWindow: inNewWindow)
    }
}

/// Reports to the coordinator when its host window's key state changes, so routing
/// follows the frontmost window and the window-level alert shows only in the key one
/// (C4a M5). A zero-size, non-drawing representable; it only observes.
struct WindowFrontReporter: NSViewRepresentable {
    /// Called with `true` when the window becomes key and `false` when it resigns.
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReporterView()
        view.onKeyChange = onKeyChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReporterView)?.onKeyChange = onKeyChange
    }

    private final class ReporterView: NSView {
        var onKeyChange: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            guard let window else { return }
            onKeyChange?(window.isKeyWindow)
            center.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
        }

        @objc private func windowDidBecomeKey() { onKeyChange?(true) }
        @objc private func windowDidResignKey() { onKeyChange?(false) }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
#endif
