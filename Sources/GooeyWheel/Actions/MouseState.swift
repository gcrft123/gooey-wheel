import Foundation

/// The mouse's settings as last read, so the wheel can show them at once: the wheel reads state
/// on the main thread every frame, and a HID++ round trip takes tens of milliseconds. Reads
/// happen in the background through `refresh()` and after each change. Whenever a value changes,
/// `ActionBehaviors.stateDidChange` is posted on the main thread.
final class MouseState {
    static let shared = MouseState()

    struct DPI: Equatable {
        var current: Int
        var standard: Int
        /// Every value the sensor accepts, in order.
        var supported: [Int]
    }

    struct SmartShift: Equatable {
        /// 1 is free spin, 2 is ratchet.
        var mode: UInt8
        /// The wheel speed at which a ratchet lets go into free spin; 0xFF never does.
        var autoDisengage: UInt8
        var torque: UInt8

        var freeSpin: Bool { mode == 1 }
    }

    struct Haptics: Equatable {
        var enabled: Bool
        /// From 0 to 100.
        var level: UInt8
    }

    struct Battery: Equatable {
        var percent: Int
        /// 0 discharging, 1 charging, 2 almost full, 3 full, 4 charging slowly, 5 invalid, 6 thermal error.
        var chargingStatus: UInt8

        var isCharging: Bool { [1, 2, 4].contains(chargingStatus) }
        var isFull: Bool { chargingStatus == 3 }
    }

    struct Host: Equatable {
        let index: Int
        let name: String
        let paired: Bool
    }

    struct Hosts: Equatable {
        var current: Int
        var list: [Host]
    }

    private(set) var dpi: DPI? { didSet { if dpi != oldValue { changed() } } }
    private(set) var smartShift: SmartShift? { didSet { if smartShift != oldValue { changed() } } }
    private(set) var haptics: Haptics? { didSet { if haptics != oldValue { changed() } } }
    private(set) var battery: Battery? { didSet { if battery != oldValue { changed() } } }
    private(set) var hosts: Hosts? { didSet { if hosts != oldValue { changed() } } }
    /// The waveforms the haptic motor plays, a bit per waveform number. Read once per connection.
    private(set) var hapticWaveforms: UInt32?

    private var mouse: ObjectIdentifier?
    private var supportedDPI: [Int]?
    private var hostsReadAt: TimeInterval = -.infinity
    private var readingHosts: Hosts?
    private var outstanding = 0
    /// Counts connections, so answers meant for a mouse that has since gone are ignored.
    private var generation = 0
    private var waiting: [() -> Void] = []
    private var changePosted = false
    /// A DPI written while another write was on its way, sent when that one is answered.
    private var nextDPI: Int?
    private var writingDPI = false

    private var link: MouseLink { .shared }

    // MARK: Reading

    /// The mouse connected, finished connecting, or went away.
    func mouseChanged() {
        let current = link.mouse.map(ObjectIdentifier.init)
        guard current != mouse else { return }
        mouse = current
        generation += 1
        outstanding = 0
        readingHosts = nil
        nextDPI = nil
        writingDPI = false
        finish()
        supportedDPI = nil
        hostsReadAt = -.infinity
        dpi = nil
        smartShift = nil
        haptics = nil
        hapticWaveforms = nil
        battery = nil
        hosts = nil
        if current != nil {
            readWheels()
            refresh()
        }
        changed()
    }

    /// Reads the mouse's settings again and calls `completion` once every read has been answered.
    /// A refresh already under way is joined instead of repeated. The host list, which hardly
    /// changes, is read again only after a minute.
    func refresh(completion: (() -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        guard outstanding == 0 else { return }
        guard link.mouse != nil else {
            finish()
            return
        }
        outstanding += 1
        if link.has(HIDPPFeature.adjustableDPI) {
            if supportedDPI == nil {
                read(HIDPPFeature.adjustableDPI, 1, [0]) { [weak self] reply in
                    if let reply { self?.supportedDPI = Self.parseDPIList(reply) }
                }
            }
            readDPI()
        }
        if link.has(HIDPPFeature.smartShift) {
            read(HIDPPFeature.smartShift, 1) { [weak self] reply in
                if let reply { self?.smartShift = Self.parseSmartShift(reply) }
            }
        }
        if link.has(HIDPPFeature.haptic) {
            if hapticWaveforms == nil {
                read(HIDPPFeature.haptic, 0) { [weak self] reply in
                    if let reply { self?.hapticWaveforms = Self.parseHapticWaveforms(reply) }
                }
            }
            read(HIDPPFeature.haptic, 1) { [weak self] reply in
                if let reply { self?.haptics = Self.parseHaptics(reply) }
            }
        }
        if link.has(HIDPPFeature.unifiedBattery) {
            read(HIDPPFeature.unifiedBattery, 1) { [weak self] reply in
                if let reply { self?.battery = Self.parseBattery(reply) }
            }
        }
        if link.has(HIDPPFeature.changeHost), ProcessInfo.processInfo.systemUptime - hostsReadAt > 60 {
            readHosts()
        }
        done()
    }

    private func readDPI() {
        read(HIDPPFeature.adjustableDPI, 2, [0]) { [weak self] reply in
            // A read sent before a write still under way would put back the old speed.
            guard let self, let reply, let supported = self.supportedDPI, !supported.isEmpty, !self.writingDPI else { return }
            let standard = Int(reply[3]) << 8 | Int(reply[4])
            var current = Int(reply[1]) << 8 | Int(reply[2])
            // 0 means the sensor is at its default.
            if current == 0 { current = standard }
            self.dpi = DPI(current: current, standard: standard, supported: supported)
        }
    }

    /// Reads which host the mouse is on and the names of the hosts it is paired with. The list
    /// is published once the refresh is over; a host whose details didn't arrive is left out.
    private func readHosts() {
        hostsReadAt = ProcessInfo.processInfo.systemUptime
        read(HIDPPFeature.changeHost, 0) { [weak self] info in
            guard let self, let info else { return }
            let count = Int(info[0])
            self.readingHosts = Hosts(current: Int(info[1]), list: [])
            guard self.link.has(HIDPPFeature.hostsInfo) else {
                // Without names, every channel is offered under its number.
                self.readingHosts?.list = (0..<count).map { Host(index: $0, name: Self.channelName($0), paired: true) }
                return
            }
            for index in 0..<count {
                self.read(HIDPPFeature.hostsInfo, 1, [UInt8(index)]) { [weak self] host in
                    guard let self, let host else { return }
                    let paired = host[1] != 0
                    self.readingHosts?.list.append(Host(index: index, name: Self.channelName(index), paired: paired))
                    let length = Int(host[4])
                    guard paired, length > 0 else { return }
                    self.readName(host: index, length: length, into: []) { [weak self] name in
                        guard let self, !name.isEmpty, let i = self.readingHosts?.list.firstIndex(where: { $0.index == index }) else { return }
                        self.readingHosts?.list[i] = Host(index: index, name: name, paired: true)
                    }
                }
            }
        }
    }

    private static func channelName(_ index: Int) -> String { "Channel \(index + 1)" }

    /// 0x1815 function 3 returns up to 14 bytes of a host's name from an offset.
    private func readName(host: Int, length: Int, into bytes: [UInt8], completion: @escaping (String) -> Void) {
        read(HIDPPFeature.hostsInfo, 3, [UInt8(host), UInt8(bytes.count)]) { [weak self] reply in
            guard let reply else { return }
            let piece = reply[2..<min(reply.count, 2 + length - bytes.count)]
            let all = bytes + piece
            if all.count < length, !piece.isEmpty {
                self?.readName(host: host, length: length, into: all, completion: completion)
            } else {
                completion(String(decoding: all.prefix { $0 != 0 }, as: UTF8.self))
            }
        }
    }

    /// The wheels' resolutions, needed to turn their reports into notches. Read once per connection.
    private func readWheels() {
        if link.has(HIDPPFeature.hiResWheel) {
            link.call(HIDPPFeature.hiResWheel, 0) { reply in
                guard let reply, reply[0] > 0 else { return }
                MouseWheelEvents.countsPerNotch = Double(reply[0])
                if reply[2] > 0 { MouseState.notchesPerTurn = Double(reply[2]) }
            }
        }
        if link.has(HIDPPFeature.thumbWheel) {
            link.call(HIDPPFeature.thumbWheel, 0) { reply in
                guard let reply else { return }
                let diverted = Double(Int(reply[2]) << 8 | Int(reply[3]))
                if diverted > 0 { MouseWheelEvents.thumbCountsPerNotch = diverted / MouseState.notchesPerTurn }
                MouseWheelEvents.thumbRightSign = reply[4] != 0 ? 1 : -1
            }
        }
    }

    /// Ratchet notches in a turn of the main wheel.
    private static var notchesPerTurn: Double = 24

    /// A read counted toward the refresh under way. `handle` gets nil when there was no answer.
    private func read(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], handle: @escaping ([UInt8]?) -> Void) {
        outstanding += 1
        let generation = generation
        link.call(feature, function, params) { [weak self] reply in
            guard let self, self.generation == generation else { return }
            handle(reply)
            self.done()
        }
    }

    private func done() {
        outstanding -= 1
        if outstanding == 0 { finish() }
    }

    private func finish() {
        if let readingHosts {
            hosts = Hosts(current: readingHosts.current, list: readingHosts.list.sorted { $0.index < $1.index })
            self.readingHosts = nil
        }
        let callbacks = waiting
        waiting.removeAll()
        for callback in callbacks { callback() }
    }

    /// A notification from the mouse, such as a change of battery level.
    func notified(_ feature: UInt16, _ event: UInt8, _ params: [UInt8]) {
        if feature == HIDPPFeature.unifiedBattery, event == 0, let battery = Self.parseBattery(params) {
            self.battery = battery
        }
    }

    private func changed() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.async { [weak self] in
            self?.changePosted = false
            NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
        }
    }

    // MARK: Writing

    /// Sets the sensor's DPI, snapped to a value it accepts. The new value shows at once; if the
    /// mouse refuses it, the value it has is read back. `completion` gets whether it was accepted.
    func setDPI(_ value: Int, completion: ((Bool) -> Void)? = nil) {
        guard var dpi else {
            completion?(false)
            return
        }
        dpi.current = Self.snap(value, to: dpi.supported)
        self.dpi = dpi
        guard !writingDPI else {
            nextDPI = dpi.current
            completion?(true)
            return
        }
        writingDPI = true
        let target = dpi.current
        link.call(HIDPPFeature.adjustableDPI, 3, [0, UInt8(target >> 8), UInt8(target & 0xFF)]) { [weak self] reply in
            guard let self else { return }
            self.writingDPI = false
            if reply == nil { self.refresh() }
            completion?(reply != nil)
            if let next = self.nextDPI {
                self.nextDPI = nil
                if next != target { self.setDPI(next) }
            }
        }
    }

    /// Turns free spin on or off, keeping the auto-disengage speed and torque the mouse has. All
    /// three are written: the MX Master 4 ignores a write that leaves any of them out.
    func setFreeSpin(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        link.call(HIDPPFeature.smartShift, 1) { [weak self] reply in
            guard let self, let reply, var state = Self.parseSmartShift(reply) else {
                completion?(false)
                return
            }
            state.mode = on ? 1 : 2
            self.smartShift = state
            self.link.call(HIDPPFeature.smartShift, 2, [state.mode, state.autoDisengage, state.torque]) { [weak self] written in
                if written == nil { self?.refresh() }
                completion?(written != nil)
            }
        }
    }

    /// Turns the mouse's haptic feedback on or off, keeping its strength.
    func setHapticsEnabled(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        link.call(HIDPPFeature.haptic, 1) { [weak self] reply in
            guard let self, let reply, var state = Self.parseHaptics(reply) else {
                completion?(false)
                return
            }
            state.enabled = on
            self.haptics = state
            self.link.call(HIDPPFeature.haptic, 2, [on ? 1 : 0, state.level]) { [weak self] written in
                if written == nil { self?.refresh() }
                completion?(written != nil)
            }
        }
    }

    /// Moves the mouse to another of its paired hosts. The mouse doesn't answer: it drops this
    /// Mac and connects to the other host.
    func switchHost(to index: Int) {
        guard let hosts, index != hosts.current, hosts.list.contains(where: { $0.index == index && $0.paired }) else { return }
        link.post(HIDPPFeature.changeHost, 1, [UInt8(index)])
    }

    // MARK: Parsing

    /// 0x2201 function 1: the sensor, then 16-bit values ending with 0. A value of 0xE000 or more
    /// is a step (its low 13 bits) between the value before it and the value after it.
    static func parseDPIList(_ reply: [UInt8]) -> [Int] {
        var raw: [Int] = []
        var i = 1
        while i + 1 < reply.count {
            let value = Int(reply[i]) << 8 | Int(reply[i + 1])
            if value == 0 { break }
            raw.append(value)
            i += 2
        }
        var values: [Int] = []
        var j = 0
        while j < raw.count {
            if raw[j] >= 0xE000, let low = values.last, j + 1 < raw.count {
                let step = raw[j] & 0x1FFF
                if step > 0 { values += stride(from: low + step, through: raw[j + 1], by: step) }
                j += 2
            } else {
                values.append(raw[j])
                j += 1
            }
        }
        return values
    }

    static func snap(_ value: Int, to supported: [Int]) -> Int {
        supported.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    static func parseSmartShift(_ reply: [UInt8]) -> SmartShift? {
        guard reply.count >= 3, reply[0] == 1 || reply[0] == 2 else { return nil }
        return SmartShift(mode: reply[0], autoDisengage: reply[1], torque: reply[2])
    }

    static func parseHaptics(_ reply: [UInt8]) -> Haptics? {
        guard reply.count >= 2 else { return nil }
        return Haptics(enabled: reply[0] & 0x01 != 0, level: reply[1])
    }

    /// 0x19B0 function 0: capabilities, with the waveforms the motor plays as a big-endian bit
    /// mask in bytes 4 to 7.
    static func parseHapticWaveforms(_ reply: [UInt8]) -> UInt32? {
        guard reply.count >= 8 else { return nil }
        let mask = reply[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return mask == 0 ? nil : mask
    }

    /// 0x1004 function 1 and event 0: percentage, level bits, charging status, external power.
    /// A mouse that doesn't report a percentage gives 0 there and only the level.
    static func parseBattery(_ reply: [UInt8]) -> Battery? {
        guard reply.count >= 3 else { return nil }
        var percent = Int(reply[0])
        if percent == 0 {
            switch reply[1] {
            case 8...: percent = 100
            case 4..<8: percent = 50
            case 2..<4: percent = 20
            case 1: percent = 5
            default: return nil
            }
        }
        return Battery(percent: min(percent, 100), chargingStatus: reply[2])
    }
}
