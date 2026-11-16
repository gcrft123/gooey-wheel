import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
#if !APPSTORE
import CoreWLAN

/// Opens a private framework and looks up a function in it, or nil when this macOS lacks it.
func privateFunction<T>(_ framework: String, _ name: String, as type: T.Type) -> T? {
    guard let handle = dlopen(framework, RTLD_LAZY), let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}
#endif

#if APPSTORE
/// Mission Control, App Exposé, Show Desktop, Apps and Dock hiding. The Dock's own calls are
/// private, so this opens the apps that ask the Dock for an overview, or posts the default key
/// combination where the app would need launch arguments, which sandboxed apps can't pass.
enum Dock {
    enum Overview {
        case missionControl, appExpose, desktop, apps

        /// Apps.app replaced Launchpad in macOS 26.
        var app: String? {
            switch self {
            case .missionControl: return "com.apple.exposelauncher"
            case .apps: return "com.apple.apps.launcher"
            case .appExpose, .desktop: return nil
            }
        }

        var keys: KeyCombo? {
            switch self {
            case .appExpose: return KeyCombo(kVK_DownArrow, .maskControl)
            case .desktop: return KeyCombo(kVK_F11)
            case .missionControl, .apps: return nil
            }
        }
    }

    static func show(_ overview: Overview) throws {
        if let app = overview.app {
            try SystemApps.open(app)
        } else if let keys = overview.keys {
            try SystemShortcut.press(keys)
        }
    }

    /// Whether the Dock hides, judged from the space it keeps clear: a Dock that hides leaves a
    /// few points at the screen's edge, one that stays at least the height of its icons. Nil
    /// when no screen shows the difference, such as with every screen in full screen.
    static var autoHides: Bool? {
        var widest: CGFloat = 0
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            widest = max(widest, visible.minX - frame.minX, frame.maxX - visible.maxX, visible.minY - frame.minY)
        }
        return NSScreen.screens.isEmpty ? nil : widest < 12
    }

    /// Dock hiding's default shortcut, ⌥⌘D, which turns hiding on or off.
    static let toggleKeys = KeyCombo(kVK_ANSI_D, [.maskAlternate, .maskCommand])
}
#else
/// Mission Control, App Exposé, Show Desktop, Apps and Dock hiding, all run by the Dock.
enum Dock {
    private static let applicationServices = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    static let sendNotification = privateFunction(applicationServices, "CoreDockSendNotification", as: (@convention(c) (CFString, Int32) -> Void).self)
    static let getAutoHide = privateFunction(applicationServices, "CoreDockGetAutoHideEnabled", as: (@convention(c) () -> Bool).self)
    static let setAutoHide = privateFunction(applicationServices, "CoreDockSetAutoHideEnabled", as: (@convention(c) (Bool) -> Void).self)

    /// What the Dock is asked to show, and the app that asks for it when the Dock's own call
    /// is missing.
    enum Overview {
        case missionControl, appExpose, desktop, apps

        var notification: String {
            switch self {
            case .missionControl: return "com.apple.expose.awake"
            case .appExpose: return "com.apple.expose.front.awake"
            case .desktop: return "com.apple.showdesktop.awake"
            case .apps: return "com.apple.launchpad.toggle"
            }
        }

        /// Mission Control.app takes 1 for Show Desktop and 2 for App Exposé. Apps.app
        /// replaced Launchpad in macOS 26.
        var app: (bundleID: String, arguments: [String]) {
            switch self {
            case .missionControl: return ("com.apple.exposelauncher", [])
            case .appExpose: return ("com.apple.exposelauncher", ["2"])
            case .desktop: return ("com.apple.exposelauncher", ["1"])
            case .apps: return ("com.apple.apps.launcher", [])
            }
        }
    }

    static func show(_ overview: Overview) throws {
        if let sendNotification {
            sendNotification(overview.notification as CFString, 0)
            return
        }
        try SystemApps.open(overview.app.bundleID, arguments: overview.app.arguments)
    }

    static var autoHides: Bool? { getAutoHide?() }

    static func setAutoHides(_ on: Bool) throws {
        guard let setAutoHide else { throw ActionError.unavailable("Dock hiding") }
        setAutoHide(on)
    }
}
#endif

/// Apps that come with macOS, opened by bundle identifier.
enum SystemApps {
    static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func open(_ bundleID: String, arguments: [String] = []) throws {
        guard let url = url(bundleID) else { throw ActionError.unavailable(bundleID) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = !arguments.isEmpty
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { NSLog("Gooey Wheel: opening \(bundleID) failed: \(error)") }
        }
    }
}

#if !APPSTORE
/// Light and Dark appearance, set as System Settings sets it.
enum Appearance {
    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let getDark = privateFunction(skyLight, "SLSGetAppearanceThemeLegacy", as: (@convention(c) () -> Bool).self)
    static let setDark = privateFunction(skyLight, "SLSSetAppearanceThemeLegacy", as: (@convention(c) (Bool) -> Void).self)
    static let getAuto = privateFunction(skyLight, "SLSGetAppearanceThemeSwitchesAutomatically", as: (@convention(c) () -> Bool).self)
    static let setAuto = privateFunction(skyLight, "SLSSetAppearanceThemeSwitchesAutomatically", as: (@convention(c) (Bool) -> Void).self)

    static var isDark: Bool? { getDark?() }
    static var switchesAutomatically: Bool? { getAuto?() }

    /// Chooses Light or Dark. Choosing one turns off Auto, as it does in System Settings.
    static func setIsDark(_ dark: Bool) throws {
        guard let setDark else { throw ActionError.unavailable("Dark Mode") }
        if switchesAutomatically == true { setAuto?(false) }
        setDark(dark)
    }
}

/// Whether a Focus such as Do Not Disturb is on. macOS offers no call for it to apps without a
/// special entitlement. The Focus database answers it when the app has Full Disk Access.
enum FocusState {
    static let assertionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// Nil when the database can't be read.
    static var isOn: Bool? {
        guard let data = try? Data(contentsOf: assertionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = json["data"] as? [[String: Any]] else { return nil }
        return stores.contains { (($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty == false }
    }
}

#endif

/// Keeps the display and the Mac awake while the app holds a power assertion.
enum KeepAwake {
    private static var assertion: IOPMAssertionID = 0

    static var isOn: Bool { assertion != 0 }

    static func set(_ on: Bool) throws {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Gooey Wheel Keep Awake" as CFString, &id
            )
            guard result == kIOReturnSuccess else { throw ActionError.failed("Couldn't keep the Mac awake (\(result))") }
            assertion = id
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

#if APPSTORE
/// Sleep, as the Apple menu does it. Locking and logging out post their default shortcuts.
enum Session {
    /// Sleeps now, as `pmset sleepnow` does.
    static func sleep() throws {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { throw ActionError.failed("Couldn't reach power management") }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        guard result == kIOReturnSuccess else { throw ActionError.failed("Sleep was refused (\(result))") }
    }
}

/// Screenshots with the system's default shortcuts, so they go where the user's screenshot
/// settings say, with the thumbnail.
enum Screenshots {
    static let shortcuts: [String: KeyCombo] = [
        "screen": KeyCombo(kVK_ANSI_3, [.maskShift, .maskCommand]),
        "selection": KeyCombo(kVK_ANSI_4, [.maskShift, .maskCommand]),
        "selectionClipboard": KeyCombo(kVK_ANSI_4, [.maskControl, .maskShift, .maskCommand]),
        // ⇧⌘4, then Space turns the crosshair into the window camera.
        "window": KeyCombo(kVK_ANSI_4, [.maskShift, .maskCommand]),
    ]

    /// How long the crosshair takes to appear before Space can switch it to windows.
    static let windowModeDelay: TimeInterval = 0.3

    static func take(_ choice: String) throws {
        if choice == "toolbar" {
            try SystemApps.open("com.apple.screenshot.launcher")
            return
        }
        guard let combo = shortcuts[choice] else { throw ActionError.failed("Unknown screenshot \(choice)") }
        try SystemShortcut.press(combo)
        if choice == "window" {
            DispatchQueue.main.asyncAfter(deadline: .now() + windowModeDelay) { try? KeySender.post(KeyCombo(kVK_Space)) }
        }
    }
}

/// Sends a system shortcut's default key combination once no modifier is held, so a key still
/// held from the wheel's own shortcut doesn't join it.
enum SystemShortcut {
    static func press(_ combo: KeyCombo) throws {
        try KeySender.requireTrust()
        KeySender.whenModifiersReleased { try? KeySender.post(combo) }
    }
}
#else
/// The Wi-Fi radio.
enum WiFi {
    static var interface: CWInterface? { CWWiFiClient.shared().interface() }

    static var isOn: Bool? { interface?.powerOn() }

    static func set(_ on: Bool) throws {
        guard let interface else { throw ActionError.unavailable("Wi-Fi") }
        try interface.setPower(on)
    }
}

/// Locking, sleeping and switching users, as the Apple menu and Control Center do them.
enum Session {
    private static let login = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    static let lockScreen = privateFunction(login, "SACLockScreenImmediate", as: (@convention(c) () -> Int32).self)
    static let switchToLoginWindow = privateFunction(login, "SACSwitchToLoginWindow", as: (@convention(c) () -> Int32).self)

    static func lock(_ frontmost: NSRunningApplication?) throws {
        if let lockScreen, lockScreen() == 0 { return }
        try pressAppleItem(.lockScreen, frontmost)
    }

    static func switchUser() throws {
        guard let switchToLoginWindow else { throw ActionError.unavailable("Switch User") }
        let result = switchToLoginWindow()
        guard result == 0 else { throw ActionError.failed("Switching to the login window failed (\(result))") }
    }

    /// Sleeps now, as `pmset sleepnow` does.
    static func sleep() throws {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { throw ActionError.failed("Couldn't reach power management") }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        guard result == kIOReturnSuccess else { throw ActionError.failed("Sleep was refused (\(result))") }
    }

    /// Whether sleep is turned off for the whole system, as `pmset disablesleep 1` does. The
    /// Apple menu greys out Sleep then, and the system refuses it.
    static var sleepIsDisabled: Bool {
        let settings = copyPowerSettings?()?.takeRetainedValue() as? [String: Any]
        return (settings?["SleepDisabled"] as? Bool) ?? false
    }

    static let copyPowerSettings = privateFunction(
        "/System/Library/Frameworks/IOKit.framework/IOKit", "IOPMCopySystemPowerSettings",
        as: (@convention(c) () -> Unmanaged<CFDictionary>?).self
    )

    static func displaySleep() throws {
        try run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Restart…, Shut Down…, Log Out… and Force Quit… from the Apple menu, with the dialogs
    /// they show there.
    static func pressAppleItem(_ which: MenuItems.AppleItem, _ frontmost: NSRunningApplication?) throws {
        try KeySender.requireTrust()
        guard let pid = MenuItems.menuOwner(frontmost), let item = MenuItems.appleItem(which, in: pid) else {
            throw ActionError.failed("Couldn't find \(which) in the Apple menu")
        }
        try MenuItems.press(item)
    }

    static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
    }
}

/// Screenshots as the system takes them, with the user's save location and thumbnail.
enum Screenshots {
    /// The system shortcut for each choice that has one. Window capture has none of its own.
    static let shortcuts: [String: Int] = [
        "selection": SymbolicHotKey.screenshotSelection,
        "screen": SymbolicHotKey.screenshotScreen,
        "selectionClipboard": SymbolicHotKey.screenshotSelectionToClipboard,
    ]

    /// `screencapture` options for each choice, used for window capture and when keys can't
    /// be sent. -p uses the user's settings for where it goes; -u shows the thumbnail.
    static let commandLine: [String: [String]] = [
        "selection": ["-i", "-s", "-p", "-u"],
        "window": ["-i", "-W", "-p", "-u"],
        "screen": ["-p", "-u"],
        "selectionClipboard": ["-i", "-s", "-c"],
    ]

    static func take(_ choice: String) throws {
        if choice == "toolbar" {
            try SystemApps.open("com.apple.screenshot.launcher")
            return
        }
        if let id = shortcuts[choice], KeySender.isTrusted, SymbolicHotKey.isSupported {
            try SystemShortcut.press(id)
            return
        }
        guard let arguments = commandLine[choice] else { throw ActionError.failed("Unknown screenshot \(choice)") }
        try Session.run("/usr/sbin/screencapture", arguments)
    }
}

/// Sends a system shortcut once no modifier is held, so a key still held from the wheel's own
/// shortcut doesn't join it.
enum SystemShortcut {
    static func press(_ id: Int) throws {
        try KeySender.requireTrust()
        KeySender.whenModifiersReleased {
            do {
                try SymbolicHotKey.press(id)
            } catch {
                NSLog("Gooey Wheel: system shortcut \(id) failed: \(error)")
                ActionFeedback.failed(ActionRunner.message(for: error))
            }
        }
    }
}

#endif

/// The eyedropper, putting the color picked on the clipboard as a hex code.
enum ColorPicker {
    static func pick(returningTo frontmost: NSRunningApplication?) {
        // The sampler takes clicks only for the active app.
        NSApp.activate()
        NSColorSampler().show { color in
            if let color {
                let code = hex(color)
                copy(code)
                ActionFeedback.confirm("Copied \(code)", swatch: color)
            }
            frontmost?.activate(options: [])
        }
    }

    /// "#RRGGBB" in sRGB.
    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((clamp01($0) * 255).rounded()) }
        return "#" + parts.map { String(format: "%02X", $0) }.joined()
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#if APPSTORE
/// Empties the Trash with Finder's own Empty Trash… command, sent to Finder as its shortcut,
/// ⇧⌘⌫, so Finder asks first as it does from its menu.
enum Trash {
    static func empty() throws {
        try KeySender.requireTrust()
        try FinderCommand.send(KeyCombo(kVK_Delete, [.maskShift, .maskCommand]))
    }
}
#else
/// Empties the Trash with Finder's own Empty Trash… command, so Finder asks first as it does
/// from its menu. When the user has turned that warning off, the app asks instead: an item
/// chosen by mistake must never delete files without a question.
enum Trash {
    /// Finder's ⇧⌘⌫, in its app menu. The alternate with Option skips the warning.
    static let shortcut = MenuItems.Shortcut(key: 51, modifiers: 1)

    static var finder: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    static func emptyTrashItem() -> AXUIElement? {
        guard let finder, MenuItems.menus(of: finder.processIdentifier).count > 1 else { return nil }
        let appMenu = MenuItems.menus(of: finder.processIdentifier)[1]
        return MenuItems.items(appMenu).first { MenuItems.shortcut($0) == shortcut }
    }

    /// Finder's "Show warning before emptying the Trash", on unless turned off.
    static var finderWarns: Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        return (CFPreferencesCopyAppValue("WarnOnEmptyTrash" as CFString, "com.apple.finder" as CFString) as? Bool) ?? true
    }

    static func empty() throws {
        try KeySender.requireTrust()
        guard let finder, let item = emptyTrashItem() else { throw ActionError.unavailable("Finder's Empty Trash") }
        guard MenuItems.isEnabled(item) else { throw ActionError.failed("The Trash is already empty") }
        if !finderWarns, !confirm() { return }
        finder.activate(options: [])
        try MenuItems.press(item)
    }

    private static func confirm() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "The items in the Trash will be deleted permanently."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
