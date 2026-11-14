import Foundation

/// A Logitech receiver, such as Bolt, and the devices connected through it.
///
/// The receiver relays HID++ for up to six paired devices. A report's second byte, the device
/// index, is the device's slot, 1 to 6, and the receiver itself is 0xFF. The receiver speaks
/// HID++ 1.0: its settings are registers, read and written with short reports (ID 0x10), whose
/// third byte is the sub ID: 0x80 writes a register, 0x81 reads one, and 0x8F is an error.
///
/// Devices are found from the receiver's connection notifications (sub ID 0x41), which it sends
/// when a device's link comes up or goes down, such as when a mouse wakes, sleeps, or is
/// switched to another computer. Asked to, it sends one for every paired device.
final class LogiReceiver {
    let port: HIDPPPort
    private unowned let owner: LogiButton
    private var links: [UInt8: LogiLink] = [:]

    private struct Request {
        let subID: UInt8
        let register: UInt8
        let params: [UInt8]
        let completion: ([UInt8]?) -> Void
    }
    private var pending: (request: Request, token: Int)?
    private var queued: [Request] = []
    private var token = 0

    private static let receiverIndex: UInt8 = 0xFF
    private static let writeRegister: UInt8 = 0x80
    private static let readRegister: UInt8 = 0x81
    private static let error: UInt8 = 0x8F
    private static let connection: UInt8 = 0x41
    /// Which notifications the receiver sends the host, three bytes of flags.
    private static let notificationsRegister: UInt8 = 0x00
    /// In `notificationsRegister`'s middle byte, the connection notifications.
    private static let wirelessNotifications: UInt8 = 0x01
    /// Writing 0x02 here makes the receiver send a connection notification for each paired device.
    private static let connectionRegister: UInt8 = 0x02

    init(port: HIDPPPort, owner: LogiButton) {
        self.port = port
        self.owner = owner
        port.onReport = { [weak self] report in self?.handle(report) }
    }

    func start() {
        // Connection notifications are off until some software turns them on. They are left on
        // when the app quits: other software, such as Logi Options+, may rely on them too, and
        // they only add messages that nothing else on the Mac reads.
        read(Self.notificationsRegister) { [weak self] flags in
            guard let self else { return }
            guard let flags else {
                TriggerDebug.log("receiver didn't answer; not a receiver")
                return
            }
            TriggerDebug.log("receiver notifications " + flags.prefix(3).map { String(format: "%02x", $0) }.joined())
            if flags[1] & Self.wirelessNotifications == 0 {
                self.write(Self.notificationsRegister, [flags[0], flags[1] | Self.wirelessNotifications, flags[2]]) { _ in }
            }
            self.write(Self.connectionRegister, [0x02, 0, 0]) { reply in
                TriggerDebug.log("receiver asked to list devices: \(reply == nil ? "refused" : "ok")")
            }
        }
    }

    private func handle(_ report: UnsafeBufferPointer<UInt8>) {
        guard report.count >= 7 else { return }
        let index = report[1]
        if index == Self.receiverIndex {
            answer(report)
        } else if report[0] == 0x10, report[2] == Self.connection {
            // Bit 6 of the first parameter is set when the link is down; the low nibble is the
            // kind of device, 2 for a mouse.
            let up = report[4] & 0x40 == 0
            TriggerDebug.log("receiver slot \(index) link \(up ? "up" : "down"): "
                + report[3..<7].map { String(format: "%02x", $0) }.joined(separator: " "))
            connected(index, up: up, isMouse: report[4] & 0x0F == 2)
        } else {
            links[index]?.handle(report)
        }
    }

    private func connected(_ index: UInt8, up: Bool, isMouse: Bool) {
        guard (1...6).contains(index) else { return }
        if let link = links[index] {
            if up {
                link.reconnected()
            } else {
                links[index] = nil
                owner.remove(link)
            }
            return
        }
        guard up else { return }
        let link = LogiLink(port: port, index: index, isMouse: isMouse, owner: owner)
        link.onUnreachable = { [weak self, weak link] in
            guard let self, let link, self.links[index] === link else { return }
            self.links[index] = nil
            self.owner.remove(link)
        }
        links[index] = link
        owner.add(link)
    }

    // MARK: Registers

    private func read(_ register: UInt8, completion: @escaping ([UInt8]?) -> Void) {
        enqueue(Request(subID: Self.readRegister, register: register, params: [0, 0, 0], completion: completion))
    }

    private func write(_ register: UInt8, _ params: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        enqueue(Request(subID: Self.writeRegister, register: register, params: params, completion: completion))
    }

    private func enqueue(_ request: Request) {
        guard pending == nil else {
            queued.append(request)
            return
        }
        token += 1
        let mine = token
        pending = (request, mine)
        let out = [0x10, Self.receiverIndex, request.subID, request.register] + request.params.prefix(3)
        port.transmit(out) { [weak self] sent in
            guard !sent, let self, self.pending?.token == mine else { return }
            self.finish(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pending?.token == mine else { return }
            self.finish(nil)
        }
    }

    /// Matches a report from the receiver itself to the register request waiting for it.
    private func answer(_ report: UnsafeBufferPointer<UInt8>) {
        guard report[0] == 0x10, let waiting = pending?.request else { return }
        if report[2] == waiting.subID, report[3] == waiting.register {
            finish(Array(report[4..<7]))
        } else if report[2] == Self.error, report[3] == waiting.subID, report[4] == waiting.register {
            TriggerDebug.log(String(format: "receiver error %02x for register %02x", report[5], waiting.register))
            finish(nil)
        }
    }

    private func finish(_ reply: [UInt8]?) {
        guard let waiting = pending else { return }
        pending = nil
        waiting.request.completion(reply)
        if pending == nil, !queued.isEmpty { enqueue(queued.removeFirst()) }
    }
}
