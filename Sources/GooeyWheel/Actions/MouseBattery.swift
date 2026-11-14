import CoreBluetooth
import IOKit

/// The battery of a mouse that doesn't report it over HID++, for Mouse Battery.
///
/// Apple's mice report their charge to macOS, which keeps it in the I/O Registry as
/// `BatteryPercent`; reading it needs no permission. Other Bluetooth mice offer the standard
/// Battery service (0x180F), read through Core Bluetooth. That asks for Bluetooth permission the
/// first time, so it's only tried when the registry has no reading.
final class MouseBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = MouseBattery()

    private static let service = CBUUID(string: "180F")
    private static let level = CBUUID(string: "2A19")

    private(set) var battery: MouseState.Battery? {
        didSet {
            guard battery != oldValue else { return }
            NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
        }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The names of the Bluetooth mice connected, as their HID devices give them.
    private var mouseNames: Set<String> = []

    /// Reads the charge again in the background.
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let registry = Self.registryPercent()
            let names = Self.bluetoothMouseNames()
            DispatchQueue.main.async { [self] in
                if let registry {
                    battery = MouseState.Battery(percent: registry, chargingStatus: 0)
                    return
                }
                mouseNames = names
                guard !names.isEmpty else {
                    battery = nil
                    return
                }
                if central == nil {
                    // Its state arrives in `centralManagerDidUpdateState`, which reads on.
                    central = CBCentralManager(delegate: self, queue: .main)
                } else {
                    readBluetooth()
                }
            }
        }
    }

    // MARK: I/O Registry

    /// The charge of the first mouse in the I/O Registry that reports one.
    private static func registryPercent() -> Int? {
        guard let matching = IOServiceMatching("IOService") else { return nil }
        (matching as NSMutableDictionary)[kIOPropertyExistsMatchKey] = "BatteryPercent"
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard isMouse(service), let percent = property(service, "BatteryPercent") as? Int else { continue }
            return percent
        }
        return nil
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Whether a HID service is a mouse: its usage, or one of its usage pairs, is a generic
    /// desktop mouse, or failing those its name says it is one.
    private static func isMouse(_ service: io_object_t) -> Bool {
        let page = kHIDPage_GenericDesktop, usage = kHIDUsage_GD_Mouse
        if (property(service, kIOHIDProductKey) as? String)?.localizedCaseInsensitiveContains("mouse") == true { return true }
        if property(service, kIOHIDPrimaryUsagePageKey) as? Int == page, property(service, kIOHIDPrimaryUsageKey) as? Int == usage {
            return true
        }
        let pairs = property(service, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []
        return pairs.contains {
            $0[kIOHIDDeviceUsagePageKey] as? Int == page && $0[kIOHIDDeviceUsageKey] as? Int == usage
        }
    }

    private static func bluetoothMouseNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: Set<String> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let transport = property(service, kIOHIDTransportKey) as? String, transport.contains("Bluetooth"),
                  isMouse(service), let name = property(service, kIOHIDProductKey) as? String else { continue }
            names.insert(name)
        }
        return names
    }

    // MARK: Bluetooth

    private func readBluetooth() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected, mouseNames.contains(peripheral.name ?? ""),
           let level = peripheral.services?.first(where: { $0.uuid == Self.service })?.characteristics?.first(where: { $0.uuid == Self.level }) {
            peripheral.readValue(for: level)
            return
        }
        guard let mouse = central.retrieveConnectedPeripherals(withServices: [Self.service]).first(where: { mouseNames.contains($0.name ?? "") }) else {
            battery = nil
            return
        }
        peripheral = mouse
        mouse.delegate = self
        central.connect(mouse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { readBluetooth() } else { battery = nil }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == self.peripheral {
            self.peripheral = nil
            battery = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.level], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.level {
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }

    /// The Battery Level characteristic is one byte, a percentage.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.level, let byte = characteristic.value?.first, byte <= 100 else { return }
        battery = MouseState.Battery(percent: Int(byte), chargingStatus: 0)
    }
}
