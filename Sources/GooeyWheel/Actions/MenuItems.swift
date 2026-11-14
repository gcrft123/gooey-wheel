import AppKit

/// Menu items and menu bar extras found through Accessibility, matched by the identifiers
/// and shortcuts AppKit gives them rather than their titles, which change with the language.
enum MenuItems {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute)
    }

    static func isEnabled(_ element: AXUIElement) -> Bool {
        attribute(element, kAXEnabledAttribute) ?? false
    }

    /// An item's shortcut: the virtual key code when the key types no character (such as
    /// Escape or Delete) or else the character, and the AX modifier bits, where Command is
    /// implied unless bit 8 is set (Shift 1, Option 2, Control 4).
    struct Shortcut: Equatable {
        var character: String? = nil
        var key: Int? = nil
        var modifiers: Int
    }

    static func shortcut(_ item: AXUIElement) -> Shortcut? {
        let character: String? = attribute(item, "AXMenuItemCmdChar")
        let key: Int? = attribute(item, "AXMenuItemCmdVirtualKey")
        let modifiers: Int = attribute(item, "AXMenuItemCmdModifiers") ?? 0
        if let key { return Shortcut(key: key, modifiers: modifiers) }
        if let character, !character.isEmpty { return Shortcut(character: character, modifiers: modifiers) }
        return nil
    }

    // MARK: App menus

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return app
    }

    /// The menus of an app's menu bar, the Apple menu first.
    static func menus(of pid: pid_t) -> [AXUIElement] {
        guard let bar: AXUIElement = attribute(application(pid), kAXMenuBarAttribute) else { return [] }
        return children(bar).compactMap { children($0).first }
    }

    /// The items of one of an app's menus, without separators.
    static func items(_ menu: AXUIElement) -> [AXUIElement] {
        children(menu).filter { (attribute($0, kAXTitleAttribute) as String?)?.isEmpty == false }
    }

    /// The first item in any of an app's menus that `matches`, looking one level deep.
    static func item(in pid: pid_t, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        for menu in menus(of: pid) {
            if let found = items(menu).first(where: matches) { return found }
        }
        return nil
    }

    /// An item AppKit names after the action it sends, such as "orderFrontCharacterPalette:".
    static func item(in pid: pid_t, identifier: String) -> AXUIElement? {
        item(in: pid) { self.identifier($0) == identifier }
    }

    /// The app whose menus to use: the one in front if it has a menu bar, else Finder.
    static func menuOwner(_ frontmost: NSRunningApplication?) -> pid_t? {
        if let frontmost, frontmost.activationPolicy == .regular { return frontmost.processIdentifier }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    // MARK: The Apple menu

    /// Items of the Apple menu, which every app's menu bar carries.
    enum AppleItem: CaseIterable {
        case forceQuit, restart, shutDown, lockScreen, logOut

        var identifier: String {
            switch self {
            case .forceQuit: return "_forceQuitPanelRequested:"
            case .restart: return "_restartRequested:"
            case .shutDown: return "_shutDownRequested:"
            case .lockScreen: return "_lockScreenRequested:"
            case .logOut: return "_logOutRequested:"
            }
        }
    }

    private static let forceQuitShortcut = Shortcut(key: 53, modifiers: 2) // ⌥⌘⎋
    private static let lockShortcut = Shortcut(character: "Q", modifiers: 4) // ⌃⌘Q
    private static let logOutShortcut = Shortcut(character: "Q", modifiers: 1) // ⇧⌘Q

    /// `byIdentifier` false skips the identifiers, for checks of the fallback.
    static func appleItem(_ which: AppleItem, in pid: pid_t, byIdentifier: Bool = true) -> AXUIElement? {
        guard let menu = menus(of: pid).first else { return nil }
        let all = items(menu)
        if byIdentifier, let found = all.first(where: { identifier($0) == which.identifier }) { return found }
        // Without identifiers, the shortcuts find most items. Restart… and Shut Down… have
        // none: they are the last two of the items between Force Quit… and Lock Screen that
        // aren't alternates (which show while Option is held, and carry Option without Command).
        switch which {
        case .forceQuit: return all.first { shortcut($0) == forceQuitShortcut }
        case .lockScreen: return all.first { shortcut($0) == lockShortcut }
        case .logOut: return all.first { shortcut($0) == logOutShortcut }
        case .restart, .shutDown:
            guard let start = all.firstIndex(where: { shortcut($0) == forceQuitShortcut }),
                  let end = all.firstIndex(where: { shortcut($0) == lockShortcut }), start < end else { return nil }
            let primaries = all[(start + 1)..<end].filter { item in
                let modifiers: Int = attribute(item, "AXMenuItemCmdModifiers") ?? 0
                return modifiers & 8 == 0 && shortcut(item) == nil
            }
            guard primaries.count >= 2 else { return nil }
            return which == .restart ? primaries[primaries.count - 2] : primaries[primaries.count - 1]
        }
    }

    // MARK: Menu bar extras

    /// The processes that draw the system's menu bar extras on macOS 26 and later, and before.
    private static let extrasOwners = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]

    /// A system menu bar extra, such as "com.apple.menuextra.clock".
    static func menuExtra(_ identifier: String) -> AXUIElement? {
        for bundleID in extrasOwners {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                guard let bar: AXUIElement = attribute(application(app.processIdentifier), "AXExtrasMenuBar") else { continue }
                if let found = find(identifier, in: bar, depth: 3) { return found }
            }
        }
        return nil
    }

    private static func find(_ identifier: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        for child in children(element) {
            if self.identifier(child) == identifier { return child }
            if depth > 0, let found = find(identifier, in: child, depth: depth - 1) { return found }
        }
        return nil
    }

    // MARK: Pressing

    /// Presses a menu item or extra. An item whose action opens a modal panel may not answer
    /// before the messaging timeout; the press has been delivered by then.
    static func press(_ element: AXUIElement) throws {
        try KeySender.requireTrust()
        AXUIElementSetMessagingTimeout(element, 1)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else {
            throw ActionError.failed("Pressing the menu item failed (\(result.rawValue))")
        }
    }
}
