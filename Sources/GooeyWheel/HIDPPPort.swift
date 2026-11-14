import Foundation
import IOKit.hid

/// An opened HID++ interface: a mouse's own, on Bluetooth, or a receiver's, which the devices
/// paired to it share. Reports arrive on the main thread and are sent from a background queue.
final class HIDPPPort {
    let device: IOHIDDevice
    /// Called with each input report, report ID first.
    var onReport: ((UnsafeBufferPointer<UInt8>) -> Void)?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init(device: IOHIDDevice) {
        self.device = device
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let port = Unmanaged<HIDPPPort>.fromOpaque(context).takeUnretainedValue()
            port.onReport?(UnsafeBufferPointer(start: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        buffer.deallocate()
    }

    /// Where reports are sent from. Sending blocks until the device acknowledges the report, 20 to
    /// 30 ms over Bluetooth, which on the main thread would hold up the wheel's animation on every
    /// request. (IOHIDDeviceSetReportWithCallback doesn't block, but once a process has used it
    /// the device's input reports stopped reaching it.)
    private static let sender = DispatchQueue(label: "HIDPPPort.sender", qos: .userInteractive)

    /// Sends a report from `sender` and calls `sent` on the main thread with whether it went.
    func transmit(_ report: [UInt8], sent: @escaping (Bool) -> Void) {
        let device = device
        Self.sender.async {
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
            DispatchQueue.main.async { sent(result == kIOReturnSuccess) }
        }
    }

    /// Sends a report and waits until it has gone, for quitting. It goes through the same queue
    /// as every other report, so it can't overtake one sent before it.
    func sendNow(_ report: [UInt8]) -> Bool {
        let device = device
        return Self.sender.sync {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        } == kIOReturnSuccess
    }
}
