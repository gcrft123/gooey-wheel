import AppKit
import Carbon.HIToolbox

/// Window and app actions: moving, minimizing, full screen and closing the window in front,
/// and switching, hiding and quitting apps. The direct download reaches the window through the
/// Accessibility API; the App Store edition, which the sandbox keeps out of other apps' windows,
/// sends the system's and the app's shortcuts instead.
enum WindowActions {
    static let behaviors: [String: ActionBehavior] = {
        // Previous App needs the activation order from as early as possible.
        _ = AppHistory.shared
        var map = shared
        #if APPSTORE
        map.merge(byKeys) { $1 }
        #else
        map.merge(byAccessibility) { $1 }
        #endif
        return map
    }()

    #if APPSTORE
    /// Each sent to the app in front as a press of its keys. Minimize, Close and Hide are
    /// the standard menu shortcuts of Mac apps, and ⌃⌘F is full screen's.
    private static let byKeys: [String: ActionBehavior] = [
        "window.move": WindowTiling.behavior,
        "desktop.minimize": .keys(KeyCombo.character("m", .maskCommand) ?? KeyCombo(kVK_ANSI_M, .maskCommand)),
        "desktop.fullScreen": .keys(KeyCombo.character("f", [.maskControl, .maskCommand]) ?? KeyCombo(kVK_ANSI_F, [.maskControl, .maskCommand])),
        "desktop.closeWindow": .keys(KeyCombo.character("w", .maskCommand) ?? KeyCombo(kVK_ANSI_W, .maskCommand)),
        // The sandbox refuses hiding another app, so the app in front hides itself, or the others.
        "desktop.hideApp": ActionBehavior(run: { invocation in
            guard let app = frontmost(invocation) else { throw ActionError.failed("No app is in front") }
            if app == .current {
                NSApp.hide(nil)
            } else {
                try KeySender.post(KeyCombo.character("h", .maskCommand) ?? KeyCombo(kVK_ANSI_H, .maskCommand))
            }
        }),
        "desktop.hideOthers": .keys(KeyCombo.character("h", [.maskAlternate, .maskCommand]) ?? KeyCombo(kVK_ANSI_H, [.maskAlternate, .maskCommand])),
    ]
    #else
    private static let byAccessibility: [String: ActionBehavior] = [
            "window.move": ActionBehavior(run: { invocation in
                try move(invocation.argument ?? WindowLayout.choices[0].id, invocation: invocation)
            }),
            "desktop.minimize": ActionBehavior(run: { invocation in
                let window = try AXWindow.focused(of: invocation.frontmost)
                guard window.set(kAXMinimizedAttribute, true) || window.pressButton(kAXMinimizeButtonAttribute) else {
                    throw ActionError.failed("The window can't be minimized")
                }
            }),
            "desktop.fullScreen": ActionBehavior(run: { invocation in
                try toggleFullScreen(try AXWindow.focused(of: invocation.frontmost))
            }),
            "desktop.closeWindow": ActionBehavior(run: { invocation in
                let window = try AXWindow.focused(of: invocation.frontmost)
                guard window.pressButton(kAXCloseButtonAttribute) else {
                    throw ActionError.failed("The window has no close button")
                }
            }),
            "desktop.nextDisplay": ActionBehavior(isAvailable: { NSScreen.screens.count > 1 }, run: { invocation in
                try moveToNextDisplay(invocation)
            }),
    ]
    #endif

    private static let shared: [String: ActionBehavior] = [
            "desktop.switchApps": previousApp,
            "desktop.hideApp": ActionBehavior(run: { invocation in
                guard let app = frontmost(invocation) else { throw ActionError.failed("No app is in front") }
                // The window server doesn't hide an accessory app such as the wheel, so the
                // wheel hides its own windows.
                if app == .current {
                    NSApp.hide(nil)
                } else if !app.hide() {
                    throw ActionError.failed("\(app.localizedName ?? "The app") can't be hidden")
                }
            }),
            "desktop.hideOthers": ActionBehavior(run: { invocation in
                // NSWorkspace's hideOtherApplications keeps the calling app, which is the wheel,
                // and hides the app in front.
                let pids = AppSwitching.appsToHide(
                    running: AppSwitching.runningApps,
                    frontmost: frontmost(invocation)?.processIdentifier,
                    exclude: getpid()
                )
                for pid in pids { NSRunningApplication(processIdentifier: pid)?.hide() }
            }),
            "desktop.quitFront": ActionBehavior(run: { invocation in
                guard let pid = AppSwitching.appToQuit(frontmost: frontmost(invocation)?.processIdentifier, exclude: getpid()),
                      let app = NSRunningApplication(processIdentifier: pid)
                else { throw ActionError.failed("No app to quit") }
                #if APPSTORE
                // The sandbox refuses a request to quit another app, so the app gets ⌘Q itself.
                try KeySender.requireTrust()
                let quit = KeyCombo.character("q", .maskCommand) ?? KeyCombo(kVK_ANSI_Q, .maskCommand)
                KeySender.whenModifiersReleased { KeySender.post(KeySender.events(for: quit), to: pid) }
                #else
                // Asks the app to quit as ⌘Q would, so it can ask to save. Never forced.
                app.terminate()
                #endif
            }),
    ]

    private static func frontmost(_ invocation: ActionInvocation) -> NSRunningApplication? {
        invocation.frontmost ?? NSWorkspace.shared.frontmostApplication
    }

    // MARK: Previous App

    /// The app Previous App would bring forward now.
    static func previousApp(_ invocation: ActionInvocation) -> NSRunningApplication? {
        AppSwitching.previousApp(
            recent: AppHistory.shared.recent,
            windowOwners: AppSwitching.windowOwnersFrontToBack(),
            frontmost: frontmost(invocation)?.processIdentifier,
            running: AppSwitching.runningApps,
            exclude: getpid()
        ).flatMap(NSRunningApplication.init(processIdentifier:))
    }

    /// Brings the previous app forward. The bubble shows that app's icon, and the hub its name.
    private static var previousApp: ActionBehavior {
        var behavior = ActionBehavior(run: { invocation in
            guard let app = previousApp(invocation) else { throw ActionError.failed("No other app to switch to") }
            AppSwitching.activate(app)
        })
        behavior.liveSymbol = { invocation in
            previousApp(invocation)?.bundleIdentifier.map { ItemIcon.app($0).name }
        }
        behavior.liveDetail = { invocation in previousApp(invocation)?.localizedName }
        return behavior
    }

    #if !APPSTORE
    // MARK: Moving

    /// What Move Window remembers about a window it moved.
    struct Record {
        /// The frame before the first of a run of moves, which Restore goes back to.
        var original: CGRect
        /// Where the last move left the window. If the window is still there, the user hasn't
        /// moved it since.
        var placed: CGRect
        var layout: String
        /// How many times in a row `layout` was chosen, less one.
        var step: Int
    }

    static var history: [AXWindow.Key: Record] = [:]

    /// The frame a layout gives a window, and the step it's at, from its frame now and what
    /// was remembered about it. Nil when there's nothing to do, such as Restore with no record.
    static func plan(_ layout: String, window: CGRect, visible: CGRect, record: Record?) -> (frame: CGRect, step: Int)? {
        let untouched = record.map { WindowGeometry.same(window, $0.placed) } ?? false
        if layout == "restore" { return record.map { ($0.original, 0) } }
        var step = 0
        if untouched, let record, record.layout == layout, WindowGeometry.cyclingLayouts.contains(layout) {
            step = record.step + 1
        }
        return WindowGeometry.frame(for: layout, window: window, visible: visible, step: step).map { ($0, step) }
    }

    /// The frame, in AppKit screen coordinates, the window in front would get from a layout,
    /// without moving it. For a preview while the layout is hovered.
    static func targetFrame(for layoutID: String, invocation: ActionInvocation) -> CGRect? {
        guard let window = try? AXWindow.focused(of: invocation.frontmost, timeout: 0.25),
              let frame = window.frame
        else { return nil }
        let screens = NSScreen.screens
        guard let index = WindowGeometry.screenIndex(for: frame, among: screens.map(\.frame)) else { return nil }
        let record = history[window.key]
        return plan(layoutID, window: frame, visible: screens[index].visibleFrame, record: record)?.frame
    }

    static func move(_ layout: String, invocation: ActionInvocation) throws {
        let window = try AXWindow.focused(of: invocation.frontmost)
        guard let frame = window.frame, let visible = window.screenVisibleFrame else {
            throw ActionError.failed("The window can't be moved")
        }
        if window.isFullScreen == true { throw ActionError.failed("The window is in full screen") }
        let key = window.key
        let record = history[key]
        guard let plan = plan(layout, window: frame, visible: visible, record: record) else {
            throw ActionError.failed(layout == "restore" ? "Nothing to restore" : "Unknown layout \(layout)")
        }
        // Restore uses the visible frame of the screen it goes back to.
        let target = layout == "restore"
            ? (WindowGeometry.screenIndex(for: plan.frame, among: NSScreen.screens.map(\.frame)).map { NSScreen.screens[$0].visibleFrame } ?? visible)
            : visible
        window.setFrame(plan.frame, within: target)
        if layout == "restore" {
            history[key] = nil
        } else {
            // A window moved by hand since starts a new run, which Restore comes back to.
            let untouched = record.map { WindowGeometry.same(frame, $0.placed) } ?? false
            history[key] = Record(
                original: (untouched ? record?.original : nil) ?? frame,
                placed: window.frame ?? plan.frame,
                layout: layout,
                step: plan.step
            )
        }
    }

    static func moveToNextDisplay(_ invocation: ActionInvocation) throws {
        let window = try AXWindow.focused(of: invocation.frontmost)
        guard let frame = window.frame else { throw ActionError.failed("The window can't be moved") }
        if window.isFullScreen == true { throw ActionError.failed("The window is in full screen") }
        let screens = NSScreen.screens
        guard screens.count > 1, let index = WindowGeometry.screenIndex(for: frame, among: screens.map(\.frame)) else {
            throw ActionError.unavailable("Next Display needs a second display")
        }
        let next = WindowGeometry.nextScreenIndex(after: index, among: screens.map(\.frame))
        let target = screens[next].visibleFrame
        window.setFrame(WindowGeometry.moved(frame, from: screens[index].visibleFrame, to: target), within: target)
    }

    /// Turns full screen on or off. Apps that don't expose it as a setting get a press of the
    /// green button instead.
    static func toggleFullScreen(_ window: AXWindow) throws {
        if window.isSettable("AXFullScreen"), let on = window.isFullScreen, window.set("AXFullScreen", !on) { return }
        guard window.pressButton(kAXFullScreenButtonAttribute) else {
            throw ActionError.failed("The window can't go full screen")
        }
    }
    #endif
}

#if APPSTORE
/// Move Window through the system's tiling, which macOS 15 put in every app's Window → Move &
/// Resize menu. Fill, Center and Return to Previous Size are key equivalents of that menu, so
/// their Globe-Control shortcuts go straight to the app in front, which runs the menu item.
/// The halves aren't offered: their shortcuts are the window server's, which tells them from
/// Spaces' Control-arrows by the keyboard's own Globe key, and no event an app posts carries it.
enum WindowTiling {
    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    /// Fill, Center and Return to Previous Size stand in for Maximize, Center and Restore.
    static let keys: [(layout: String, combo: KeyCombo)] = [
        ("maximize", KeyCombo.character("f", [.maskControl, .maskSecondaryFn]) ?? KeyCombo(kVK_ANSI_F, [.maskControl, .maskSecondaryFn])),
        ("center", KeyCombo.character("c", [.maskControl, .maskSecondaryFn]) ?? KeyCombo(kVK_ANSI_C, [.maskControl, .maskSecondaryFn])),
        ("restore", KeyCombo.character("r", [.maskControl, .maskSecondaryFn]) ?? KeyCombo(kVK_ANSI_R, [.maskControl, .maskSecondaryFn])),
    ]

    static var behavior: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: { isSupported }) { invocation in
            try move(invocation.argument ?? keys[0].layout, in: invocation.frontmost)
        }
        behavior.unavailableMessage = "Move Window needs macOS 15 or later"
        return behavior
    }

    static func move(_ layout: String, in app: NSRunningApplication?) throws {
        guard isSupported else { throw ActionError.unavailable("Move Window needs macOS 15 or later") }
        guard let combo = keys.first(where: { $0.layout == layout })?.combo else {
            throw ActionError.unavailable("The App Store version can only fill, center, or restore a window")
        }
        guard let app else { throw ActionError.failed("No app is in front") }
        try KeySender.requireTrust()
        // Option or Command still held from the wheel's shortcut would make it another one.
        KeySender.whenModifiersReleased { KeySender.post(KeySender.events(for: combo), to: app.processIdentifier) }
    }
}
#endif
