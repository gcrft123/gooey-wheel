import Foundation
import IOKit.hid

/// Reads one button of a Logitech mouse straight from the device over HID++ 2.0. It doesn't go
/// through Logi Options+ and works whether or not Options+ is running.
///
/// The mouse is asked to "divert" the button: instead of performing its built-in function, it
/// sends a notification listing which diverted buttons are down. That gives a press and a release,
/// which a keyboard shortcut assigned in Options+ doesn't.
///
/// Only devices connected by Bluetooth are handled. A mouse behind a Bolt receiver is addressed
/// differently and isn't supported yet.
final class LogiButton {
    enum Status: Equatable {
        case searching
        /// macOS is withholding the device until the app is allowed under Input Monitoring.
        case needsPermission
        case ready(String)
    }

    /// The MX Master 4's thumb panel.
    static let thumbPanel: UInt16 = 0x01A0

    /// Called with true when the button goes down and false when it comes up.
    var onChange: ((Bool) -> Void)?
    /// Called in place of `onChange(false)` for a release the mouse never reported, recovered
    /// when the next press arrives. When the button actually came up isn't known.
    var onMissedRelease: (() -> Void)?
    var onStatus: ((Status) -> Void)?
    /// Called when access has been granted but macOS still refuses the device, which a fresh
    /// launch of the app clears.
    var onNeedsRelaunch: (() -> Void)?
    private(set) var status = Status.searching {
        didSet {
            guard status != oldValue else { return }
            TriggerDebug.log("link status \(status)")
            onStatus?(status)
        }
    }

    fileprivate let controlID: UInt16
    private let manager: IOHIDManager
    private var links: [Link] = []
    private let vendor = VendorChannel()
    private var unopened: [IOHIDDevice] = []
    private var retryTimer: Timer?
    private var reportedFailure = false
    private var askedForRelaunch = false

    init(controlID: UInt16) {
        self.controlID = controlID
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        // HID++ over Bluetooth is a vendor-defined collection on the mouse's own HID device.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
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
            for link in self?.links ?? [] where link.name == name { link.handleVendor(report) }
        }
        vendor.start()
    }

    /// Asks the mouse to divert the button again. Other software can switch it back, so this runs
    /// whenever the frontmost app changes and after sleep.
    func reassert() {
        TriggerDebug.log("reassert divert on \(links.filter(\.ready).count) link(s)")
        for link in links where link.ready { link.divert() }
    }

    /// Hands the button back to the mouse if this app was the one that took it.
    func stop() {
        for link in links { link.restore() }
    }

    private func attach(_ device: IOHIDDevice) {
        guard !links.contains(where: { $0.device == device }) else { return }
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
        let link = Link(device: device, owner: self)
        links.append(link)
        link.setUp()
        vendor.refresh()
    }

    private func detach(_ device: IOHIDDevice) {
        unopened.removeAll { $0 == device }
        if let index = links.firstIndex(where: { $0.device == device }) {
            let link = links.remove(at: index)
            TriggerDebug.log("device removed: \(link.name), pressed=\(link.pressed)")
            // A button held while the mouse disconnects would otherwise stay down forever.
            if link.pressed { onChange?(false) }
        }
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

    fileprivate func refreshStatus() {
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
}

/// One opened mouse.
private final class Link {
    /// Marks this app's requests so their replies can be told apart from notifications, which carry 0.
    private static let softwareID: UInt8 = 0x0B
    /// "Reprogrammable controls v4", the HID++ feature that lists and diverts buttons.
    private static let controlsFeature: UInt16 = 0x1B04

    let device: IOHIDDevice
    let name: String
    private unowned let owner: LogiButton
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var controlsIndex: UInt8 = 0
    private var flagsBefore: UInt8?
    /// The second reporting byte before this app changed it. Bit 0 is analytics reporting.
    private var flags2Before: UInt8 = 0
    /// Set once this app has turned analytics reporting on, so quitting can turn it back off.
    private var analyticsOn = false
    private var pending: (feature: UInt8, address: UInt8, token: Int, completion: ([UInt8]?) -> Void)?
    /// Requests wait their turn: replies are matched to the one request in flight, so one sent
    /// while another is waiting would otherwise be dropped.
    private var queued: [(feature: UInt8, function: UInt8, params: [UInt8], completion: ([UInt8]?) -> Void)] = []
    private var token = 0
    private(set) var ready = false
    private var tracker = ButtonTracker()
    var pressed: Bool { tracker.pressed }

    init(device: IOHIDDevice, owner: LogiButton) {
        self.device = device
        self.owner = owner
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let link = Unmanaged<Link>.fromOpaque(context).takeUnretainedValue()
            link.handle(UnsafeBufferPointer(start: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        buffer.deallocate()
    }

    private var controlBytes: [UInt8] { [UInt8(owner.controlID >> 8), UInt8(owner.controlID & 0xFF)] }

    func setUp() {
        // Feature 0 is the root: ask it where the controls feature lives on this device.
        request(0x00, 0, [UInt8(Self.controlsFeature >> 8), UInt8(Self.controlsFeature & 0xFF)]) { [weak self] reply in
            guard let self, let reply, reply[0] != 0 else { return }
            self.controlsIndex = reply[0]
            // Function 2 reads the button's current reporting. It fails if the mouse has no such button.
            self.request(self.controlsIndex, 2, self.controlBytes) { [weak self] reporting in
                guard let self, let reporting else {
                    NSLog("LogiButton: \(self?.name ?? "device") has no control 0x%04x", self?.owner.controlID ?? 0)
                    return
                }
                self.flagsBefore = reporting[2]
                self.flags2Before = reporting[5]
                self.divert()
            }
        }
    }

    func divert(analytics: Bool = true) {
        // Function 3 sets reporting: the button, a flags byte, a remap target (0 leaves it alone),
        // and a second flags byte. In each flags byte a setting's bit is followed by a bit that
        // says it's valid. 0x03 in the first turns on "divert". 0x03 in the second turns on
        // analytics, a second report of each press and release; the MX Master 4 sometimes leaves
        // a transition out of the divert report, and the analytics report fills it in.
        // None of this is persistent: the mouse forgets it when it reconnects, and this runs again.
        request(controlsIndex, 3, controlBytes + [0x03, 0, 0, analytics ? 0x03 : 0]) { [weak self] reply in
            guard let self else { return }
            TriggerDebug.log("divert analytics=\(analytics) reply=\(reply == nil ? "none" : "ok")")
            if reply == nil, analytics {
                // A mouse without analytics reporting refuses the whole request. Divert alone.
                self.divert(analytics: false)
                return
            }
            if reply != nil { self.analyticsOn = analytics || self.analyticsOn }
            if reply != nil, !self.ready {
                self.ready = true
                NSLog("LogiButton: reading control 0x%04x on \(self.name)", self.owner.controlID)
                if TriggerDebug.enabled { self.mapFeatures() }
            }
            self.owner.refreshStatus()
        }
    }


    /// Undoes what this app turned on. 0x02 is a setting's valid bit with the setting off.
    func restore() {
        guard ready, let before = flagsBefore else { return }
        let undivert = before & 0x01 == 0
        let unanalytics = analyticsOn && flags2Before & 0x01 == 0
        guard undivert || unanalytics else { return }
        send(controlsIndex, 3, controlBytes + [undivert ? 0x02 : 0, 0, 0, unanalytics ? 0x02 : 0])
    }

    @discardableResult
    private func send(_ feature: UInt8, _ function: UInt8, _ params: [UInt8]) -> UInt8? {
        // A long HID++ report: report ID, device index (0xFF addresses a directly connected device),
        // feature index, then function and software ID sharing a byte.
        var out = [UInt8](repeating: 0, count: 20)
        out[0] = 0x11
        out[1] = 0xFF
        out[2] = feature
        out[3] = (function << 4) | Self.softwareID
        for (i, byte) in params.prefix(16).enumerated() { out[4 + i] = byte }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, out, out.count)
        return result == kIOReturnSuccess ? out[3] : nil
    }

    private func request(_ feature: UInt8, _ function: UInt8, _ params: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        guard pending == nil else {
            queued.append((feature, function, params, completion))
            return
        }
        guard let address = send(feature, function, params) else {
            completion(nil)
            sendNext()
            return
        }
        token += 1
        let mine = token
        pending = (feature, address, mine, completion)
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
        guard pending == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        request(next.feature, next.function, next.params, completion: next.completion)
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

    private func handle(_ report: UnsafeBufferPointer<UInt8>, vendor: Bool = false) {
        let channel = vendor ? "ble" : "hid"
        defer { if TriggerDebug.enabled, pendingConsumed == false { logOther(report, channel: channel) } }
        pendingConsumed = false
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
        guard ready, report[2] == controlsIndex else { return }
        TriggerDebug.log("\(channel) " + report[3..<min(report.count, 19)].map { String(format: "%02x", $0) }.joined(separator: " "))
        func control(at i: Int) -> UInt16 { UInt16(report[i]) << 8 | UInt16(report[i + 1]) }
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
