import AppKit

/// Window and app actions: moving, minimizing, full screen and closing the window in front
/// through the Accessibility API, and switching, hiding and quitting apps.
enum WindowActions {
    static let behaviors: [String: ActionBehavior] = {
        // Previous App needs the activation order from as early as possible.
        _ = AppHistory.shared
        return [
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
                // Asks the app to quit as ⌘Q would, so it can ask to save. Never forced.
                app.terminate()
            }),
        ]
    }()

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
        // The window's number is read only when there's a record that could match it.
        let record = history.keys.contains { $0.pid == window.pid } ? window.key.flatMap { history[$0] } : nil
        return plan(layoutID, window: frame, visible: screens[index].visibleFrame, record: record)?.frame
    }

    static func move(_ layout: String, invocation: ActionInvocation) throws {
        let window = try AXWindow.focused(of: invocation.frontmost)
        guard let frame = window.frame, let visible = window.screenVisibleFrame else {
            throw ActionError.failed("The window can't be moved")
        }
        if window.isFullScreen == true { throw ActionError.failed("The window is in full screen") }
        let key = window.key
        let record = key.flatMap { history[$0] }
        guard let plan = plan(layout, window: frame, visible: visible, record: record) else {
            throw ActionError.failed(layout == "restore" ? "Nothing to restore" : "Unknown layout \(layout)")
        }
        // Restore uses the visible frame of the screen it goes back to.
        let target = layout == "restore"
            ? (WindowGeometry.screenIndex(for: plan.frame, among: NSScreen.screens.map(\.frame)).map { NSScreen.screens[$0].visibleFrame } ?? visible)
            : visible
        window.setFrame(plan.frame, within: target)
        guard let key else { return }
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
}
