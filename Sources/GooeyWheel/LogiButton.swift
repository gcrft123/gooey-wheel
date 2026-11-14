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
    fileprivate let controlID: UInt16?
    private let manager: IOHIDManager
    private(set) var links: [LogiLink] = []
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

    /// Sends a HID++ report to `link`'s device over Logitech's Bluetooth characteristic.
    fileprivate func writeVendor(_ report: [UInt8], for link: LogiLink) -> Bool {
        vendor.write(report, to: link.name)
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
        let link = LogiLink(device: device, owner: self)
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
            onLinksChanged?()
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

    let device: IOHIDDevice
    let name: String
    /// Whether the device presents itself as a mouse. A Logitech keyboard answers HID++ as well.
    let isMouse: Bool
    private unowned let owner: LogiButton
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
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

    init(device: IOHIDDevice, owner: LogiButton) {
        self.device = device
        self.owner = owner
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
        isMouse = page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let link = Unmanaged<LogiLink>.fromOpaque(context).takeUnretainedValue()
            link.handle(UnsafeBufferPointer(start: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        buffer.deallocate()
    }

    private var controlBytes: [UInt8] {
        let control = owner.controlID ?? 0
        return [UInt8(control >> 8), UInt8(control & 0xFF)]
    }

    func setUp() {
        guard owner.controlID != nil else {
            discover()
            return
        }
        // Feature 0 is the root: ask it where the controls feature lives on this device.
        request(0x00, 0, [UInt8(Self.controlsFeature >> 8), UInt8(Self.controlsFeature & 0xFF)]) { [weak self] reply in
            guard let self else { return }
            guard let reply, reply[0] != 0 else {
                self.discover()
                return
            }
            self.controlsIndex = reply[0]
            // Function 2 reads the button's current reporting. It fails if the mouse has no such button.
            self.request(self.controlsIndex, 2, self.controlBytes) { [weak self] reporting in
                guard let self, let reporting else {
                    NSLog("LogiButton: \(self?.name ?? "device") has no control 0x%04x", self?.owner.controlID ?? 0)
                    self?.discover()
                    return
                }
                // The flags as they were before this app ever diverted the button, kept across
                // launches: after a crash the mouse still reports this app's divert.
                let key = "ReportingBefore." + self.name
                let saved = UserDefaults.standard.array(forKey: key) as? [Int]
                let before = saved.map { $0.map(UInt8.init(truncatingIfNeeded:)) } ?? [reporting[2], reporting[5]]
                if saved == nil { UserDefaults.standard.set(before.map(Int.init), forKey: key) }
                self.flagsBefore = before[0]
                self.flags2Before = before[1]
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
        guard let index = features[feature], index != 0 else { return false }
        return owner.writeVendor(Self.frame(feature: index, function: function, params: params), for: self)
    }

    /// Whether a request is waiting for a reply or for its turn.
    var isBusy: Bool { pending != nil || posting || !queued.isEmpty }

    /// A long HID++ report: report ID, device index (0xFF addresses a directly connected device),
    /// feature index, then function and software ID sharing a byte, then 16 parameter bytes.
    static func frame(feature: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20)
        out[0] = 0x11
        out[1] = 0xFF
        out[2] = feature
        out[3] = (function << 4) | softwareID
        for (i, byte) in params.prefix(16).enumerated() { out[4 + i] = byte }
        return out
    }


    /// Undoes what this app turned on. 0x02 is a setting's valid bit with the setting off.
    /// Requests still waiting are dropped first, so none of them lands after it. It runs even
    /// before the divert has been answered, since the divert may already be on its way.
    func restore() {
        queued.removeAll()
        stopped = true
        guard let before = flagsBefore else { return }
        let undivert = before & 0x01 == 0
        // Analytics may have been turned on by a divert still on its way.
        let unanalytics = flags2Before & 0x01 == 0
        guard undivert || unanalytics else { return }
        if send(controlsIndex, 3, controlBytes + [undivert ? 0x02 : 0, 0, 0, unanalytics ? 0x02 : 0]) != nil {
            UserDefaults.standard.removeObject(forKey: "ReportingBefore." + name)
        }
    }

    /// Set once the button has been handed back. Replies arriving after that change nothing.
    private var stopped = false

    /// Sends a request and waits until it has gone, for quitting. It goes through the same queue
    /// as every other report, so it can't overtake one sent before it.
    @discardableResult
    private func send(_ feature: UInt8, _ function: UInt8, _ params: [UInt8]) -> UInt8? {
        let out = Self.frame(feature: feature, function: function, params: params)
        let device = device
        let result = Self.sender.sync { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, out, out.count) }
        return result == kIOReturnSuccess ? out[3] : nil
    }

    /// Where reports are sent from. Sending blocks until the mouse acknowledges the report, 20 to
    /// 30 ms over Bluetooth, which on the main thread would hold up the wheel's animation on every
    /// request. (IOHIDDeviceSetReportWithCallback doesn't block, but once a process has used it
    /// the device's input reports stopped reaching it.)
    private static let sender = DispatchQueue(label: "LogiLink.sender", qos: .userInteractive)

    /// Sends a report from `sender` and calls `sent` on the main thread with whether it went.
    private func transmit(_ report: [UInt8], sent: @escaping (Bool) -> Void) {
        let device = device
        Self.sender.async {
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
            DispatchQueue.main.async { sent(result == kIOReturnSuccess) }
        }
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
        let out = Self.frame(feature: next.feature, function: next.function, params: next.params)
        guard next.awaitsReply else {
            posting = true
            transmit(out) { [weak self] sent in
                self?.posting = false
                next.completion(sent ? [] : nil)
                self?.sendNext()
            }
            return
        }
        token += 1
        let mine = token
        pending = (next.feature, out[3], mine, next.completion)
        transmit(out) { [weak self] sent in
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
        if report[3] & 0x0F == 0, let feature = featureByIndex[report[2]], feature != Self.controlsFeature {
            owner.notified(self, feature, report[3] >> 4, Array(report[4...]))
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
