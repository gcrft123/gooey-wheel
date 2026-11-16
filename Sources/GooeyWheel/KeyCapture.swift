import AppKit
import Carbon.HIToolbox

/// Takes key presses from the session before the window server matches them against
/// shortcuts: the system's, such as ⌘Space or ⌃→, and other apps' global hotkeys. The
/// keystroke recorder uses it so a combination it records isn't also run. Needs
/// Accessibility, or Input Monitoring in the App Store edition (`Permissions.canTapKeys`);
/// without it `start` returns false and keys reach the panel as usual.
final class KeyCapture {
    /// Offered each key-down. Returns whether it took the press; a taken press, and its
    /// release, go no further.
    private let take: (NSEvent) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose press was taken, so their release is taken too.
    private var held: Set<Int64> = []

    init(take: @escaping (NSEvent) -> Bool) {
        self.take = take
    }

    deinit { stop() }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyCapture>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: context) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        held.removeAll()
    }

    /// What the tap does with an event: nil takes it out of the stream.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            guard let ns = NSEvent(cgEvent: event), take(ns) else { return pass }
            held.insert(key)
            return nil
        case .keyUp:
            return held.remove(key) == nil ? pass : nil
        default:
            return pass
        }
    }
}

extension KeyCapture {
    /// A global hotkey of this process stands in for a system shortcut: both are matched by
    /// the window server. Its combination is one nobody types, and the recorder sits in a
    /// panel behind the desktop picture, so nothing reaches the apps in use.
    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("keys.recorderBeatsHotKeys") { ctx in
                guard Permissions.canTapKeys else { try ctx.skip(Permissions.canPostEvents ? "Input Monitoring not granted" : "Accessibility not granted") }
                let combo = KeyCombo(kVK_PageDown, [.maskControl, .maskAlternate, .maskShift, .maskCommand])
                var fired = 0
                let id: UInt32 = 90
                try ctx.expect(HotKeyCenter.shared.register(id: id, keyCode: kVK_PageDown, modifiers: controlKey | optionKey | shiftKey | cmdKey) { if $0 { fired += 1 } },
                               "couldn't register ⌃⌥⇧⌘⇟")
                defer { HotKeyCenter.shared.unregister(id: id) }

                // Nothing recording: the hotkey runs.
                ctx.textTarget.text = ""
                KeySender.post(KeySender.events(for: combo))
                ctx.wait(upTo: 1) { fired > 0 }
                try ctx.expect(fired == 1, "hotkey fired \(fired) times with nothing recording")

                let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
                let recorder = ParameterView.make(.keystroke, value: nil, theme: EditorTheme(GooStyle.resolve(dark: false, accent: .controlAccentColor)))
                recorder.frame = panel.contentLayoutRect
                panel.contentView?.addSubview(recorder)
                defer { panel.orderOut(nil) }
                var recorded: [String?] = []
                recorder.onChange = { recorded.append($0) }
                panel.orderFrontRegardless()
                panel.makeKey()
                recorder.focus()
                try ctx.expect(NSApp.keyWindow === panel && panel.firstResponder === recorder, "recorder isn't focused")

                // Recording: the recorder takes the press and the hotkey never sees it.
                KeySender.post(KeySender.events(for: combo))
                ctx.wait(upTo: 1) { !recorded.isEmpty }
                ctx.wait(0.3)
                try ctx.expect(recorded == ["⌃⌥⇧⌘⇟"], "recorded \(recorded)")
                try ctx.expect(fired == 1, "hotkey fired while recording")

                // Focus moved on: keys pass again.
                panel.makeFirstResponder(nil)
                KeySender.post(KeySender.events(for: combo))
                ctx.wait(upTo: 1) { fired > 1 }
                try ctx.expect(fired == 2 && recorded.count == 1, "after recording: fired \(fired), recorded \(recorded)")
            },
        ]
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
