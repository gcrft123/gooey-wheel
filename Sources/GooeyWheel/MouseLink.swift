import Foundation

/// The HID++ 2.0 features the app uses besides the button's, by ID.
enum HIDPPFeature {
    static let unifiedBattery: UInt16 = 0x1004
    static let changeHost: UInt16 = 0x1814
    static let hostsInfo: UInt16 = 0x1815
    static let haptic: UInt16 = 0x19B0
    static let smartShift: UInt16 = 0x2111
    static let hiResWheel: UInt16 = 0x2121
    static let thumbWheel: UInt16 = 0x2150
    static let adjustableDPI: UInt16 = 0x2201
}

/// The connected Logitech mouse, for everything other than the thumb button. It talks through the
/// links of the `LogiButton` that opened the mouse, so there is one owner of the device and one
/// queue of requests.
///
/// Every HID++ request has a cost: for up to 4 seconds after one, the mouse sends its
/// notifications here instead of to Logi Options+, which stops Options+'s scrolling and gestures.
/// Ask only when something needs reading.
final class MouseLink {
    static let shared = MouseLink()

    private var button: LogiButton?
    /// Collects the requests `post` would send, without sending them, for the self-test.
    var interceptPosts: (([UInt8]) -> Void)?

    /// Talks to the mouse through `button`, the one the app reads the thumb button with.
    func use(_ button: LogiButton) {
        self.button = button
        button.onLinksChanged = { MouseState.shared.mouseChanged() }
        button.onNotification = { [weak self] link, feature, event, params in
            guard link === self?.mouse else { return }
            MouseWheelEvents.handle(feature, event, params)
            MouseState.shared.notified(feature, event, params)
        }
    }

    /// Opens the mouse without reading any button, for the self-test, unless something already has.
    func startWithoutButton() {
        guard button == nil else { return }
        let button = LogiButton.withoutButton()
        use(button)
        button.start()
    }

    /// The mouse, once it has connected and its features are known.
    var mouse: LogiLink? {
        button?.links.first { $0.isMouse && $0.featuresKnown }
    }

    func has(_ feature: UInt16) -> Bool {
        mouse?.has(feature) == true
    }

    /// Sends a request and passes the reply's parameter bytes to `completion`, or nil.
    func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], completion: @escaping ([UInt8]?) -> Void) {
        guard let mouse else {
            completion(nil)
            return
        }
        mouse.call(feature, function, params, completion: completion)
    }

    /// Sends a request without waiting for an answer, such as one the mouse never answers.
    func post(_ feature: UInt16, _ function: UInt8, _ params: [UInt8]) {
        guard let mouse, let index = mouse.features[feature], index != 0 else { return }
        if let interceptPosts {
            interceptPosts(LogiLink.frame(index: mouse.index, feature: index, function: function, params: params))
            return
        }
        mouse.post(feature, function, params)
    }

    /// Sends a request over the Bluetooth channel Logi Options+ uses, without waiting for an
    /// answer, so the mouse goes on sending its notifications to Options+. Returns whether it was
    /// sent: it isn't when the app hasn't found that channel, such as without Bluetooth permission.
    @discardableResult
    func postOverBluetooth(_ feature: UInt16, _ function: UInt8, _ params: [UInt8]) -> Bool {
        guard let mouse, let index = mouse.features[feature], index != 0 else { return false }
        if let interceptPosts {
            interceptPosts(LogiLink.frame(feature: index, function: function, params: params))
            return true
        }
        return mouse.postOverBluetooth(feature, function, params)
    }
}

/// Movements of the mouse's wheels that reach this app as HID++ notifications.
///
/// Logi Options+ diverts both wheels, so they report over HID++ and Options+ turns that into
/// scrolling. The mouse sends those reports to whichever channel last made a HID++ request. They
/// come here, read from both channels, either way, but when this app made the last request
/// Options+ gets none and no scroll events are posted, for up to 4 seconds. A slider that wants
/// the wheel should therefore take these while they arrive and ignore scroll events meanwhile,
/// so a notch isn't counted twice.
enum MouseWheelEvents {
    /// Called on the main thread with each movement, in notches. `vertical` is positive when the
    /// top of the main wheel rolls away from the user, whatever the scroll-direction setting.
    /// `horizontal` is positive when the thumb wheel turns the way the mouse calls right; a full
    /// turn of it counts as many notches as a full turn of the main wheel.
    static var onWheel: ((_ vertical: Double, _ horizontal: Double) -> Void)?
    /// When the last movement arrived, in system uptime.
    private(set) static var lastEvent: TimeInterval = -.infinity

    /// Main-wheel counts per notch in high resolution, from 0x2121's capabilities.
    static var countsPerNotch: Double = 15
    /// Thumb-wheel counts per notch while diverted, from 0x2150's info.
    static var thumbCountsPerNotch: Double = 5
    /// 1 when the thumb wheel's positive rotation is to the right, -1 when it is to the left.
    static var thumbRightSign: Double = -1

    /// Whether wheel reports have arrived in the last `seconds`, so scroll events can be ignored.
    static func isActive(within seconds: TimeInterval = 0.5) -> Bool {
        ProcessInfo.processInfo.systemUptime - lastEvent < seconds
    }

    static func handle(_ feature: UInt16, _ event: UInt8, _ params: [UInt8]) {
        guard event == 0 else { return }
        let movement: (Double, Double)?
        switch feature {
        case HIDPPFeature.hiResWheel: movement = vertical(params).map { ($0, 0) }
        case HIDPPFeature.thumbWheel: movement = horizontal(params).map { (0, $0) }
        default: movement = nil
        }
        guard let movement, movement != (0, 0) else { return }
        lastEvent = ProcessInfo.processInfo.systemUptime
        onWheel?(movement.0, movement.1)
    }

    /// 0x2121 event 0: a flags byte (bit 4 set when the count is in high resolution), then the
    /// movement as a signed 16-bit count, positive up.
    static func vertical(_ params: [UInt8]) -> Double? {
        guard params.count >= 3 else { return nil }
        let count = Double(Int16(bitPattern: UInt16(params[1]) << 8 | UInt16(params[2])))
        return params[0] & 0x10 != 0 ? count / countsPerNotch : count
    }

    /// 0x2150 event 0: the rotation as a signed 16-bit count, a timestamp, and a status.
    static func horizontal(_ params: [UInt8]) -> Double? {
        guard params.count >= 2 else { return nil }
        let count = Double(Int16(bitPattern: UInt16(params[0]) << 8 | UInt16(params[1])))
        return count * thumbRightSign / thumbCountsPerNotch
    }
}
