import AppKit

/// Reads a button of any mouse from the events macOS makes of its presses, through an event tap.
/// The button's presses and releases are taken out of the event stream, so it does nothing else
/// while it opens the wheel. Taking events out needs Accessibility.
///
/// Buttons are numbered as macOS numbers them: 0 is the left button, 1 the right, 2 the middle,
/// and the side buttons follow, usually 3 for back and 4 for forward. The left and right buttons
/// are never taken.
final class MouseButtonTap {
    /// What a button is called, by its macOS number.
    static func name(of button: Int) -> String {
        switch button {
        case 2: return "Middle Button"
        case 3: return "Back Button"
        case 4: return "Forward Button"
        default: return "Button \(button + 1)"
        }
    }

    /// The button read, or nil to read none.
    var button: Int? {
        didSet {
            guard button != oldValue else { return }
            if pressed { onChange?(false) }
            pressed = false
            update()
        }
    }

    /// Called with true when the button goes down and false when it comes up.
    var onChange: ((Bool) -> Void)?
    /// Called when the tap starts or stops working.
    var onStatus: (() -> Void)?

    /// Whether the tap is in place, which it can't be without Accessibility.
    var isRunning: Bool { tap != nil || !installs }
    var isCapturing: Bool { capture != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var pressed = false
    private var capture: ((Int?) -> Void)?
    /// A button pressed to be captured, whose release is taken too.
    private var capturedButton: Int?

    private var needed: Bool { button != nil || capture != nil || capturedButton != nil }
    /// False for one that never puts a tap in place, for the self-test, which hands it events.
    private let installs: Bool

    init(installs: Bool = true) {
        self.installs = installs
    }

    deinit {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
    }

    /// Waits for a press of any button other than the left and right buttons, and passes its
    /// number to `completion`. The press and its release do nothing else. Returns false, without
    /// calling `completion`, when the tap can't be put in place.
    @discardableResult
    func capturePress(completion: @escaping (Int?) -> Void) -> Bool {
        cancelCapture()
        capture = completion
        update()
        guard isRunning else {
            capture = nil
            update()
            return false
        }
        return true
    }

    /// Stops waiting for a press, passing nil to the waiting completion.
    func cancelCapture() {
        guard let completion = capture else { return }
        capture = nil
        update()
        completion(nil)
    }

    /// Puts the tap in place while something needs it, and takes it away otherwise. Without
    /// Accessibility it tries again every 2 seconds, so the button starts working soon after
    /// it's allowed.
    func update() {
        guard needed else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            stopRetrying()
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        guard installs else { return }
        guard install() else {
            scheduleRetry()
            return
        }
        stopRetrying()
        TriggerDebug.log("event tap installed for button \(button.map(String.init) ?? "none")")
        onStatus?()
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MouseButtonTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: context) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    private func stopRetrying() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// What the tap does with an event: nil takes it out of the stream.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            TriggerDebug.log("event tap disabled (\(type.rawValue)), turning it back on")
            if let tap, needed { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            break
        default:
            return pass
        }
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard number >= 2 else { return pass }

        if type == .otherMouseDown, let completion = capture {
            capture = nil
            capturedButton = number
            TriggerDebug.log("event tap captured button \(number)")
            DispatchQueue.main.async { completion(number) }
            return nil
        }
        if number == capturedButton {
            if type == .otherMouseUp {
                capturedButton = nil
                DispatchQueue.main.async { [weak self] in self?.update() }
            }
            return Self.taken(type, event)
        }

        guard number == button else { return pass }
        switch type {
        case .otherMouseDown where !pressed:
            pressed = true
            TriggerDebug.log("event tap: button \(number) down")
            DispatchQueue.main.async { [weak self] in self?.onChange?(true) }
        case .otherMouseUp where pressed:
            pressed = false
            TriggerDebug.log("event tap: button \(number) up")
            DispatchQueue.main.async { [weak self] in self?.onChange?(false) }
        default:
            break
        }
        return Self.taken(type, event)
    }

    /// What's left of a taken button's event: nothing for a press or release, and a plain move
    /// for a drag, so the app under the pointer sees it move without a drag it never saw start.
    private static func taken(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .otherMouseDragged else { return nil }
        event.type = .mouseMoved
        return Unmanaged.passUnretained(event)
    }
}

extension MouseButtonTap {
    /// Events are made here and handed to the tap's handler directly; none is posted, so the
    /// real pointer and the apps under it see nothing.
    static var tests: [SelfTest.Case] {
        func event(_ type: CGEventType, _ button: Int) -> CGEvent? {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            return event
        }
        return [
            SelfTest.Case("mouse.buttonNames") { ctx in
                try ctx.expect(name(of: 2) == "Middle Button" && name(of: 3) == "Back Button" && name(of: 4) == "Forward Button", "named buttons")
                try ctx.expect(name(of: 5) == "Button 6", "numbered from 1: \(name(of: 5))")
                try ctx.expect(ButtonAssignment.standard(3).name == "Back Button", "standard assignment")
                try ctx.expect(ButtonAssignment.logitech(LogiButton.thumbPanel).name == "Thumb Button", "Logitech assignment")
            },
            SelfTest.Case("mouse.eventTapTakesTheButton") { ctx in
                let tap = MouseButtonTap(installs: false)
                tap.button = 3
                defer { tap.button = nil }
                var changes: [Bool] = []
                tap.onChange = { changes.append($0) }
                let down = try ctx.expectValue(event(.otherMouseDown, 3), "no event")
                let drag = try ctx.expectValue(event(.otherMouseDragged, 3), "no event")
                let up = try ctx.expectValue(event(.otherMouseUp, 3), "no event")
                try ctx.expect(tap.handle(.otherMouseDown, down) == nil, "press passed on")
                try ctx.expect(tap.handle(.otherMouseDown, down) == nil, "repeated press passed on")
                let moved = tap.handle(.otherMouseDragged, drag)?.takeUnretainedValue()
                try ctx.expect(moved?.type == .mouseMoved, "drag became \(String(describing: moved?.type.rawValue))")
                try ctx.expect(tap.handle(.otherMouseUp, up) == nil, "release passed on")
                ctx.wait(0.05)
                try ctx.expect(changes == [true, false], "changes \(changes)")
                for (type, button) in [(CGEventType.otherMouseDown, 2), (.otherMouseUp, 4), (.otherMouseDragged, 2)] {
                    let other = try ctx.expectValue(event(type, button), "no event")
                    try ctx.expect(tap.handle(type, other) != nil, "button \(button) taken")
                }
                // Left and right are always passed on, whatever their number field says.
                let left = try ctx.expectValue(event(.otherMouseDown, 0), "no event")
                try ctx.expect(tap.handle(.otherMouseDown, left) != nil, "button 0 taken")
            },
            SelfTest.Case("mouse.eventTapInstalls") { ctx in
                guard Permissions.canPostEvents else { try ctx.skip("Accessibility not granted") }
                // Button 31 is on no mouse, so the tap passes every real event on.
                let tap = MouseButtonTap()
                tap.button = 31
                try ctx.expect(tap.isRunning, "the event tap wasn't created")
                tap.button = nil
            },
            SelfTest.Case("mouse.eventTapCaptures") { ctx in
                let tap = MouseButtonTap(installs: false)
                var captured: Int??
                try ctx.expect(tap.capturePress { captured = .some($0) }, "capture didn't start")
                let down = try ctx.expectValue(event(.otherMouseDown, 4), "no event")
                let up = try ctx.expectValue(event(.otherMouseUp, 4), "no event")
                let later = try ctx.expectValue(event(.otherMouseDown, 4), "no event")
                try ctx.expect(tap.handle(.otherMouseDown, down) == nil, "captured press passed on")
                try ctx.expect(tap.handle(.otherMouseUp, up) == nil, "captured release passed on")
                try ctx.expect(tap.handle(.otherMouseDown, later) != nil, "a later press taken")
                ctx.wait(0.05)
                try ctx.expect(captured == .some(4), "captured \(String(describing: captured))")
                try ctx.expect(!tap.isCapturing, "still capturing")
            },
        ]
    }
}
