import AppKit

/// The mouse button that opens the wheel.
enum ButtonAssignment: Equatable {
    /// A button of a Logitech mouse, by HID++ control ID, read from the mouse itself.
    case logitech(UInt16)
    /// A button any mouse reports to macOS, by its number: 2 is the middle button.
    case standard(Int)

    /// The HID++ control ID, saved under `logitechKey` for compatibility with earlier versions.
    private static let logitechKey = "button"
    private static let standardKey = "mouseButton"

    /// The assignment saved, or nil when the user hasn't assigned a button.
    static var saved: ButtonAssignment? {
        get {
            let defaults = UserDefaults.standard
            if let number = defaults.object(forKey: standardKey) as? Int { return .standard(number) }
            if let control = defaults.object(forKey: logitechKey) as? Int { return .logitech(UInt16(truncatingIfNeeded: control)) }
            return nil
        }
        set {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: standardKey)
            defaults.removeObject(forKey: logitechKey)
            switch newValue {
            case .logitech(let control): defaults.set(Int(control), forKey: logitechKey)
            case .standard(let number): defaults.set(number, forKey: standardKey)
            case nil: break
            }
        }
    }

    var name: String {
        switch self {
        case .logitech(let control): return LogiButton.name(of: control) ?? "Assigned Button"
        case .standard(let number): return MouseButtonTap.name(of: number)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Seconds Assign Button waits for a press.
    private static let captureTimeout: TimeInterval = 15

    private var controller: WheelController?
    private var statusItem: NSStatusItem?
    /// Set between a press of the button and its release. A Logitech mouse can drop a release,
    /// which `LogiButton` recovers at the next press.
    private var buttonHeld = false
    /// Nil until the user assigns a button. Until then a Logitech mouse's thumb button opens the
    /// wheel, on a mouse that has one.
    private var assignment = ButtonAssignment.saved
    /// Reads a Logitech mouse over HID++, for its buttons and for the mouse actions and haptics.
    private let logitech: LogiButton
    /// Reads a button of any mouse from macOS's events.
    private let standard = MouseButtonTap()
    private var assignItem: NSMenuItem?
    private var hapticsItem: NSMenuItem?
    /// Shown while the app lacks Accessibility, which shortcuts, typing, and window actions need.
    private var accessibilityItem: NSMenuItem?
    private let options: LaunchOptions
    /// Set once the welcome panel has been closed, so it shows only on the first launch.
    private static let welcomedKey = "welcomed"
    private var welcome: WelcomePanel?
    /// Set while the welcome panel's button page is up, which waits for presses throughout.
    private var welcomeListening = false
    private var welcomeTimer: Timer?

    init(options: LaunchOptions) {
        self.options = options
        switch assignment {
        case .logitech(let control): logitech = LogiButton(controlID: control)
        case .standard: logitech = LogiButton(controlID: nil)
        case nil: logitech = LogiButton(controlID: LogiButton.thumbPanel)
        }
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
        controller.accent = options.accent.flatMap(ItemColor.init(hex:)).map { NSColor(srgbRed: CGFloat($0.rgb.x), green: CGFloat($0.rgb.y), blue: CGFloat($0.rgb.z), alpha: 1) }

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
        if options.readsMouse { startButton() }

        // The first launch shows the welcome panel, which opens the wheel when it closes.
        if options.showsWelcome || !UserDefaults.standard.bool(forKey: Self.welcomedKey) {
            showWelcome()
            return
        }
        // Open once at launch so there's something on screen, with how to summon it shown underneath.
        // The delay gives the mouse time to answer, so the hint names the right trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.openCentered(hint: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutomationActions.restoreClipboard()
        logitech.stop()
    }

    /// A quick press opens the wheel and leaves it open; holding keeps it open until release,
    /// which picks whatever the cursor is on. Pressing again while it's open closes it.
    /// `missed` marks a release a Logitech mouse never reported, recovered at the next press.
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
        logitech.onChange = { [weak self] pressed in self?.buttonChanged(pressed) }
        logitech.onMissedRelease = { [weak self] in self?.buttonChanged(false, missed: true) }
        logitech.onStatus = { [weak self] _ in self?.updateButtonState() }
        logitech.onNeedsRelaunch = {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", Bundle.main.bundleURL.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
        MouseLink.shared.use(logitech)
        logitech.start()
        standard.onChange = { [weak self] pressed in self?.buttonChanged(pressed) }
        standard.onStatus = { [weak self] in self?.updateButtonState() }
        if case .standard(let number) = assignment { standard.button = number }
        updateButtonState()

        // Other software can hand the button back to the mouse, so claim it again when the
        // frontmost app changes and when the Mac wakes.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.logitech.reassert() }
            }
        }
    }

    /// The menu's Assign Button item and the hint under the wheel at launch, from the state of
    /// the assigned button.
    private func updateButtonState() {
        guard let controller, let item = assignItem else { return }
        item.isHidden = !options.readsMouse
        item.title = "Assign Button"
        item.action = #selector(assignButton)
        item.isEnabled = true
        accessibilityItem?.isHidden = AXIsProcessTrusted()
        updateWelcome()
        let assignHint = "Assign a mouse button in the menu bar"
        if waitingForPress {
            Self.setSubtitle(item, "Press a mouse button…")
            return
        }
        switch assignment {
        case .standard(let number):
            let name = MouseButtonTap.name(of: number)
            if standard.isRunning {
                Self.setSubtitle(item, name)
                controller.hintText = "Press the \(name.lowercased()) to open"
            } else {
                // The tap needs Accessibility. This item asks for it, so the other doesn't.
                item.title = "Allow Accessibility…"
                Self.setSubtitle(item, name)
                item.action = #selector(openAccessibility)
                accessibilityItem?.isHidden = true
                controller.hintText = "Allow Accessibility to use the \(name.lowercased())"
            }
        case .logitech, nil:
            let name = assignment?.name ?? LogiButton.name(of: LogiButton.thumbPanel) ?? ""
            switch logitech.status {
            case .ready:
                Self.setSubtitle(item, name)
                controller.hintText = "Press the \(name.lowercased()) to open"
            case .needsPermission:
                item.title = "Allow Input Monitoring…"
                Self.setSubtitle(item, nil)
                item.action = #selector(openInputMonitoring)
                controller.hintText = "Allow Input Monitoring to use your mouse"
            case .searching:
                // The thumb button is only a default for the mice that have one.
                Self.setSubtitle(item, assignment == nil ? nil : "\(name) not found")
                controller.hintText = assignHint
            }
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

    /// Set while Assign Button waits for a press.
    private var waitingForPress = false
    private var captureTimer: Timer?
    /// Called with the button pressed, or nil when the wait ends without one.
    private var captureCompletion: ((ButtonAssignment?) -> Void)?

    /// Waits for a press of any mouse button but the left and right ones. A Logitech mouse is
    /// asked for its buttons over HID++; any other button is read from macOS's events, which
    /// needs Accessibility. Returns false, without calling `completion`, when neither can read
    /// a press. A wait already going ends first, with nil.
    private func capturePress(timeout: TimeInterval, _ completion: @escaping (ButtonAssignment?) -> Void) -> Bool {
        finishCapture(nil)
        captureCompletion = completion
        let standardCaptures = standard.capturePress { [weak self] number in
            self?.finishCapture(number.map(ButtonAssignment.standard))
        }
        if logitech.canCapture {
            logitech.capturePress(timeout: timeout) { [weak self] control in
                self?.finishCapture(control.map(ButtonAssignment.logitech))
            }
        }
        guard standardCaptures || logitech.isCapturing else {
            captureCompletion = nil
            return false
        }
        return true
    }

    private func finishCapture(_ pressed: ButtonAssignment?) {
        guard let completion = captureCompletion else { return }
        captureCompletion = nil
        // Whichever reader didn't catch the press stops waiting. Its completion comes back here
        // with nil and finds nothing left to do.
        logitech.cancelCapture()
        standard.cancelCapture()
        completion(pressed)
    }

    /// Waits for a press and assigns the button pressed.
    @objc private func assignButton() {
        guard let controller else { return }
        TriggerDebug.event("menu: Assign Button")
        let screen = Self.pointerScreen()
        // Choosing it again while it waits starts the wait over.
        let started = capturePress(timeout: Self.captureTimeout) { [weak self] pressed in
            self?.endCapture(pressed, on: screen)
        }
        guard started else {
            openAccessibility()
            return
        }
        waitingForPress = true
        if controller.isOpen { controller.dismiss() }
        let text = standard.isCapturing ? "Press a mouse button" : "Press a button on \(logitech.mouseName ?? "the mouse")"
        controller.announce(Toast.Message(text: text, symbol: "computermouse", lasts: Self.captureTimeout), on: screen)
        captureTimer = Timer.scheduledTimer(withTimeInterval: Self.captureTimeout, repeats: false) { [weak self] _ in
            self?.finishCapture(nil)
        }
        updateButtonState()
    }

    /// Assigns the button Assign Button caught, if any.
    private func endCapture(_ pressed: ButtonAssignment?, on screen: NSScreen) {
        waitingForPress = false
        captureTimer?.invalidate()
        captureTimer = nil
        defer { updateButtonState() }
        guard let controller else { return }
        guard let pressed else {
            controller.withdrawAnnouncement()
            return
        }
        assign(pressed)
        controller.announce(Toast.Message(text: "\(pressed.name) opens the wheel", symbol: "computermouse.fill"), on: screen)
    }

    private func assign(_ new: ButtonAssignment) {
        assignment = new
        ButtonAssignment.saved = new
        switch new {
        case .logitech(let control):
            standard.button = nil
            logitech.assign(control)
        case .standard(let number):
            logitech.assign(nil)
            standard.button = number
        }
    }

    // MARK: Welcome

    private func showWelcome() {
        let panel = WelcomePanel()
        panel.onButtonPage = { [weak self] shown in
            if shown { self?.startWelcomeListening() } else { self?.stopWelcomeListening() }
        }
        panel.onAllow = { [weak self] permission in
            switch permission {
            case .accessibility: self?.openAccessibility()
            case .inputMonitoring: self?.openInputMonitoring()
            }
        }
        panel.onClose = { [weak self] point in self?.welcomeClosed(at: point) }
        welcome = panel
        updateWelcome()
        panel.show()
    }

    /// While the button page is up, every press of a mouse button other than the left and right
    /// ones assigns it. Permissions allowed meanwhile take effect within a second.
    private func startWelcomeListening() {
        // A copy that leaves the mouse alone for testing doesn't take its buttons either.
        guard options.readsMouse else { return }
        welcomeListening = true
        listenForWelcome()
        welcomeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.listenForWelcome()
            self?.updateWelcome()
        }
    }

    /// Starts waiting again when a reader that could take the press isn't waiting: after a
    /// press, after a wait times out, or once a permission or a Logitech mouse arrives.
    private func listenForWelcome() {
        guard welcomeListening, !waitingForPress else { return }
        let standardIdle = AXIsProcessTrusted() && !standard.isCapturing
        let logitechIdle = logitech.canCapture && !logitech.isCapturing
        guard standardIdle || logitechIdle else { return }
        _ = capturePress(timeout: 600) { [weak self] pressed in
            guard let self, let pressed else { return }
            self.assign(pressed)
            self.updateWelcome(assigned: true)
            self.updateButtonState()
            self.listenForWelcome()
        }
    }

    private func stopWelcomeListening() {
        guard welcomeListening else { return }
        welcomeListening = false
        welcomeTimer?.invalidate()
        welcomeTimer = nil
        if !waitingForPress { finishCapture(nil) }
    }

    private func updateWelcome(assigned: Bool = false) {
        guard let welcome else { return }
        var missing: [WelcomePanel.Permission] = []
        if !AXIsProcessTrusted() { missing.append(.accessibility) }
        if logitech.status == .needsPermission { missing.append(.inputMonitoring) }
        let name: String?
        switch assignment {
        case .some(let assigned): name = assigned.name
        // A Logitech mouse's thumb button opens the wheel until a button is assigned, on a
        // mouse that has one.
        case nil:
            if case .ready = logitech.status { name = LogiButton.name(of: LogiButton.thumbPanel) } else { name = nil }
        }
        welcome.update(WelcomePanel.ButtonState(name: name, missing: missing), assigned: assigned)
    }

    /// The panel has drawn in to a hub at `point`, and the wheel opens there.
    private func welcomeClosed(at point: CGPoint) {
        stopWelcomeListening()
        welcome = nil
        UserDefaults.standard.set(true, forKey: Self.welcomedKey)
        updateButtonState()
        guard let controller, !controller.isOpen else { return }
        controller.open(at: point, mode: .sticky, hint: true, formed: true)
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
    /// A hex color the demo uses in place of the system's accent color.
    var accent: String?
    /// Starts the demo with only this many items on the wheel, to see small rings.
    var demoRootCount: Int?
    /// Keeps the wheel in this file instead of Application Support, for testing.
    var storePath: String?
    /// False leaves the mouse alone, for testing.
    var readsMouse = true
    /// Writes an image of each named moment of the demo into this folder, without showing
    /// anything on screen, and quits. A pattern limits it to some of the moments. A stretch
    /// of the script, as "from,to,rate", writes that stretch frame by frame instead.
    var captureDirectory: String?
    var captureFilter: String?
    var captureFrames: (from: Double, to: Double, rate: Double)?
    /// Shows the welcome panel even when it has been closed before.
    var showsWelcome = false
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
            case "--accent": accent = next; i += 1
            case "--demo-root-count": demoRootCount = next.flatMap(Int.init); i += 1
            case "--store": storePath = next; i += 1
            case "--no-mouse", "--no-thumb": readsMouse = false
            case "--demo-marks": listDemoMarks = true
            case "--welcome": showsWelcome = true
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
