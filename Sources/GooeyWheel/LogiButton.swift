import Foundation
import IOKit.hid

/// Reads one button of a Logitech mouse straight from the device over HID++ 2.0. It doesn't go
/// through Logi Options+ and works whether or not Options+ is running.
///
/// The mouse is asked to "divert" the button: instead of performing its built-in function, it
/// sends a notification listing which diverted buttons are down. That gives a press and a release,
/// which a keyboard shortcut assigned in Options+ doesn't.
///
/// A mouse connected by Bluetooth is opened directly. One behind a receiver, such as Bolt, is
/// reached through the receiver's HID++ interface (see `LogiReceiver`).
final class LogiButton {
    enum Status: Equatable {
        case searching
        /// macOS is withholding the device until the app is allowed under Input Monitoring.
        case needsPermission
        case ready(String)
    }

    /// The MX Master 4's thumb panel.
    static let thumbPanel: UInt16 = 0x01A0

    /// What a button is called, by its HID++ control ID, for the ones that have a common name.
    static func name(of control: UInt16) -> String? {
        switch control {
        case 0x0052: return "Middle Button"
        case 0x0053: return "Back Button"
        case 0x0056: return "Forward Button"
        case 0x005B: return "Wheel Tilt Left"
        case 0x005D: return "Wheel Tilt Right"
        case 0x00C3: return "Gesture Button"
        case 0x00C4: return "Wheel Mode Button"
        case thumbPanel: return "Thumb Button"
        default: return nil
        }
    }

    /// One that reads no button and only carries requests to the mouse, for the self-test.
    static func withoutButton() -> LogiButton { LogiButton(controlID: nil) }

    /// Called with true when the button goes down and false when it comes up.
    var onChange: ((Bool) -> Void)?
    /// Called in place of `onChange(false)` for a release the mouse never reported, recovered
    /// when the next press arrives. When the button actually came up isn't known.
    var onMissedRelease: (() -> Void)?
    var onStatus: ((Status) -> Void)?
    /// Called when access has been granted but macOS still refuses the device, which a fresh
    /// launch of the app clears.
    var onNeedsRelaunch: (() -> Void)?
    /// Called when a mouse has finished connecting, once its features are known, and when one goes.
    var onLinksChanged: (() -> Void)?
    /// Called with each HID++ notification from a feature other than the button's, from either
    /// channel: the link, the feature's ID, the event number, and the event's parameter bytes.
    var onNotification: ((LogiLink, UInt16, UInt8, [UInt8]) -> Void)?
    private(set) var status = Status.searching {
        didSet {
            guard status != oldValue else { return }
            TriggerDebug.log("link status \(status)")
            onStatus?(status)
        }
    }

    /// The button read, or nil to read none.
    fileprivate(set) var controlID: UInt16?
    private let manager: IOHIDManager
    private(set) var links: [LogiLink] = []
    private var receivers: [LogiReceiver] = []
    private let vendor = VendorChannel()
    private var unopened: [IOHIDDevice] = []
    private var retryTimer: Timer?
    private var reportedFailure = false
    private var askedForRelaunch = false

    init(controlID: UInt16?) {
        self.controlID = controlID
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        let matching: [[String: Any]] = [
            // HID++ over Bluetooth is a vendor-defined collection on the mouse's own HID device.
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: Self.bluetoothPage, kIOHIDDeviceUsageKey: Self.bluetoothUsage],
            // A receiver has an interface of its own for HID++, whose long reports are this usage.
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF00, kIOHIDDeviceUsageKey: 0x0002],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LogiButton>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LogiButton>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        vendor.onMessage = { [weak self] name, report in
            for link in self?.links ?? [] where link.index == LogiLink.direct && link.name == name { link.handleVendor(report) }
        }
    }

    /// Asks the mouse to divert the button again. Other software can switch it back, so this runs
    /// whenever the frontmost app changes and after sleep.
    func reassert() {
        TriggerDebug.log("reassert divert on \(links.filter(\.ready).count) link(s)")
        for link in links where link.ready { link.divert() }
    }

    /// Sends a HID++ report to `link`'s device over Logitech's Bluetooth characteristic.
    fileprivate func writeVendor(_ report: [UInt8], for link: LogiLink) -> Bool {
        vendor.write(report, to: link.name)
    }

    /// Hands the button back to the mouse if this app was the one that took it.
    func stop() {
        for link in links { link.restore() }
    }

    private static let bluetoothPage: UInt32 = 0xFF43
    private static let bluetoothUsage: UInt32 = 0x0202

    /// Reads `control` from now on, or no button when it's nil, and hands the button read until
    /// now back to the mouse.
    func assign(_ control: UInt16?) {
        guard control != controlID else { return }
        let old = controlID
        controlID = control
        for link in links { link.reassign(from: old) }
        refreshStatus()
    }

    /// Whether a connected mouse can report presses of its other buttons, for `capturePress`.
    var canCapture: Bool { links.contains { $0.canCapture } }
    var isCapturing: Bool { capture != nil }
    /// The name of the mouse whose buttons `capturePress` would wait for.
    var mouseName: String? { links.first { $0.canCapture }?.name }
    private var capture: ((UInt16?) -> Void)?
    private var captureTimer: Timer?

    /// Waits for a press of any button the mouse lets this app take, other than the left and
    /// right buttons, and passes its control ID to `completion`. Nil when nothing is pressed
    /// within `timeout` or `cancelCapture()` is called. Meanwhile those buttons do nothing else,
    /// and the button read now doesn't report.
    func capturePress(timeout: TimeInterval, completion: @escaping (UInt16?) -> Void) {
        cancelCapture()
        let mice = links.filter(\.canCapture)
        guard !mice.isEmpty else {
            completion(nil)
            return
        }
        capture = completion
        for link in mice { link.startCapture() }
        captureTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.endCapture(nil)
        }
    }

    func cancelCapture() {
        endCapture(nil)
    }

    fileprivate func endCapture(_ control: UInt16?) {
        guard let completion = capture else { return }
        capture = nil
        captureTimer?.invalidate()
        captureTimer = nil
        for link in links { link.endCapture() }
        completion(control)
    }

    private func attach(_ device: IOHIDDevice) {
        guard !links.contains(where: { $0.device == device }), !receivers.contains(where: { $0.port.device == device }) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        TriggerDebug.log(String(format: "device matched: %@, open 0x%08x", IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?", result))
        guard result == kIOReturnSuccess else {
            if !unopened.contains(device) { unopened.append(device) }
            let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            if !granted {
                // Shows the system prompt the first time and lists the app under Input Monitoring.
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            } else if result == kIOReturnNotPermitted, !askedForRelaunch {
                askedForRelaunch = true
                onNeedsRelaunch?()
            }
            status = .needsPermission
            if !reportedFailure {
                reportedFailure = true
                NSLog("LogiButton: couldn't open the mouse (0x%08x). Input Monitoring granted: %d", result, granted ? 1 : 0)
            }
            scheduleRetry()
            return
        }
        unopened.removeAll { $0 == device }
        let port = HIDPPPort(device: device)
        if IOHIDDeviceConformsTo(device, Self.bluetoothPage, Self.bluetoothUsage) {
            add(LogiLink(port: port, owner: self))
            // Bluetooth is only needed, and its permission only asked for, once there's a
            // Logitech mouse on Bluetooth.
            vendor.start()
        } else {
            let receiver = LogiReceiver(port: port, owner: self)
            receivers.append(receiver)
            receiver.start()
        }
    }

    private func detach(_ device: IOHIDDevice) {
        unopened.removeAll { $0 == device }
        receivers.removeAll { $0.port.device == device }
        for link in links where link.device == device { remove(link) }
        refreshStatus()
    }

    func add(_ link: LogiLink) {
        links.append(link)
        link.setUp()
    }

    /// Forgets a device that has gone, by disconnecting or, behind a receiver, by losing its link.
    func remove(_ link: LogiLink) {
        guard let index = links.firstIndex(where: { $0 === link }) else { return }
        links.remove(at: index)
        link.close()
        TriggerDebug.log("device removed: \(link.name), pressed=\(link.pressed)")
        // A button held while the mouse disconnects would otherwise stay down forever.
        if link.pressed { onChange?(false) }
        onLinksChanged?()
        refreshStatus()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            for device in self.unopened { self.attach(device) }
            if self.unopened.isEmpty {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    func refreshStatus() {
        if let link = links.first(where: { $0.ready }) {
            status = .ready(link.name)
        } else if !unopened.isEmpty {
            status = .needsPermission
        } else {
            status = .searching
        }
    }

    fileprivate func buttonChanged(_ pressed: Bool) {
        onChange?(pressed)
    }

    fileprivate func missedRelease() {
        if let onMissedRelease { onMissedRelease() } else { onChange?(false) }
    }

    fileprivate func linkChanged() {
        onLinksChanged?()
    }

    fileprivate func notified(_ link: LogiLink, _ feature: UInt16, _ event: UInt8, _ params: [UInt8]) {
        onNotification?(link, feature, event, params)
    }
}

/// One opened Logitech device, and the one way to send it HID++ requests: they wait their turn
/// in a queue, so the button's requests and everything else's share it safely.
final class LogiLink {
    /// Marks this app's requests so their replies can be told apart from notifications, which carry 0.
    private static let softwareID: UInt8 = 0x0B
    /// "Reprogrammable controls v4", the HID++ feature that lists and diverts buttons.
    private static let controlsFeature: UInt16 = 0x1B04
    /// The features looked up once a mouse has connected. Others are looked up when first used.
    static let knownFeatures: [UInt16] = [0x1004, 0x1814, 0x1815, 0x19B0, 0x2111, 0x2121, 0x2150, 0x2201]

    /// The device index of a device connected directly rather than through a receiver.
    static let direct: UInt8 = 0xFF
    /// "Device name and type", which names a device behind a receiver.
    private static let nameFeature: UInt16 = 0x0005

    let port: HIDPPPort
    var device: IOHIDDevice { port.device }
    /// `direct`, or the device's slot on its receiver, 1 to 6.
    let index: UInt8
    private(set) var name: String
    /// Whether the device is a mouse. A Logitech keyboard answers HID++ as well.
    private(set) var isMouse: Bool
    /// Called when a device behind a receiver doesn't answer while being set up.
    var onUnreachable: (() -> Void)?
    private unowned let owner: LogiButton
    private var controlsIndex: UInt8 = 0
    /// Each feature's index on this device, 0 for one it doesn't have, as the root feature said.
    private(set) var features: [UInt16: UInt8] = [:]
    private var featureByIndex: [UInt8: UInt16] = [:]
    /// Set once `knownFeatures` have all been looked up.
    private(set) var featuresKnown = false
    private var discovering = false
    private var flagsBefore: UInt8?
    /// The second reporting byte before this app changed it. Bit 0 is analytics reporting.
    private var flags2Before: UInt8 = 0
    /// Set once this app has turned analytics reporting on, so quitting can turn it back off.
    private var analyticsOn = false
    private var pending: (feature: UInt8, address: UInt8, token: Int, completion: ([UInt8]?) -> Void)?
    private struct Request {
        let feature: UInt8
        let function: UInt8
        let params: [UInt8]
        /// False for a request whose reply isn't waited for, such as switching host, which gets none.
        let awaitsReply: Bool
        let completion: ([UInt8]?) -> Void
    }
    /// Requests wait their turn: replies are matched to the one request in flight, so one sent
    /// while another is waiting would otherwise be dropped.
    private var queued: [Request] = []
    private var token = 0
    private(set) var ready = false
    private var tracker = ButtonTracker()
    var pressed: Bool { tracker.pressed }

    /// A device connected directly, which the port belongs to alone.
    init(port: HIDPPPort, owner: LogiButton) {
        self.port = port
        self.owner = owner
        index = Self.direct
        name = IOHIDDeviceGetProperty(port.device, kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        let page = IOHIDDeviceGetProperty(port.device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        let usage = IOHIDDeviceGetProperty(port.device, kIOHIDPrimaryUsageKey as CFString) as? Int
        isMouse = page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse
        port.onReport = { [weak self] report in self?.handle(report) }
    }

    /// A device in one of a receiver's slots. Its name and kind are read from the device in
    /// `setUp`, since the port's HID properties are the receiver's; until then they are guesses.
    init(port: HIDPPPort, index: UInt8, isMouse: Bool, owner: LogiButton) {
        self.port = port
        self.owner = owner
        self.index = index
        self.isMouse = isMouse
        name = isMouse ? "Logitech mouse" : "Logitech device"
    }

    private var controlBytes: [UInt8] {
        let control = owner.controlID ?? 0
        return [UInt8(control >> 8), UInt8(control & 0xFF)]
    }

    func setUp() {
        guard index == Self.direct else {
            identify { [weak self] in self?.setUpButton() }
            return
        }
        setUpButton()
    }

    /// Reads the name and kind of a device behind a receiver. A device that doesn't answer has
    /// gone to sleep or out of range since the receiver announced it, and is dropped until the
    /// receiver announces it again.
    private func identify(then next: @escaping () -> Void) {
        request(0x00, 0, [UInt8(Self.nameFeature >> 8), UInt8(Self.nameFeature & 0xFF)]) { [weak self] reply in
            guard let self else { return }
            guard let reply else {
                TriggerDebug.log(String(format: "slot %d didn't answer", self.index))
                self.onUnreachable?()
                return
            }
            self.remember(Self.nameFeature, at: reply[0])
            guard reply[0] != 0 else { return next() }
            // Function 2 is the kind: 3 a mouse, 4 a trackpad, 5 a trackball.
            self.call(Self.nameFeature, 2) { [weak self] kind in
                guard let self else { return }
                if let kind { self.isMouse = (3...5).contains(kind[0]) }
                // Function 0 is the name's length, and function 1 reads it from an offset.
                self.call(Self.nameFeature, 0) { [weak self] length in
                    guard let self, let length else { return next() }
                    self.readName(length: Int(length[0]), into: []) { [weak self] name in
                        if let self, !name.isEmpty { self.name = name }
                        next()
                    }
                }
            }
        }
    }

    private func readName(length: Int, into bytes: [UInt8], completion: @escaping (String) -> Void) {
        guard bytes.count < length else {
            return completion(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        }
        call(Self.nameFeature, 1, [UInt8(bytes.count)]) { [weak self] chunk in
            guard let self, let chunk, !chunk.isEmpty else {
                return completion(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
            }
            self.readName(length: length, into: bytes + chunk.prefix(length - bytes.count), completion: completion)
        }
    }

    /// The receiver reports that the device has connected again, after sleep or after being
    /// out of range. Its divert may have been forgotten, so it's asked for again.
    func reconnected() {
        if ready { divert() }
    }

    /// Finds the controls feature, which Assign Button needs too, then diverts the owner's
    /// button if it has one.
    private func setUpButton() {
        // Feature 0 is the root: ask it where the controls feature lives on this device.
        request(0x00, 0, [UInt8(Self.controlsFeature >> 8), UInt8(Self.controlsFeature & 0xFF)]) { [weak self] reply in
            guard let self else { return }
            guard let reply, reply[0] != 0 else {
                self.discover()
                return
            }
            self.controlsIndex = reply[0]
            guard self.owner.controlID != nil else {
                self.discover()
                return
            }
            self.claim()
        }
    }

    /// Counts the times this link has started taking a button, so answers about one it has
    /// since let go of are ignored.
    private var claims = 0

    /// Saves the owner's button's reporting as it is, then diverts it.
    private func claim() {
        claims += 1
        let claim = claims
        // Function 2 reads the button's current reporting. It fails if the mouse has no such button.
        request(controlsIndex, 2, controlBytes) { [weak self] reporting in
            guard let self, claim == self.claims else { return }
            guard let reporting else {
                NSLog("LogiButton: \(self.name) has no control 0x%04x", self.owner.controlID ?? 0)
                self.discover()
                return
            }
            // The flags as they were before this app ever diverted the button, kept across
            // launches: after a crash the mouse still reports this app's divert.
            let key = self.savedReportingKey
            let saved = UserDefaults.standard.array(forKey: key) as? [Int]
            let before = saved.map { $0.map(UInt8.init(truncatingIfNeeded:)) } ?? [reporting[2], reporting[5]]
            if saved == nil { UserDefaults.standard.set(before.map(Int.init), forKey: key) }
            self.flagsBefore = before[0]
            self.flags2Before = before[1]
            self.divert()
        }
    }

    private var savedReportingKey: String {
        "ReportingBefore." + name + String(format: ".%04X", owner.controlID ?? 0)
    }

    /// Hands `old` back to the mouse and takes the owner's button instead.
    func reassign(from old: UInt16?) {
        if let old, let before = flagsBefore, let params = Self.handBack(old, before: before, before2: flags2Before) {
            request(controlsIndex, 3, params) { _ in }
        }
        if let old {
            UserDefaults.standard.removeObject(forKey: "ReportingBefore." + name + String(format: ".%04X", old))
        }
        flagsBefore = nil
        flags2Before = 0
        analyticsOn = false
        ready = false
        tracker = ButtonTracker()
        if controlsIndex == 0 { setUpButton() } else if owner.controlID != nil { claim() }
    }

    /// The parameters of the request that undoes this app's changes to `control`'s reporting,
    /// given its two flags bytes from before, or nil if there's nothing to undo. 0x02 is a
    /// setting's valid bit with the setting off.
    private static func handBack(_ control: UInt16, before: UInt8, before2: UInt8) -> [UInt8]? {
        let undivert = before & 0x01 == 0
        // Analytics may have been turned on by a divert still on its way.
        let unanalytics = before2 & 0x01 == 0
        guard undivert || unanalytics else { return nil }
        return [UInt8(control >> 8), UInt8(control & 0xFF), undivert ? 0x02 : 0, 0, 0, unanalytics ? 0x02 : 0]
    }

    func divert(analytics: Bool = true) {
        // Function 3 sets reporting: the button, a flags byte, a remap target (0 leaves it alone),
        // and a second flags byte. In each flags byte a setting's bit is followed by a bit that
        // says it's valid. 0x03 in the first turns on "divert". 0x03 in the second turns on
        // analytics, a second report of each press and release; the MX Master 4 sometimes leaves
        // a transition out of the divert report, and the analytics report fills it in.
        // None of this is persistent: the mouse forgets it when it reconnects, and this runs again.
        let claim = claims
        request(controlsIndex, 3, controlBytes + [0x03, 0, 0, analytics ? 0x03 : 0]) { [weak self] reply in
            guard let self, claim == self.claims else { return }
            TriggerDebug.log("divert analytics=\(analytics) reply=\(reply == nil ? "none" : "ok")")
            if reply == nil, analytics {
                // A mouse without analytics reporting refuses the whole request. Divert alone.
                self.divert(analytics: false)
                return
            }
            if reply != nil { self.analyticsOn = analytics || self.analyticsOn }
            if reply != nil, !self.ready {
                self.ready = true
                NSLog("LogiButton: reading control 0x%04x on \(self.name)", self.owner.controlID ?? 0)
                if TriggerDebug.enabled { self.mapFeatures() }
            }
            self.owner.refreshStatus()
            if reply != nil || !analytics { self.discover() }
        }
    }

    /// Looks up where `knownFeatures` live on a mouse, once, after the button is set up so the
    /// button isn't kept waiting.
    private func discover() {
        guard isMouse, !discovering else { return }
        discovering = true
        if controlsIndex != 0 { remember(Self.controlsFeature, at: controlsIndex) }
        for (i, id) in Self.knownFeatures.enumerated() {
            resolve(id) { [weak self] _ in
                guard let self, i == Self.knownFeatures.count - 1 else { return }
                self.featuresKnown = true
                self.owner.linkChanged()
            }
        }
    }

    private func remember(_ feature: UInt16, at index: UInt8) {
        features[feature] = index
        if index != 0 { featureByIndex[index] = feature }
    }

    /// Finds a feature's index, asking the root feature the first time. Nil if the device
    /// doesn't have it or didn't answer.
    private func resolve(_ feature: UInt16, completion: @escaping (UInt8?) -> Void) {
        if let index = features[feature] {
            completion(index == 0 ? nil : index)
            return
        }
        request(0x00, 0, [UInt8(feature >> 8), UInt8(feature & 0xFF)]) { [weak self] reply in
            guard let self else { return }
            // No answer leaves it to be asked again; an answer of 0 means the device lacks it.
            if let reply { self.remember(feature, at: reply[0]) }
            completion(reply.flatMap { $0[0] == 0 ? nil : $0[0] })
        }
    }

    /// Whether the device has a feature. Nil until it has been looked up.
    func has(_ feature: UInt16) -> Bool? {
        features[feature].map { $0 != 0 }
    }

    /// Sends a HID++ request to a feature, by its ID, and passes its reply's parameter bytes to
    /// `completion` on the main thread: nil if the device doesn't have the feature, refused the
    /// request, or didn't answer.
    func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], completion: @escaping ([UInt8]?) -> Void) {
        resolve(feature) { [weak self] index in
            guard let self, let index else {
                completion(nil)
                return
            }
            self.request(index, function, params, completion: completion)
        }
    }

    /// Sends a HID++ request in its turn without waiting for a reply, which may never come.
    func post(_ feature: UInt16, _ function: UInt8, _ params: [UInt8]) {
        resolve(feature) { [weak self] index in
            guard let self, let index else { return }
            self.enqueue(Request(feature: index, function: function, params: params, awaitsReply: false) { _ in })
        }
    }

    /// Sends a request over Logitech's Bluetooth characteristic instead, where Logi Options+ talks
    /// to the mouse, without waiting for a reply. The mouse then keeps sending its notifications
    /// there. Only for a feature already looked up. Returns whether it was sent.
    func postOverBluetooth(_ feature: UInt16, _ function: UInt8, _ params: [UInt8]) -> Bool {
        guard self.index == Self.direct, let index = features[feature], index != 0 else { return false }
        return owner.writeVendor(Self.frame(feature: index, function: function, params: params), for: self)
    }

    /// Whether a request is waiting for a reply or for its turn.
    var isBusy: Bool { pending != nil || posting || !queued.isEmpty }

    /// A long HID++ report: report ID, device index (`direct`, or a receiver's slot), feature
    /// index, then function and software ID sharing a byte, then 16 parameter bytes.
    static func frame(index: UInt8 = direct, feature: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20)
        out[0] = 0x11
        out[1] = index
        out[2] = feature
        out[3] = (function << 4) | softwareID
        for (i, byte) in params.prefix(16).enumerated() { out[4 + i] = byte }
        return out
    }


    /// Undoes what this app turned on. Requests still waiting are dropped first, so none of
    /// them lands after it. It runs even before the divert has been answered, since the divert
    /// may already be on its way.
    func restore() {
        close()
        for control in capturedBefore.compactMap({ $0.value == 0 ? $0.key : nil }) {
            send(controlsIndex, 3, [UInt8(control >> 8), UInt8(control & 0xFF), 0x02, 0, 0, 0])
        }
        guard let before = flagsBefore, let control = owner.controlID,
              let params = Self.handBack(control, before: before, before2: flags2Before) else { return }
        if send(controlsIndex, 3, params) != nil {
            UserDefaults.standard.removeObject(forKey: savedReportingKey)
        }
    }

    // MARK: Capturing a press

    /// The left and right buttons, which are never taken.
    private static let mainButtons: Set<UInt16> = [0x0050, 0x0051]
    /// Set while waiting for a press of any button.
    private var capturing = false
    /// The buttons diverted to wait for a press, each with its divert bit from before.
    private var capturedBefore: [UInt16: UInt8] = [:]
    /// The diverted buttons last reported down while capturing.
    private var capturedDown: Set<UInt16> = []

    var canCapture: Bool { isMouse && controlsIndex != 0 }

    /// Diverts every button the mouse allows, except the left and right buttons and the one
    /// already read, so a press of any of them is reported.
    func startCapture() {
        capturing = true
        capturedDown = []
        // Function 0 counts the controls. Function 1 describes one by its index: its ID, its
        // task, then a flags byte in which 0x20 marks one that can be diverted.
        request(controlsIndex, 0, []) { [weak self] count in
            guard let self, self.capturing, let count else { return }
            for index in 0..<Int(count[0]) {
                self.request(self.controlsIndex, 1, [UInt8(index)]) { [weak self] info in
                    guard let self, self.capturing, let info else { return }
                    let control = UInt16(info[0]) << 8 | UInt16(info[1])
                    guard info[4] & 0x20 != 0, !Self.mainButtons.contains(control), control != self.owner.controlID else { return }
                    self.request(self.controlsIndex, 2, [info[0], info[1]]) { [weak self] reporting in
                        guard let self, self.capturing, let reporting else { return }
                        self.capturedBefore[control] = reporting[2] & 0x01
                        self.request(self.controlsIndex, 3, [info[0], info[1], 0x03, 0, 0, 0]) { _ in }
                    }
                }
            }
        }
    }

    /// Hands back the buttons `startCapture` took. Each request goes after the divert it
    /// undoes, since they share the queue.
    func endCapture() {
        guard capturing else { return }
        capturing = false
        for (control, before) in capturedBefore where before == 0 {
            request(controlsIndex, 3, [UInt8(control >> 8), UInt8(control & 0xFF), 0x02, 0, 0, 0]) { _ in }
        }
        capturedBefore = [:]
    }

    /// Set once the button has been handed back or the device has gone. Replies arriving after
    /// that change nothing.
    private var stopped = false

    /// Drops requests still waiting and sends no more.
    func close() {
        queued.removeAll()
        stopped = true
    }

    /// Sends a request and waits until it has gone, for quitting. It goes through the same queue
    /// as every other report, so it can't overtake one sent before it.
    @discardableResult
    private func send(_ feature: UInt8, _ function: UInt8, _ params: [UInt8]) -> UInt8? {
        let out = Self.frame(index: index, feature: feature, function: function, params: params)
        return port.sendNow(out) ? out[3] : nil
    }

    private func request(_ feature: UInt8, _ function: UInt8, _ params: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        enqueue(Request(feature: feature, function: function, params: params, awaitsReply: true, completion: completion))
    }

    /// Set while a request that gets no reply is on its way, so the next one waits for it.
    private var posting = false

    private func enqueue(_ next: Request) {
        guard !stopped else { return }
        guard pending == nil, !posting else {
            queued.append(next)
            return
        }
        let out = Self.frame(index: index, feature: next.feature, function: next.function, params: next.params)
        guard next.awaitsReply else {
            posting = true
            port.transmit(out) { [weak self] sent in
                self?.posting = false
                next.completion(sent ? [] : nil)
                self?.sendNext()
            }
            return
        }
        token += 1
        let mine = token
        pending = (next.feature, out[3], mine, next.completion)
        port.transmit(out) { [weak self] sent in
            guard !sent, let self, let waiting = self.pending, waiting.token == mine else { return }
            self.finish(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let waiting = self.pending, waiting.token == mine else { return }
            TriggerDebug.log(String(format: "request to feature %02x function %02x timed out", waiting.feature, waiting.address >> 4))
            self.finish(nil)
        }
    }

    /// Set while handling a report that answered this app's request.
    private var pendingConsumed = false

    private func finish(_ reply: [UInt8]?) {
        guard let waiting = pending else { return }
        pendingConsumed = true
        pending = nil
        waiting.completion(reply)
        sendNext()
    }

    private func sendNext() {
        guard pending == nil, !posting, !queued.isEmpty else { return }
        enqueue(queued.removeFirst())
    }

    /// Feature IDs by index, for the diagnostic's log.
    private var featureIDs: [UInt8: UInt16] = [:]

    /// Lists the mouse's features, so the diagnostic can name the ones that send it messages.
    /// Feature 0x0001 (feature set) only reads: function 0 is the count, function 1 an index's ID.
    private func mapFeatures() {
        request(0x00, 0, [0x00, 0x01]) { [weak self] reply in
            guard let self, let reply, reply[0] != 0 else { return }
            let featureSet = reply[0]
            self.request(featureSet, 0, []) { [weak self] count in
                guard let self, let count else { return }
                for index in 1...max(Int(count[0]), 1) {
                    self.request(featureSet, 1, [UInt8(index)]) { [weak self] id in
                        guard let self, let id else { return }
                        self.featureIDs[UInt8(index)] = UInt16(id[0]) << 8 | UInt16(id[1])
                        if index == Int(count[0]) {
                            TriggerDebug.log("features: " + self.featureIDs.sorted { $0.key < $1.key }
                                .map { String(format: "%d=%04X", $0.key, $0.value) }.joined(separator: " "))
                        }
                    }
                }
            }
        }
    }

    /// Logs every HID++ message the mouse sends that isn't a reply to this app or the button's
    /// own reports, which are logged where they're read.
    private func logOther(_ report: UnsafeBufferPointer<UInt8>, channel: String) {
        guard report.count >= 4, report[0] == 0x10 || report[0] == 0x11 else { return }
        if report[2] == controlsIndex, ready { return }
        let feature = report[2] == 0xFF ? "error" : featureIDs[report[2]].map { String(format: "%04X", $0) } ?? String(format: "#%d", report[2])
        TriggerDebug.log("\(channel)++ \(name.prefix(9)) \(feature) fn/ev \(report[3] >> 4) sw \(report[3] & 0x0F): "
            + report[4..<min(report.count, 20)].map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    /// A message from Logitech's own Bluetooth characteristic. Replies there answer Options+,
    /// never this app, so only notifications are read.
    func handleVendor(_ report: [UInt8]) {
        report.withUnsafeBufferPointer { handle($0, vendor: true) }
    }

    func handle(_ report: UnsafeBufferPointer<UInt8>, vendor: Bool = false) {
        let channel = vendor ? "ble" : "hid"
        defer { if TriggerDebug.enabled, pendingConsumed == false { logOther(report, channel: channel) } }
        pendingConsumed = false
        // A receiver refuses a request for a device it can't reach with a short HID++ 1.0 error,
        // sub ID 0x8F, naming the request's feature index and function byte.
        if !vendor, let waiting = pending, report.count >= 6, report[0] == 0x10, report[2] == 0x8F,
           report[3] == waiting.feature, report[4] == waiting.address {
            TriggerDebug.log(String(format: "receiver error %02x for slot %d feature %02x", report[5], index, report[3]))
            finish(nil)
            return
        }
        guard report.count >= 12, report[0] == 0x11 else { return }
        if !vendor, let waiting = pending {
            if report[2] == waiting.feature, report[3] == waiting.address {
                finish(Array(report[4...]))
                return
            }
            // An error reply names the feature and function it refuses.
            if report[2] == 0xFF, report[3] == waiting.feature, report[4] == waiting.address {
                TriggerDebug.log(String(format: "error %02x from feature %02x function %02x", report[5], report[3], report[4] >> 4))
                finish(nil)
                return
            }
        }
        if report[3] & 0x0F == 0, let feature = featureByIndex[report[2]], feature != Self.controlsFeature {
            owner.notified(self, feature, report[3] >> 4, Array(report[4...]))
        }
        func control(at i: Int) -> UInt16 { UInt16(report[i]) << 8 | UInt16(report[i + 1]) }
        if capturing, controlsIndex != 0, report[2] == controlsIndex {
            // While capturing, a button newly listed in event 0 is the one pressed.
            guard report[3] == 0x00 else { return }
            let down = Set((0..<4).map { control(at: 4 + 2 * $0) }).subtracting([0])
            let pressed = down.subtracting(capturedDown)
            capturedDown = down
            if let pressed = pressed.min() { owner.endCapture(pressed) }
            return
        }
        guard ready, report[2] == controlsIndex else { return }
        TriggerDebug.log("\(channel) " + report[3..<min(report.count, 19)].map { String(format: "%02x", $0) }.joined(separator: " "))
        let down: Bool
        switch report[3] {
        case 0x00:
            // Event 0 lists up to four diverted buttons that are down right now.
            down = (0..<4).contains { control(at: 4 + 2 * $0) == owner.controlID }
        case 0x20 where report.count >= 19:
            // Event 2, analytics, lists up to five buttons that changed, each followed by 1 for
            // pressed or 0 for released. It repeats what event 0 says, except when event 0
            // leaves a press or release out, so only a change from what's known counts.
            guard let i = (0..<5).map({ 4 + 3 * $0 }).first(where: { control(at: $0) == owner.controlID }) else { return }
            down = report[i + 2] == 1
        default:
            return
        }
        for change in tracker.report(down: down, at: ProcessInfo.processInfo.systemUptime) {
            TriggerDebug.log("button \(change) from \(report[3] == 0 ? "divert" : "analytics") report over \(channel)")
            switch change {
            case .press: owner.buttonChanged(true)
            case .release: owner.buttonChanged(false)
            case .missedRelease: owner.missedRelease()
            }
        }
    }
}

/// Turns the mouse's reports on one button into presses and releases.
///
/// Either report alone can leave a change out, so a change counts from whichever report says it
/// first. Both can also lose the same release: the mouse sometimes never reports the release of
/// a press made just before a pause, and its next word on the button is the following press,
/// arriving while the button still reads as down. A press reported that way after the button has
/// been quiet a while recovers the release first, so the press isn't swallowed.
struct ButtonTracker {
    enum Change: Equatable { case press, release, missedRelease }

    /// On 2026-11-13 every lost release was followed by the next press 1 to 3.4 s later.
    /// Ordinary presses and releases came 50 to 500 ms apart, and the two reports of one change
    /// about 10 ms apart.
    static let missedReleaseGap: TimeInterval = 0.6

    private(set) var pressed = false
    private var lastReport = -TimeInterval.infinity

    mutating func report(down: Bool, at now: TimeInterval) -> [Change] {
        let quiet = now - lastReport
        lastReport = now
        if down, pressed, quiet > Self.missedReleaseGap {
            return [.missedRelease, .press]
        }
        guard down != pressed else { return [] }
        pressed = down
        return [down ? .press : .release]
    }
}
