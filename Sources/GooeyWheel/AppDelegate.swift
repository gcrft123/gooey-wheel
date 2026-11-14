import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// The HID++ control ID of the button that opens the wheel.
    private static let buttonKey = "button"
    /// Seconds Assign Button waits for a press.
    private static let captureTimeout: TimeInterval = 15

    private var controller: WheelController?
    private var statusItem: NSStatusItem?
    /// Set between a press of the button and its release. The mouse can drop a release, which
    /// `LogiButton` recovers at the next press.
    private var buttonHeld = false
    private let button: LogiButton
    private var assignItem: NSMenuItem?
    private var hapticsItem: NSMenuItem?
    /// Shown while the app lacks Accessibility, which shortcuts, typing, and window actions need.
    private var accessibilityItem: NSMenuItem?
    private let options: LaunchOptions

    init(options: LaunchOptions) {
        self.options = options
        let saved = UserDefaults.standard.object(forKey: Self.buttonKey) as? Int
        button = LogiButton(controlID: saved.map { UInt16(truncatingIfNeeded: $0) } ?? LogiButton.thumbPanel)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = options.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        WheelItem.describe = WheelItem.argumentTitle
        AppIndex.systemAppsOnly = options.demo
        let store = options.demo ? WheelStore.temporary(rootCount: options.demoRootCount) : WheelStore.saved(at: options.storePath)
        guard let renderer = GooRenderer(), let controller = WheelController(renderer: renderer, store: store) else {
            NSLog("Metal is unavailable.")
            NSApp.terminate(nil)
            return
        }
        self.controller = controller
        controller.timescale = options.timescale
        controller.reduceMotion = options.reduceMotion

        if options.demo {
            controller.stage = options.stage
            controller.stageScript = options.demoScript
            controller.captureDirectory = options.captureDirectory
            controller.captureFilter = options.captureFilter
            controller.captureFrames = options.captureFrames
            controller.startDemo(DemoDriver(script: options.demoScript, exitWhenDone: options.demoExit, stopAt: options.demoStopAt))
            return
        }

        installStatusItem()
        // Previous App needs the order apps came forward in from the start.
        _ = AppHistory.shared
        // A system shortcut lent out for an action when the app last quit unexpectedly goes back.
        SymbolicHotKey.restoreInterrupted()
        TriggerDebug.wheelState = { [weak controller] in controller?.debugState ?? "" }
        TriggerDebug.start()
        if options.thumbButton { startButton() }

        // Open once at launch so there's something on screen, with how to summon it shown underneath.
        // The delay gives the mouse time to answer, so the hint names the right trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.openCentered(hint: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutomationActions.restoreClipboard()
        button.stop()
    }

    /// A quick press opens the wheel and leaves it open; holding keeps it open until release,
    /// which picks whatever the cursor is on. Pressing again while it's open closes it.
    /// `missed` marks a release the mouse never reported, recovered at the next press.
    private func buttonChanged(_ pressed: Bool, missed: Bool = false) {
        guard let controller else { return }
        if pressed {
            guard !buttonHeld else {
                TriggerDebug.event("button press IGNORED, already held")
                return
            }
            buttonHeld = true
            if controller.isOpen {
                TriggerDebug.event("button press → close")
                controller.dismiss()
            } else {
                TriggerDebug.event("button press → open")
                controller.open(mode: .held)
            }
        } else {
            guard buttonHeld else {
                TriggerDebug.event("button release IGNORED, wasn't held")
                return
            }
            buttonHeld = false
            TriggerDebug.event("button release\(missed ? " (recovered)" : "")")
            controller.triggerReleased(missed: missed)
        }
    }

    private func startButton() {
        button.onChange = { [weak self] pressed in self?.buttonChanged(pressed) }
        button.onMissedRelease = { [weak self] in self?.buttonChanged(false, missed: true) }
        button.onStatus = { [weak self] _ in self?.updateButtonState() }
        button.onNeedsRelaunch = {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", Bundle.main.bundleURL.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
        MouseLink.shared.use(button)
        button.start()
        updateButtonState()

        // Other software can hand the button back to the mouse, so claim it again when the
        // frontmost app changes and when the Mac wakes.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.button.reassert() }
            }
        }
    }

    private var buttonName: String {
        button.controlID.flatMap(LogiButton.name(of:)) ?? "Assigned Button"
    }

    /// The menu's Assign Button item and the hint under the wheel at launch, from the mouse's state.
    private func updateButtonState() {
        guard let controller, let item = assignItem else { return }
        item.isHidden = !options.thumbButton
        item.title = "Assign Button"
        item.action = #selector(assignButton)
        item.isEnabled = true
        switch button.status {
        case .ready:
            Self.setSubtitle(item, button.isCapturing ? "Press a mouse button…" : buttonName)
            controller.hintText = "Press the \(buttonName.lowercased()) to open"
        case .needsPermission:
            item.title = "Allow Input Monitoring…"
            Self.setSubtitle(item, nil)
            item.action = #selector(openInputMonitoring)
            controller.hintText = "Allow Input Monitoring to use your mouse"
        case .searching:
            Self.setSubtitle(item, button.canCapture ? "\(buttonName) not on this mouse" : "No mouse found")
            item.isEnabled = button.canCapture
            controller.hintText = "Open the wheel from the menu bar"
        }
    }

    /// Shows `text` under the item's title, or after it before macOS 14.4.
    private static func setSubtitle(_ item: NSMenuItem, _ text: String?) {
        if #available(macOS 14.4, *) {
            item.subtitle = text
        } else if let text {
            item.title += ": " + text
        }
    }

    @objc private func assignButton() {
        guard let controller else { return }
        // Choosing it again while it waits starts the wait over.
        button.cancelCapture()
        let screen = Self.pointerScreen()
        if controller.isOpen { controller.dismiss() }
        TriggerDebug.event("menu: Assign Button")
        controller.announce(Toast.Message(text: "Press a mouse button", symbol: "computermouse", lasts: Self.captureTimeout), on: screen)
        button.capturePress(timeout: Self.captureTimeout) { [weak self] control in
            guard let self else { return }
            defer { self.updateButtonState() }
            guard let control else {
                controller.withdrawAnnouncement()
                return
            }
            self.button.assign(control)
            UserDefaults.standard.set(Int(control), forKey: Self.buttonKey)
            controller.announce(Toast.Message(text: "\(self.buttonName) opens the wheel", symbol: "computermouse.fill"), on: screen)
        }
        updateButtonState()
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func pointerScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var pointerScreenCenter: CGPoint {
        let frame = Self.pointerScreen().visibleFrame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func openCentered(hint: Bool) {
        guard let controller, !controller.isOpen else { return }
        controller.open(at: pointerScreenCenter, mode: .sticky, hint: hint)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()

        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add("Open Wheel", #selector(openFromMenu))
        assignItem = add("Assign Button", #selector(assignButton))
        _ = add("Customize Wheel", #selector(customizeFromMenu))
        hapticsItem = add("Haptic Feedback", #selector(toggleHaptics))
        accessibilityItem = add("Allow Accessibility for Actions…", #selector(openAccessibility))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Gooey Wheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateButtonState()
    }

    @objc private func openFromMenu() {
        TriggerDebug.event("menu: Open Wheel")
        openCentered(hint: false)
    }

    @objc private func customizeFromMenu() {
        TriggerDebug.event("menu: Customize Wheel")
        controller?.customize(at: pointerScreenCenter)
    }

    @objc private func toggleHaptics() {
        MouseHaptics.enabled.toggle()
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityItem?.isHidden = AXIsProcessTrusted()
        hapticsItem?.isHidden = !MouseHaptics.supported
        hapticsItem?.state = MouseHaptics.enabled ? .on : .off
        updateButtonState()
    }

    /// A hub with six bubbles around it, drawn as a template image.
    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8)).fill()
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi + .pi / 2
                let p = CGPoint(x: c.x + 6.2 * cos(a), y: c.y + 6.2 * sin(a))
                NSBezierPath(ovalIn: CGRect(x: p.x - 1.9, y: p.y - 1.9, width: 3.8, height: 3.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct LaunchOptions {
    var demo = false
    var demoExit = false
    var stage: String?
    var timescale = 1.0
    var appearance: String?
    var iconPath: String?
    var demoScript = DemoScript.wheel
    /// Script time at which the demo cursor freezes, for stills of one moment.
    var demoStopAt: Double?
    var reduceMotion: Bool?
    /// Starts the demo with only this many items on the wheel, to see small rings.
    var demoRootCount: Int?
    /// Keeps the wheel in this file instead of Application Support, for testing.
    var storePath: String?
    /// False leaves the mouse alone, for testing.
    var thumbButton = true
    /// Writes an image of each named moment of the demo into this folder, without showing
    /// anything on screen, and quits. A pattern limits it to some of the moments. A stretch
    /// of the script, as "from,to,rate", writes that stretch frame by frame instead.
    var captureDirectory: String?
    var captureFilter: String?
    var captureFrames: (from: Double, to: Double, rate: Double)?
    /// Prints the demo stage's rectangle for `screencapture -R` and quits.
    var printStageRect = false
    /// Prints the configuration script's named moments and quits.
    var listDemoMarks = false

    init(arguments: [String]) {
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            let next = i + 1 < arguments.count ? arguments[i + 1] : nil
            switch arg {
            case "--demo": demo = true
            case "--demo-exit": demo = true; demoExit = true
            case "--stage": stage = next ?? "dark"; i += 1
            case "--timescale": timescale = next.flatMap(Double.init) ?? 1; i += 1
            case "--appearance": appearance = next; i += 1
            case "--render-icon": iconPath = next; i += 1
            case "--demo-script": demoScript = next.flatMap(DemoScript.init(rawValue:)) ?? .wheel; i += 1
            case "--reduce-motion": reduceMotion = true
            case "--demo-root-count": demoRootCount = next.flatMap(Int.init); i += 1
            case "--store": storePath = next; i += 1
            case "--no-thumb": thumbButton = false
            case "--demo-marks": listDemoMarks = true
            case "--demo-stage-rect": printStageRect = true
            case "--demo-capture": demo = true; captureDirectory = next; i += 1
            case "--demo-capture-filter": captureFilter = next; i += 1
            case "--demo-capture-frames":
                let parts = (next ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 3 { captureFrames = (parts[0], parts[1], parts[2]) }
                i += 1
            case "--demo-stop-at": demoStopAt = next.flatMap(Double.init); i += 1
            default: break
            }
            i += 1
        }
    }
}
