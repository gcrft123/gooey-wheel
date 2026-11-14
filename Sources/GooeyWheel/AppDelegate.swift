import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let summonHotKey: UInt32 = 1
    private static let parentStyleKey = "parentStyle"

    private var controller: WheelController?
    private var statusItem: NSStatusItem?
    private enum Trigger { case thumb, hotKey }
    /// Each trigger keeps its own held state, so a release one of them loses (the mouse can drop
    /// one) never makes the other ignore its presses.
    private var heldTriggers = Set<Trigger>()
    private let thumb = LogiButton(controlID: LogiButton.thumbPanel)
    private var thumbItem: NSMenuItem?
    /// Shown while the app lacks Accessibility, which shortcuts, typing, and window actions need.
    private var accessibilityItem: NSMenuItem?
    /// The haptics switch and the separator after it, shown only for a mouse with a haptic motor.
    private var hapticsItems: [NSMenuItem] = []
    private let options: LaunchOptions

    init(options: LaunchOptions) {
        self.options = options
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
        controller.parentStyle = options.parentStyle
            ?? ParentStyle(rawValue: UserDefaults.standard.string(forKey: Self.parentStyleKey) ?? "") ?? .shrink

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
        HotKeyCenter.shared.register(id: Self.summonHotKey, keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] pressed in
            self?.trigger(.hotKey, pressed)
        }
        if options.thumbButton { startThumbButton() }

        // Open once at launch so there's something on screen, with how to summon it shown underneath.
        // The delay gives the mouse time to answer, so the hint names the right trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.openCentered(hint: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutomationActions.restoreClipboard()
        thumb.stop()
    }

    /// The thumb button and the keyboard shortcut behave the same way. A quick press opens the
    /// wheel and leaves it open; holding keeps it open until release, which picks whatever the
    /// cursor is on. Pressing again while it's open closes it.
    /// `missed` marks a release the mouse never reported, recovered at the next press.
    private func trigger(_ source: Trigger, _ pressed: Bool, missed: Bool = false) {
        guard let controller else { return }
        if pressed {
            guard heldTriggers.insert(source).inserted else {
                TriggerDebug.event("\(source) press IGNORED, already held")
                return
            }
            if controller.isOpen {
                TriggerDebug.event("\(source) press → close")
                controller.dismiss()
            } else {
                TriggerDebug.event("\(source) press → open")
                controller.open(mode: .held)
            }
        } else {
            guard heldTriggers.remove(source) != nil else {
                TriggerDebug.event("\(source) release IGNORED, wasn't held")
                return
            }
            TriggerDebug.event("\(source) release\(missed ? " (recovered)" : "")")
            controller.triggerReleased(missed: missed)
        }
    }

    private func startThumbButton() {
        thumb.onChange = { [weak self] pressed in self?.trigger(.thumb, pressed) }
        thumb.onMissedRelease = { [weak self] in self?.trigger(.thumb, false, missed: true) }
        thumb.onStatus = { [weak self] _ in self?.updateThumbItem() }
        thumb.onNeedsRelaunch = {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", Bundle.main.bundleURL.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
        MouseLink.shared.use(thumb)
        thumb.start()
        updateThumbItem()

        // Other software can hand the button back to the mouse, so claim it again when the
        // frontmost app changes and when the Mac wakes.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.thumb.reassert() }
            }
        }
    }

    private func updateThumbItem() {
        guard let controller else { return }
        switch thumb.status {
        case .ready(let name):
            thumbItem?.title = "Thumb Button: \(name)"
            thumbItem?.action = nil
            controller.hintText = "Press the thumb button to open"
        case .needsPermission:
            thumbItem?.title = "Allow Input Monitoring for the Thumb Button…"
            thumbItem?.action = #selector(openInputMonitoring)
            controller.hintText = "Hold ⌃⌥Space to open"
        case .searching:
            thumbItem?.title = "Thumb Button: No Mouse Found"
            thumbItem?.action = nil
            controller.hintText = "Hold ⌃⌥Space to open"
        }
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openCentered(hint: Bool) {
        guard let controller, !controller.isOpen else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        controller.open(at: CGPoint(x: frame.midX, y: frame.midY), mode: .sticky, hint: hint)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Wheel", action: #selector(openFromMenu), keyEquivalent: " ")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)
        let thumbItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        thumbItem.target = self
        menu.addItem(thumbItem)
        self.thumbItem = thumbItem
        let accessibility = NSMenuItem(title: "Allow Accessibility for Actions…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        accessibilityItem = accessibility
        menu.addItem(.separator())
        let haptics = NSMenuItem(title: "Mouse Haptic Feedback", action: #selector(toggleHaptics), keyEquivalent: "")
        haptics.target = self
        let hapticsSeparator = NSMenuItem.separator()
        menu.addItem(haptics)
        menu.addItem(hapticsSeparator)
        hapticsItems = [haptics, hapticsSeparator]
        let heading = NSMenuItem(title: "Parent Ring in Folders", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (title, style) in [("Shrink", ParentStyle.shrink), ("Hide", ParentStyle.hide)] {
            let item = NSMenuItem(title: title, action: #selector(chooseParentStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Quit Gooey Wheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openFromMenu() {
        TriggerDebug.event("menu: Open Wheel")
        openCentered(hint: false)
    }

    @objc private func chooseParentStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = ParentStyle(rawValue: raw) else { return }
        controller?.parentStyle = style
        UserDefaults.standard.set(raw, forKey: Self.parentStyleKey)
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
        for item in hapticsItems { item.isHidden = !MouseHaptics.supported }
        hapticsItems.first?.state = MouseHaptics.enabled ? .on : .off
        for item in menu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = raw == controller?.parentStyle.rawValue ? .on : .off
        }
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
    var parentStyle: ParentStyle?
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
            case "--parent": parentStyle = next.flatMap(ParentStyle.init(rawValue:)); i += 1
            default: break
            }
            i += 1
        }
    }
}
