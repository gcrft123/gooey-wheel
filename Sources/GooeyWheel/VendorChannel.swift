import CoreBluetooth

/// A Logitech mouse on Bluetooth carries HID++ two ways: as HID reports, which this app uses,
/// and over a Bluetooth characteristic of Logitech's own, which Logi Options+ uses. The mouse
/// sends its notifications only to the channel that spoke to it last. Options+ asks it something
/// every 4 seconds, and for one to two seconds after each of those the button's reports arrive
/// on that characteristic and not as HID reports. Listening there as well keeps them.
///
/// This only subscribes. It never writes to the characteristic.
final class VendorChannel: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "00010000-0000-1000-8000-011F2000046D")
    static let characteristic = CBUUID(string: "00010001-0000-1000-8000-011F2000046D")

    /// Called with each message in HID++ long-report form, and the name of the device it came from.
    var onMessage: ((String, [UInt8]) -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]

    func start() {
        guard central == nil else {
            refresh()
            return
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Picks up mice that have connected since the last look.
    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.service]) where peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        TriggerDebug.log("bluetooth state \(central.state.rawValue), access \(CBManager.authorization.rawValue)")
        if central.state == .poweredOn {
            refresh()
        } else {
            peripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.characteristic], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.characteristic {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        TriggerDebug.log("bluetooth channel \(peripheral.name ?? "?"): \(characteristic.isNotifying ? "listening" : "not listening")\(error.map { " (\($0.localizedDescription))" } ?? "")")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, value.count >= 2 else { return }
        // The characteristic leaves out the report ID and device index that a HID report starts with.
        var report: [UInt8] = [0x11, 0xFF] + value.prefix(18)
        report += repeatElement(0, count: max(0, 20 - report.count))
        onMessage?(peripheral.name ?? "", report)
    }
}
