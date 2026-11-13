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
    var onStatus: ((Status) -> Void)?
    /// Called when access has been granted but macOS still refuses the device, which a fresh
    /// launch of the app clears.
    var onNeedsRelaunch: (() -> Void)?
    private(set) var status = Status.searching {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    fileprivate let controlID: UInt16
    private let manager: IOHIDManager
    private var links: [Link] = []
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
    }

    /// Asks the mouse to divert the button again. Other software can switch it back, so this runs
    /// whenever the frontmost app changes and after sleep.
    func reassert() {
        for link in links where link.ready { link.divert() }
    }

    /// Hands the button back to the mouse if this app was the one that took it.
    func stop() {
        for link in links { link.restore() }
    }

    private func attach(_ device: IOHIDDevice) {
        guard !links.contains(where: { $0.device == device }) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
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
    }

    private func detach(_ device: IOHIDDevice) {
        unopened.removeAll { $0 == device }
        if let index = links.firstIndex(where: { $0.device == device }) {
            let link = links.remove(at: index)
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
    private var pending: (feature: UInt8, address: UInt8, token: Int, completion: ([UInt8]?) -> Void)?
    private var token = 0
    private(set) var ready = false
    private(set) var pressed = false

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
                self.divert()
            }
        }
    }

    func divert() {
        // Function 3 sets reporting. 0x03 is "divert" plus the bit that says the divert bit is valid.
        // It isn't persistent: the mouse forgets it when it reconnects, and this runs again.
        request(controlsIndex, 3, controlBytes + [0x03, 0, 0]) { [weak self] reply in
            guard let self else { return }
            if reply != nil, !self.ready {
                self.ready = true
                NSLog("LogiButton: reading control 0x%04x on \(self.name)", self.owner.controlID)
            }
            self.owner.refreshStatus()
        }
    }

    func restore() {
        guard ready, let before = flagsBefore, before & 0x01 == 0 else { return }
        send(controlsIndex, 3, controlBytes + [0x02, 0, 0])
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
        guard pending == nil, let address = send(feature, function, params) else {
            completion(nil)
            return
        }
        token += 1
        let mine = token
        pending = (feature, address, mine, completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let waiting = self.pending, waiting.token == mine else { return }
            self.pending = nil
            waiting.completion(nil)
        }
    }

    private func handle(_ report: UnsafeBufferPointer<UInt8>) {
        guard report.count >= 12, report[0] == 0x11 else { return }
        if let waiting = pending {
            if report[2] == waiting.feature, report[3] == waiting.address {
                pending = nil
                waiting.completion(Array(report[4...]))
                return
            }
            // An error reply names the feature and function it refuses.
            if report[2] == 0xFF, report[3] == waiting.feature, report[4] == waiting.address {
                pending = nil
                waiting.completion(nil)
                return
            }
        }
        // Event 0 of the controls feature lists up to four diverted buttons that are down right now.
        guard ready, report[2] == controlsIndex, report[3] == 0x00 else { return }
        var down = false
        for i in 0..<4 {
            let control = UInt16(report[4 + 2 * i]) << 8 | UInt16(report[5 + 2 * i])
            if control == owner.controlID { down = true }
        }
        guard down != pressed else { return }
        pressed = down
        owner.buttonChanged(down)
    }
}
