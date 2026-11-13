import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let summonHotKey: UInt32 = 1
    private static let parentStyleKey = "parentStyle"

    private var controller: WheelController?
    private var statusItem: NSStatusItem?
    private var triggerIsDown = false
    private let thumb = LogiButton(controlID: LogiButton.thumbPanel)
    private var thumbItem: NSMenuItem?
    private let options: LaunchOptions

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = options.appearance {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        guard let renderer = GooRenderer(), let controller = WheelController(renderer: renderer) else {
            NSLog("Metal is unavailable.")
            NSApp.terminate(nil)
            return
        }
        self.controller = controller
        controller.timescale = options.timescale
        controller.parentStyle = options.parentStyle
            ?? ParentStyle(rawValue: UserDefaults.standard.string(forKey: Self.parentStyleKey) ?? "") ?? .shrink

        if options.demo {
            controller.stage = options.stage
            controller.startDemo(DemoDriver(exitWhenDone: options.demoExit))
            return
        }

        installStatusItem()
        HotKeyCenter.shared.register(id: Self.summonHotKey, keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] pressed in
            self?.trigger(pressed)
        }
        startThumbButton()

        // Open once at launch so there's something on screen, with how to summon it shown underneath.
        // The delay gives the mouse time to answer, so the hint names the right trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.openCentered(hint: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        thumb.stop()
    }

    /// The thumb button and the keyboard shortcut behave the same way. A quick press opens the
    /// wheel and leaves it open; holding keeps it open until release, which picks whatever the
    /// cursor is on. Pressing again while it's open closes it.
    private func trigger(_ pressed: Bool) {
        guard let controller else { return }
        if pressed {
            guard !triggerIsDown else { return }
            triggerIsDown = true
            if controller.isOpen {
                controller.dismiss()
            } else {
                controller.open(mode: .held)
            }
        } else {
            guard triggerIsDown else { return }
            triggerIsDown = false
            controller.triggerReleased()
        }
    }

    private func startThumbButton() {
        thumb.onChange = { [weak self] pressed in self?.trigger(pressed) }
        thumb.onStatus = { [weak self] _ in self?.updateThumbItem() }
        thumb.onNeedsRelaunch = {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", Bundle.main.bundleURL.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
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
        menu.addItem(.separator())
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
        openCentered(hint: false)
    }

    @objc private func chooseParentStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = ParentStyle(rawValue: raw) else { return }
        controller?.parentStyle = style
        UserDefaults.standard.set(raw, forKey: Self.parentStyleKey)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
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
            case "--parent": parentStyle = next.flatMap(ParentStyle.init(rawValue:)); i += 1
            default: break
            }
            i += 1
        }
    }
}
