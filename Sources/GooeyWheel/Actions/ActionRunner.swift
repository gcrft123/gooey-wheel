import AppKit

/// Runs chosen items and keeps the state the wheel shows for them: whether a toggle is on,
/// a slider's level, a picker's choices.
final class ActionRunner {
    /// The app in front when the wheel opened.
    private var frontmost: NSRunningApplication?
    /// Actions that wait for the wheel to leave the screen.
    private var pending: [() -> Void] = []
    /// Called on the main thread when a state the wheel may be showing has changed.
    var onStateChange: (() -> Void)?
    /// Called when an action needs Accessibility and doesn't have it.
    var onNeedsAccessibility: (() -> Void)?
    private var askedForAccessibility = false

    init() {
        NotificationCenter.default.addObserver(forName: ActionBehaviors.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.onStateChange?()
        }
    }

    func wheelOpened() {
        frontmost = NSWorkspace.shared.frontmostApplication
    }

    private func invocation(_ item: WheelItem) -> ActionInvocation {
        ActionInvocation(argument: item.argument, frontmost: frontmost ?? NSWorkspace.shared.frontmostApplication)
    }

    private func behavior(_ item: WheelItem) -> ActionBehavior? {
        item.actionID.flatMap(ActionBehaviors.behavior(for:))
    }

    // MARK: Running

    /// Runs an item that was chosen. Returns false if it failed straight away, so the wheel
    /// can say so.
    @discardableResult
    func perform(_ item: WheelItem) -> Bool {
        guard let behavior = behavior(item), let run = behavior.run else { return false }
        let invocation = invocation(item)
        // A toggle's state before it flips, to say afterwards what it became.
        let wasOn = behavior.isOn?(invocation)
        let action = { [weak self] in
            guard let self else { return }
            // Keys meant for one app never go to another that came forward in the meantime.
            if ActionBehaviors.sendsKeys(item.actionID), let meant = invocation.frontmost,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != meant.processIdentifier {
                self.failed(item, ActionError.failed("\(meant.localizedName ?? "The app") is no longer in front"))
                return
            }
            do {
                try run(invocation)
                if let wasOn, let id = item.actionID { Self.confirmToggle(id, on: !wasOn) }
            } catch {
                self.failed(item, error)
            }
            self.onStateChange?()
        }
        // An action that ends the session or deletes files waits for every key to be let go:
        // with ⌥ held, its menu command skips the confirmation. Still held after ten seconds,
        // it doesn't run at all.
        let destructive = ActionBehaviors.isDestructive(item.actionID)
        let whenReleased = { [weak self] in
            KeySender.whenModifiersReleased(timeout: destructive ? 10 : 0.5, required: destructive, gaveUp: {
                self?.failed(item, ActionError.failed("A modifier key was held down"))
            }, action)
        }
        switch behavior.timing {
        case .now:
            guard behavior.isAvailable() else {
                failed(item, ActionError.unavailable(item.title))
                return false
            }
            if needsAccessibilityNow(item) { return false }
            whenReleased()
        case .afterClose:
            pending.append(whenReleased)
        }
        return true
    }

    /// Runs one of a picker's choices.
    func choose(_ choice: LiveChoice, of item: WheelItem) {
        guard let behavior = behavior(item), let choose = behavior.choose else { return }
        let invocation = invocation(item)
        let action = { [weak self] in
            do {
                try choose(choice, invocation)
            } catch {
                self?.failed(item, error)
            }
            self?.onStateChange?()
        }
        if behavior.timing == .afterClose, !choice.keepsOpen {
            pending.append(action)
        } else {
            if needsAccessibilityNow(item) { return }
            KeySender.whenModifiersReleased(action)
        }
    }

    /// The wheel is off the screen. Actions that were waiting for that run now.
    func wheelHidden() {
        let actions = pending
        pending.removeAll()
        guard !actions.isEmpty else { return }
        // One more moment for the window server to take the wheel's window away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for action in actions { action() }
        }
    }

    private func needsAccessibilityNow(_ item: WheelItem) -> Bool {
        guard !KeySender.isTrusted, ActionBehaviors.needsAccessibility(item.actionID) else { return false }
        failed(item, ActionError.needsAccessibility)
        return true
    }

    private func failed(_ item: WheelItem, _ error: Error) {
        NSLog("Gooey Wheel: \(item.title) failed: \(error)")
        if case ActionError.needsAccessibility = error {
            onNeedsAccessibility?()
            if !askedForAccessibility {
                askedForAccessibility = true
                // Shows the system prompt and lists the app under Accessibility.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            ActionFeedback.failed("Allow Accessibility for Gooey Wheel")
            return
        }
        ActionFeedback.failed(Self.message(for: error))
    }

    /// What the toast says about an error.
    static func message(for error: Error) -> String {
        switch error {
        case ActionError.needsAccessibility:
            return "Allow Accessibility for Gooey Wheel"
        case ActionError.unavailable(let what):
            // A name, such as "Free Spin", becomes a sentence. A sentence is kept.
            let words = what.split(separator: " ").count
            return words <= 3 && !what.hasPrefix("No ") ? "\(what) isn't available on this Mac" : what
        case ActionError.failed(let why):
            return why
        default:
            return "Something went wrong"
        }
    }

    /// Toggles whose new state isn't plain to see say what they became. Dark Mode, the Dock,
    /// and Stage Manager show it themselves.
    private static let toggleMessages: [String: (on: (String, String), off: (String, String))] = [
        "media.mute": (("Sound muted", "speaker.slash.fill"), ("Sound on", "speaker.wave.2.fill")),
        "system.micMute": (("Microphone muted", "mic.slash.fill"), ("Microphone on", "mic.fill")),
        "system.keepAwake": (("Keeping your Mac awake", "cup.and.saucer.fill"), ("Your Mac can sleep again", "moon.zzz.fill")),
        "system.wifi": (("Wi-Fi on", "wifi"), ("Wi-Fi off", "wifi.slash")),
        "system.doNotDisturb": (("Do Not Disturb on", "moon.fill"), ("Do Not Disturb off", "moon")),
        "mouse.precision": (("Precision Mode on", "scope"), ("Precision Mode off", "scope")),
        "mouse.smartShift": (("Scroll wheel spins freely", "arrow.trianglehead.2.clockwise.rotate.90"), ("Scroll wheel clicks", "circle.dotted")),
        "mouse.haptics": (("Mouse haptics on", "dot.radiowaves.left.and.right"), ("Mouse haptics off", "dot.radiowaves.left.and.right")),
        "mouse.scrollDirection": (("Natural scrolling on", "arrow.up.and.down"), ("Natural scrolling off", "arrow.up.and.down")),
    ]

    private static func confirmToggle(_ id: String, on: Bool) {
        guard let messages = toggleMessages[id] else { return }
        let (text, symbol) = on ? messages.on : messages.off
        ActionFeedback.confirm(text, symbol: symbol)
    }

    // MARK: State

    func isAvailable(_ item: WheelItem) -> Bool {
        behavior(item)?.isAvailable() ?? true
    }

    func isOn(_ item: WheelItem) -> Bool? {
        behavior(item)?.isOn?(invocation(item))
    }

    func liveSymbol(_ item: WheelItem) -> String? {
        guard let behavior = behavior(item) else { return nil }
        let invocation = invocation(item)
        if let level = behavior.level, let symbol = level.symbol, let value = level.read() { return symbol(value) }
        return behavior.liveSymbol?(invocation)
    }

    func detail(_ item: WheelItem) -> String? {
        guard let behavior = behavior(item) else { return nil }
        if let level = behavior.level, let value = level.read() { return level.format(value) }
        if let on = behavior.isOn?(invocation(item)) { return behavior.liveDetail?(invocation(item)) ?? (on ? "On" : "Off") }
        return behavior.liveDetail?(invocation(item))
    }

    func level(_ item: WheelItem) -> Double? {
        behavior(item)?.level?.read()
    }

    func detent(_ item: WheelItem) -> Double {
        behavior(item)?.level?.detent ?? 1.0 / 16
    }

    func setLevel(_ item: WheelItem, _ value: Double) {
        guard let level = behavior(item)?.level else { return }
        do {
            try level.write(clamp01(value))
        } catch {
            failed(item, error)
        }
    }

    func format(_ item: WheelItem, level value: Double) -> String? {
        behavior(item)?.level?.format(value)
    }

    func step(_ item: WheelItem, by notches: Int) {
        guard notches != 0, let step = behavior(item)?.step else { return }
        if needsAccessibilityNow(item) { return }
        do {
            try step(notches, invocation(item))
        } catch {
            failed(item, error)
        }
    }

    /// Where Move Window would put the front window, in screen coordinates.
    func previewFrame(_ item: WheelItem) -> CGRect? {
        guard item.actionID == "window.move" else { return nil }
        let choice = ActionCatalog.action("window.move")?.choice(item.argument)?.id ?? "leftHalf"
        return WindowActions.targetFrame(for: choice, invocation: invocation(item))
    }

    func choices(_ item: WheelItem) -> [LiveChoice] {
        behavior(item)?.choices?(invocation(item)) ?? []
    }
}

extension ActionRunner: ControlSource {}

extension ActionBehaviors {
    /// Posted on the main thread by an action whose state changed outside the wheel's view,
    /// such as a value read in the background.
    static let stateDidChange = Notification.Name("GooeyWheelActionStateDidChange")

    /// Actions that send key presses to the app in front.
    static func sendsKeys(_ id: String?) -> Bool {
        guard let id else { return false }
        return ["edit.", "navigation.", "automation.keystroke", "automation.typeText", "apps.quickLook", "apps.getInfo", "apps.moveToTrash"]
            .contains { id.hasPrefix($0) }
    }

    /// Actions that end the session or delete files, whose confirmation a held ⌥ would skip.
    static func isDestructive(_ id: String?) -> Bool {
        ["system.logOut", "system.restart", "system.shutDown", "system.emptyTrash", "apps.moveToTrash"].contains(id ?? "")
    }

    /// Actions that send key presses or move other apps' windows, which macOS allows only
    /// with the Accessibility permission.
    static func needsAccessibility(_ id: String?) -> Bool {
        guard let id else { return false }
        let prefixes = ["edit.", "navigation.", "window.", "automation.keystroke", "automation.typeText",
                        "desktop.minimize", "desktop.fullScreen", "desktop.nextDisplay", "desktop.closeWindow",
                        "apps.quickLook", "apps.getInfo", "apps.moveToTrash", "desktop.space", "desktop.stageManager",
                        "system.doNotDisturb", "system.spotlight", "system.notificationCenter", "system.controlCenter",
                        "system.dictation", "system.emoji", "system.forceQuit", "system.logOut", "system.restart",
                        "system.shutDown", "system.emptyTrash"]
        return prefixes.contains { id.hasPrefix($0) }
    }
}
