import AppKit

/// Settings of the Logitech mouse, changed over HID++ through `MouseState`, and macOS's scroll
/// direction.
enum MouseActions {
    /// Reads the mouse's settings again in the background. The wheel calls this when it opens.
    static func refresh() {
        MouseState.shared.refresh()
    }

    private static var state: MouseState { .shared }

    private static func available(_ feature: UInt16) -> () -> Bool {
        { MouseLink.shared.has(feature) }
    }

    static let behaviors: [String: ActionBehavior] = [
        "mouse.pointerSpeed": pointerSpeed,
        "mouse.precision": precision,
        "mouse.smartShift": freeSpin,
        "mouse.haptics": haptics,
        "mouse.scrollDirection": naturalScrolling,
        "device.easySwitch": easySwitch,
        "device.battery": battery,
    ]

    // MARK: Pointer speed

    /// Choosing Pointer Speed steps through these, from the one above the current speed.
    static let presets = [800, 1000, 1600, 2400, 4000]

    /// A level from 0 to 1 for a DPI, on a logarithmic scale: a notch near 400 DPI changes the
    /// speed about as noticeably as a notch near 4000.
    static func level(forDPI dpi: Int, in supported: [Int]) -> Double {
        guard let low = supported.first, let high = supported.last, high > low else { return 0 }
        return clamp01(log(Double(dpi) / Double(low)) / log(Double(high) / Double(low)))
    }

    static func dpi(forLevel level: Double, in supported: [Int]) -> Int {
        guard let low = supported.first, let high = supported.last, high > low else { return supported.first ?? 0 }
        let value = Double(low) * pow(Double(high) / Double(low), clamp01(level))
        return MouseState.snap(Int(value.rounded()), to: supported)
    }

    static func nextPreset(after current: Int, in supported: [Int]) -> Int {
        let presets = Set(presets.map { MouseState.snap($0, to: supported) }).sorted()
        return presets.first { $0 > current } ?? presets.first ?? current
    }

    private static var pointerSpeed: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.adjustableDPI)) { _ in
            guard let dpi = state.dpi else { throw ActionError.unavailable("Pointer Speed") }
            forgetPrecision()
            state.setDPI(nextPreset(after: dpi.current, in: dpi.supported))
        }
        behavior.level = LevelControl(
            read: { state.dpi.map { level(forDPI: $0.current, in: $0.supported) } },
            write: { value in
                guard let dpi = state.dpi else { throw ActionError.unavailable("Pointer Speed") }
                forgetPrecision()
                state.setDPI(MouseActions.dpi(forLevel: value, in: dpi.supported))
            },
            // A 24th of the scale is about a sixth faster or slower, and always at least one of
            // the sensor's steps.
            detent: 1.0 / 24,
            format: { value in
                guard let dpi = state.dpi else { return "" }
                return "\(MouseActions.dpi(forLevel: value, in: dpi.supported)) DPI"
            }
        )
        return behavior
    }

    // MARK: Precision mode

    /// The DPI to go back to when precision mode is turned off. Kept in the app's defaults, so
    /// it survives a relaunch.
    private static let returnKey = "MousePrecisionReturnDPI"

    private static var returnDPI: Int? {
        let value = UserDefaults.standard.integer(forKey: returnKey)
        return value > 0 ? value : nil
    }

    private static func forgetPrecision() {
        UserDefaults.standard.removeObject(forKey: returnKey)
    }

    /// The slow speed for precision mode: a third of the usual speed, at most 400 DPI.
    static func precisionDPI(from dpi: Int, in supported: [Int]) -> Int {
        MouseState.snap(min(400, dpi / 3), to: supported)
    }

    private static var precision: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.adjustableDPI)) { _ in
            guard let dpi = state.dpi else { throw ActionError.unavailable("Precision Mode") }
            if let back = returnDPI, dpi.current == precisionDPI(from: back, in: dpi.supported) {
                forgetPrecision()
                state.setDPI(back)
            } else {
                UserDefaults.standard.set(dpi.current, forKey: returnKey)
                state.setDPI(precisionDPI(from: dpi.current, in: dpi.supported))
            }
        }
        behavior.isOn = { _ in
            guard let dpi = state.dpi else { return nil }
            guard let back = returnDPI else { return false }
            return dpi.current == precisionDPI(from: back, in: dpi.supported)
        }
        return behavior
    }

    // MARK: Free spin and haptics

    private static var freeSpin: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.smartShift)) { _ in
            guard let smartShift = state.smartShift else { throw ActionError.unavailable("Free Spin") }
            state.setFreeSpin(!smartShift.freeSpin)
        }
        behavior.isOn = { _ in state.smartShift?.freeSpin }
        return behavior
    }

    private static var haptics: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.haptic)) { _ in
            guard let haptics = state.haptics else { throw ActionError.unavailable("Mouse Haptics") }
            state.setHapticsEnabled(!haptics.enabled)
        }
        behavior.isOn = { _ in state.haptics?.enabled }
        return behavior
    }

    // MARK: Scroll direction

    private static var naturalScrolling: ActionBehavior {
        var behavior = ActionBehavior(run: { _ in try NaturalScrolling.set(!NaturalScrolling.isOn) })
        behavior.isOn = { _ in NaturalScrolling.isOn }
        return behavior
    }

    // MARK: Easy-Switch

    static func choices(for hosts: MouseState.Hosts?) -> [LiveChoice] {
        guard let hosts else { return [] }
        return hosts.list.filter(\.paired).map {
            LiveChoice(id: "host\($0.index)", title: $0.name, symbol: "desktopcomputer", isCurrent: $0.index == hosts.current)
        }
    }

    private static var easySwitch: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.changeHost))
        behavior.choices = { _ in
            MouseLink.shared.mouse == nil ? [] : choices(for: state.hosts)
        }
        behavior.choose = { choice, _ in
            guard !choice.isCurrent else { return }
            guard MouseLink.shared.mouse != nil, let index = Int(choice.id.dropFirst("host".count)) else {
                throw ActionError.unavailable("Easy-Switch")
            }
            state.switchHost(to: index)
            ActionFeedback.confirm("Mouse switching to \(choice.title)", symbol: "arrow.left.arrow.right.square")
        }
        return behavior
    }

    // MARK: Battery

    static func batteryDetail(_ battery: MouseState.Battery) -> String {
        if battery.isCharging { return "\(battery.percent)% · Charging" }
        if battery.isFull { return "\(battery.percent)% · Charged" }
        return "\(battery.percent)%"
    }

    static func batterySymbol(_ battery: MouseState.Battery) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        let steps = [0, 25, 50, 75, 100]
        let nearest = steps.min { abs($0 - battery.percent) < abs($1 - battery.percent) } ?? 100
        return "battery.\(nearest)percent"
    }

    private static var battery: ActionBehavior {
        var behavior = ActionBehavior(isAvailable: available(HIDPPFeature.unifiedBattery))
        behavior.liveDetail = { _ in state.battery.map(batteryDetail) }
        behavior.liveSymbol = { _ in state.battery.map(batterySymbol) }
        return behavior
    }

    // MARK: Checks

    private static var foundNoMouse = false

    /// Opens the mouse for a check, or skips it when there is none.
    private static func connect(_ ctx: SelfTest.Context) throws -> LogiLink {
        MouseLink.shared.startWithoutButton()
        guard !foundNoMouse, ctx.wait(upTo: 4, until: { MouseLink.shared.mouse != nil }), let mouse = MouseLink.shared.mouse else {
            foundNoMouse = true
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            try ctx.skip(access ? "no Logitech HID++ mouse connected" : "Input Monitoring not granted")
        }
        var refreshed = false
        state.refresh { refreshed = true }
        try ctx.expect(ctx.wait(upTo: 5, until: { refreshed }), "refresh didn't finish")
        return mouse
    }

    /// Runs `body` and fails if it took longer than the wheel can wait in a frame.
    private static func quickly<T>(_ ctx: SelfTest.Context, _ what: String, _ body: () -> T) throws -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        try ctx.expect(ms < 2, "\(what) took \(String(format: "%.2f", ms)) ms")
        return value
    }

    private static func behavior(_ id: String) -> ActionBehavior { behaviors[id]! }

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("mouse.dpiListParsing") { ctx in
                // As the MX Master 4 answers: 200 to 8000 in steps of 50.
                let range = MouseState.parseDPIList([0x00, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0x00, 0x00])
                try ctx.expect(range.first == 200 && range.last == 8000 && range.count == 157, "range \(range.first ?? 0)…\(range.last ?? 0) × \(range.count)")
                let list = MouseState.parseDPIList([0x00, 0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0x00, 0x00])
                try ctx.expect(list == [400, 800, 1600], "list \(list)")
                try ctx.expect(MouseState.snap(1324, to: range) == 1300 && MouseState.snap(9000, to: range) == 8000, "snap")
            },
            SelfTest.Case("mouse.pointerSpeedScale") { ctx in
                let range = Array(stride(from: 200, through: 8000, by: 50))
                for dpi in [200, 400, 1000, 1300, 4000, 8000] {
                    let back = MouseActions.dpi(forLevel: level(forDPI: dpi, in: range), in: range)
                    try ctx.expect(back == dpi, "\(dpi) → \(back)")
                }
                try ctx.expect(abs(level(forDPI: 1265, in: range) - 0.5) < 0.01, "the middle is near 1265 DPI")
                // Each notch moves at least one of the sensor's steps, at either end, both ways.
                for dpi in [200, 250, 1000, 7950, 8000] {
                    let here = level(forDPI: dpi, in: range)
                    let up = MouseActions.dpi(forLevel: here + 1.0 / 24, in: range)
                    let down = MouseActions.dpi(forLevel: here - 1.0 / 24, in: range)
                    try ctx.expect(up > dpi || dpi == 8000, "\(dpi) up → \(up)")
                    try ctx.expect(down < dpi || dpi == 200, "\(dpi) down → \(down)")
                }
                let up = MouseActions.dpi(forLevel: level(forDPI: 1000, in: range) + 1.0 / 24, in: range)
                ctx.note("1000 + 1 notch = \(up)")
                try ctx.expect((1100...1250).contains(up), "a notch from 1000 is \(up)")
                try ctx.expect(nextPreset(after: 1300, in: range) == 1600, "after 1300")
                try ctx.expect(nextPreset(after: 4000, in: range) == 800, "after 4000 it starts over")
                try ctx.expect(nextPreset(after: 200, in: range) == 800, "after 200")
                try ctx.expect(precisionDPI(from: 1300, in: range) == 400 && precisionDPI(from: 900, in: range) == 300
                    && precisionDPI(from: 400, in: range) == 200, "precision speeds")
            },
            SelfTest.Case("mouse.wheelEvents") { ctx in
                let saved = (MouseWheelEvents.countsPerNotch, MouseWheelEvents.thumbCountsPerNotch, MouseWheelEvents.thumbRightSign)
                defer { (MouseWheelEvents.countsPerNotch, MouseWheelEvents.thumbCountsPerNotch, MouseWheelEvents.thumbRightSign) = saved }
                MouseWheelEvents.countsPerNotch = 15
                MouseWheelEvents.thumbCountsPerNotch = 5
                MouseWheelEvents.thumbRightSign = -1
                // As seen from the MX Master 4: high resolution, 2 periods, +30 counts.
                try ctx.expect(MouseWheelEvents.vertical([0x12, 0x00, 0x1E]) == 2, "two notches up")
                try ctx.expect(MouseWheelEvents.vertical([0x02, 0xFF, 0xFF]) == -1, "low resolution, one notch down")
                try ctx.expect(MouseWheelEvents.horizontal([0xFF, 0xF6, 0x00, 0x10, 0x02]) == 2, "thumb wheel right")
                var got: [(Double, Double)] = []
                let before = MouseWheelEvents.onWheel
                MouseWheelEvents.onWheel = { got.append(($0, $1)) }
                defer { MouseWheelEvents.onWheel = before }
                MouseWheelEvents.handle(HIDPPFeature.hiResWheel, 0, [0x10, 0x00, 0x0F])
                MouseWheelEvents.handle(HIDPPFeature.thumbWheel, 0, [0x00, 0x05, 0x00, 0x10, 0x02])
                MouseWheelEvents.handle(HIDPPFeature.thumbWheel, 0, [0x00, 0x00, 0x00, 0x10, 0x03])
                MouseWheelEvents.handle(HIDPPFeature.unifiedBattery, 0, [0x32, 0x04, 0x00])
                try ctx.expect(got.count == 2 && got[0] == (1, 0) && got[1] == (0, -1), "callbacks \(got)")
                try ctx.expect(MouseWheelEvents.isActive(), "recent movement counts as active")
            },
            SelfTest.Case("device.batteryText") { ctx in
                let half = MouseState.parseBattery([0x32, 0x04, 0x00, 0x00])
                try ctx.expect(half == MouseState.Battery(percent: 50, chargingStatus: 0), "parsed \(String(describing: half))")
                try ctx.expect(batteryDetail(half!) == "50%" && batterySymbol(half!) == "battery.50percent", "50%")
                let charging = MouseState.Battery(percent: 81, chargingStatus: 1)
                try ctx.expect(batteryDetail(charging) == "81% · Charging" && batterySymbol(charging) == "battery.100percent.bolt", "charging")
                try ctx.expect(batterySymbol(MouseState.Battery(percent: 9, chargingStatus: 0)) == "battery.0percent", "low")
                try ctx.expect(MouseState.parseBattery([0x00, 0x08, 0x03])?.percent == 100, "level only")
            },
            SelfTest.Case("device.easySwitchChoices") { ctx in
                let hosts = MouseState.Hosts(current: 0, list: [
                    MouseState.Host(index: 0, name: "Desk", paired: true),
                    MouseState.Host(index: 1, name: "Channel 2", paired: false),
                    MouseState.Host(index: 2, name: "Work", paired: true),
                ])
                let choices = choices(for: hosts)
                try ctx.expect(choices.map(\.title) == ["Desk", "Work"], "paired only: \(choices.map(\.title))")
                try ctx.expect(choices.map(\.isCurrent) == [true, false], "current marked")
                try ctx.expect(MouseActions.choices(for: nil).isEmpty, "no mouse, no choices")
                // 0x1814 function 1 at index 14, host 2: report 0x11, device 0xFF, then function 1
                // with this app's software ID.
                let frame = LogiLink.frame(feature: 14, function: 1, params: [2])
                try ctx.expect(Array(frame.prefix(6)) == [0x11, 0xFF, 0x0E, 0x1B, 0x02, 0x00] && frame.count == 20, "frame \(frame.prefix(6).map { String(format: "%02x", $0) })")
            },
            SelfTest.Case("mouse.link") { ctx in
                let mouse = try connect(ctx)
                let names: [UInt16: String] = [0x1004: "battery", 0x1814: "host", 0x1815: "hosts", 0x19B0: "haptic", 0x2111: "smartshift", 0x2121: "wheel", 0x2150: "thumbwheel", 0x2201: "dpi"]
                ctx.note(mouse.name + " " + LogiLink.knownFeatures.map { "\(names[$0] ?? "?")=\(mouse.features[$0] ?? 0)" }.joined(separator: " "))
                try ctx.expect(LogiLink.knownFeatures.allSatisfy { mouse.features[$0] != nil }, "features not all looked up")
                for id in ["mouse.pointerSpeed", "mouse.precision", "mouse.smartShift", "mouse.haptics", "device.easySwitch", "device.battery"] {
                    let available = try quickly(ctx, "\(id) isAvailable") { behavior(id).isAvailable() }
                    ctx.note("\(id.split(separator: ".").last!) \(available ? "available" : "unavailable")")
                }
            },
            SelfTest.Case("mouse.readsAreCached") { ctx in
                _ = try connect(ctx)
                let speed = behavior("mouse.pointerSpeed")
                let level = try quickly(ctx, "pointer speed read") { speed.level?.read() }
                if let level, let format = speed.level?.format { ctx.note(format(level)) }
                for id in ["mouse.precision", "mouse.smartShift", "mouse.haptics", "mouse.scrollDirection"] {
                    let on = try quickly(ctx, "\(id) isOn") { behavior(id).isOn?(.current) }
                    ctx.note("\(id.split(separator: ".").last!) \(on.map { $0 ? "on" : "off" } ?? "unknown")")
                }
                let battery = try quickly(ctx, "battery") { behavior("device.battery").liveDetail?(.current) }
                ctx.note("battery \(battery ?? "unknown")")
                let hosts = try quickly(ctx, "hosts") { behavior("device.easySwitch").choices?(.current) ?? [] }
                ctx.note("hosts " + hosts.map { $0.title + ($0.isCurrent ? "*" : "") }.joined(separator: ","))
                if MouseLink.shared.has(HIDPPFeature.adjustableDPI) { try ctx.expect(level != nil, "DPI not read") }
                if MouseLink.shared.has(HIDPPFeature.unifiedBattery) {
                    try ctx.expect(battery?.range(of: #"^\d+%"#, options: .regularExpression) != nil, "battery \(battery ?? "nil")")
                }
                if MouseLink.shared.has(HIDPPFeature.changeHost) {
                    try ctx.expect(hosts.filter(\.isCurrent).count == 1, "one current host among \(hosts.map(\.title))")
                }
            },
            SelfTest.Case("mouse.pointerSpeedWritesCurrentValue") { ctx in
                _ = try connect(ctx)
                guard let before = state.dpi, let level = behavior("mouse.pointerSpeed").level else { try ctx.skip("no DPI control") }
                let value = try ctx.expectValue(level.read(), "no level")
                // Only the value the mouse already has is written.
                try ctx.expect(MouseActions.dpi(forLevel: value, in: before.supported) == before.current, "would change the DPI")
                var accepted: Bool?
                state.setDPI(before.current) { accepted = $0 }
                try ctx.expect(ctx.wait(upTo: 2, until: { accepted != nil }) && accepted == true, "write refused")
                var reread = false
                state.refresh { reread = true }
                ctx.wait(upTo: 2, until: { reread })
                try ctx.expect(state.dpi?.current == before.current, "DPI \(state.dpi?.current ?? 0), was \(before.current)")
                ctx.note("wrote \(before.current) DPI back")
            },
            SelfTest.Case("mouse.smartShiftWritesCurrentValue") { ctx in
                _ = try connect(ctx)
                guard let before = state.smartShift else { try ctx.skip("no SmartShift") }
                var accepted: Bool?
                state.setFreeSpin(before.freeSpin) { accepted = $0 }
                try ctx.expect(ctx.wait(upTo: 2, until: { accepted != nil }) && accepted == true, "write refused")
                var reread = false
                state.refresh { reread = true }
                ctx.wait(upTo: 2, until: { reread })
                try ctx.expect(state.smartShift == before, "now \(String(describing: state.smartShift)), was \(before)")
                ctx.note("mode \(before.mode) threshold \(before.autoDisengage) torque \(before.torque)")
            },
            SelfTest.Case("mouse.hapticsWritesCurrentValue") { ctx in
                _ = try connect(ctx)
                guard let before = state.haptics else { try ctx.skip("no haptics") }
                var accepted: Bool?
                state.setHapticsEnabled(before.enabled) { accepted = $0 }
                try ctx.expect(ctx.wait(upTo: 2, until: { accepted != nil }) && accepted == true, "write refused")
                var reread = false
                state.refresh { reread = true }
                ctx.wait(upTo: 2, until: { reread })
                try ctx.expect(state.haptics == before, "now \(String(describing: state.haptics)), was \(before)")
                ctx.note("enabled \(before.enabled) level \(before.level)")
            },
            SelfTest.Case("mouse.hapticWaveformChoice") { ctx in
                // Waveforms 0 to 4 and 27 (whisper collision).
                let all = MouseState.parseHapticWaveforms([0, 0, 0, 0, 0x08, 0x00, 0x00, 0x1F])
                try ctx.expect(all == 0x0800_001F, "parsed \(String(describing: all))")
                try ctx.expect(MouseState.parseHapticWaveforms([0, 0, 0, 0, 0, 0, 0, 0]) == nil, "an empty list is known")
                try ctx.expect(MouseHaptics.Kind.hover.waveform(available: all) == .whisperCollision, "hover")
                try ctx.expect(MouseHaptics.Kind.hover.waveform(available: 0x1F) == .subtleCollision, "hover without whisper")
                try ctx.expect(MouseHaptics.Kind.open.waveform(available: 0x01) == .sharpStateChange, "open with only sharp")
                try ctx.expect(MouseHaptics.Kind.back.waveform(available: 0x01) == nil, "back with nothing fitting")
                for kind in MouseHaptics.Kind.allCases {
                    try ctx.expect(kind.waveform(available: nil) == kind.waveforms.first, "\(kind) with the list unknown")
                }
            },
            SelfTest.Case("mouse.hapticTick") { ctx in
                let mouse = try connect(ctx)
                guard let haptics = state.haptics else { try ctx.skip("no haptics") }
                guard haptics.enabled else { try ctx.skip("haptics are turned off on the mouse") }
                guard MouseHaptics.enabled else { try ctx.skip("Mouse Haptic Feedback is turned off in the menu") }
                ctx.note("waveforms \(state.hapticWaveforms.map { String($0, radix: 16) } ?? "unknown")")
                ctx.wait(upTo: 2, until: { !mouse.isBusy })
                // One tick, the faintest waveform.
                let start = DispatchTime.now().uptimeNanoseconds
                try ctx.expect(MouseHaptics.play(.hover), "no tick sent")
                ctx.note(String(format: "sending took %.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
                try ctx.expect(!MouseHaptics.play(.hover), "a second tick within 40 ms was sent")
                // The mouse still answers requests after it.
                var answered = false
                MouseLink.shared.call(HIDPPFeature.haptic, 1) { answered = $0 != nil }
                try ctx.expect(ctx.wait(upTo: 2, until: { answered }), "the mouse stopped answering after the tick")
            },
            SelfTest.Case("mouse.hapticTickOverBluetooth") { ctx in
                _ = try connect(ctx)
                guard let haptics = state.haptics, haptics.enabled else { try ctx.skip("no haptics, or turned off on the mouse") }
                guard MouseHaptics.enabled else { try ctx.skip("Mouse Haptic Feedback is turned off in the menu") }
                // The Bluetooth channel is found a moment after the mouse.
                var sent = false
                ctx.wait(upTo: 3, until: {
                    sent = MouseHaptics.play(.hover, over: .bluetooth)
                    return sent
                })
                try ctx.expect(sent, "no tick sent; is Bluetooth allowed?")
                var answered = false
                MouseLink.shared.call(HIDPPFeature.haptic, 1) { answered = $0 != nil }
                try ctx.expect(ctx.wait(upTo: 2, until: { answered }), "the mouse stopped answering after the tick")
            },
            SelfTest.Case("mouse.naturalScrollingWritesCurrentValue") { ctx in
                let before = NaturalScrolling.isOn
                ctx.note(before ? "on" : "off")
                // Writes the value it already has, which changes nothing.
                try NaturalScrolling.set(before)
                try ctx.expect(NaturalScrolling.isOn == before, "changed")
                let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool
                try ctx.expect(global == nil || global == before, "the global default says \(String(describing: global))")
            },
            SelfTest.Case("device.easySwitchNeverChoosesTheCurrentHost") { ctx in
                let mouse = try connect(ctx)
                guard MouseLink.shared.has(HIDPPFeature.changeHost) else { try ctx.skip("no Easy-Switch") }
                var sent: [[UInt8]] = []
                MouseLink.shared.interceptPosts = { sent.append($0) }
                defer { MouseLink.shared.interceptPosts = nil }
                let easySwitch = behavior("device.easySwitch")
                let choices = easySwitch.choices?(.current) ?? []
                let current = try ctx.expectValue(choices.first(where: \.isCurrent), "no current host in \(choices.map(\.title))")
                try easySwitch.choose?(current, .current)
                try easySwitch.choose?(LiveChoice(id: current.id, title: current.title, symbol: current.symbol), .current)
                ctx.wait(0.2)
                try ctx.expect(sent.isEmpty, "choosing the current host sent \(sent.count) request(s)")
                // The request a switch would send, caught before it reaches the mouse.
                MouseLink.shared.post(HIDPPFeature.changeHost, 1, [1])
                let index = try ctx.expectValue(mouse.features[HIDPPFeature.changeHost], "no index")
                try ctx.expect(sent.count == 1 && Array(sent[0].prefix(5)) == [0x11, 0xFF, index, 0x1B, 0x01], "request \(sent.first?.prefix(5).map { String(format: "%02x", $0) } ?? [])")
            },
        ]
    }
}

private extension SelfTest.Context {
    func expectValue<T>(_ value: T?, _ message: @autoclosure () -> String) throws -> T {
        guard let value else { throw SelfTest.Failure(message: message()) }
        return value
    }
}
