#if os(macOS)
import AppKit

/// Counts how many items in a menu tree carry a given key equivalent, so a slice that
/// adds a shortcut can prove it did not create a DUPLICATE of an existing one (F1 did this
/// for ⌘C through the responder chain; F3b does it for Find ⌘F / Find Next ⌘G / Find
/// Previous ⇧⌘G). Pure over `NSMenu`, so the DEBUG launch audit and the unit test share it.
enum MenuShortcutAudit {
    /// The number of items in `menu` (recursing into submenus) whose key equivalent is
    /// `key` with exactly `modifiers`. Case-sensitive on the key character, exact on the
    /// modifier mask.
    static func count(key: String, modifiers: NSEvent.ModifierFlags, in menu: NSMenu) -> Int {
        var total = 0
        for item in menu.items {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask == modifiers { total += 1 }
            if let submenu = item.submenu { total += count(key: key, modifiers: modifiers, in: submenu) }
        }
        return total
    }
}
#endif
