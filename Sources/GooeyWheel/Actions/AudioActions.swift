import AppKit
import AudioToolbox
import CoreAudio

/// Sound actions: the output volume and mute, the sound devices in use, and muting the
/// microphone. They work through CoreAudio, which needs no permission.
enum AudioActions {
    static let behaviors: [String: ActionBehavior] = {
        // From the first time the wheel looks up an action, so the wheel's state stays current
        // and a muted microphone stays muted on a newly connected device.
        AudioWatcher.shared.start()

        var volume = ActionBehavior(isAvailable: { AudioDevice.defaultDevice(.output)?.canSetVolume(.output) ?? false })
        volume.level = LevelControl(
            read: { AudioDevice.defaultDevice(.output)?.volume(.output) },
            write: { value in
                guard let device = AudioDevice.defaultDevice(.output) else { throw ActionError.unavailable("No sound output") }
                // As with the volume keys, changing the volume turns mute off.
                if device.isMuted(.output) == true { try device.setMuted(false, .output) }
                try device.setVolume(value, .output)
            },
            detent: 1.0 / 32,
            symbol: { level in
                if level <= 0.001 || OutputMute.isOn == true { return "speaker.slash.fill" }
                if level < 1.0 / 3 { return "speaker.wave.1.fill" }
                return level < 2.0 / 3 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            }
        )

        var mute = ActionBehavior(isAvailable: { OutputMute.isOn != nil }) { _ in
            try OutputMute.set(!(OutputMute.isOn ?? false))
        }
        mute.isOn = { _ in OutputMute.isOn }
        mute.liveSymbol = { _ in OutputMute.isOn.map { $0 ? "speaker.slash.fill" : "speaker.wave.2.fill" } }

        var micMute = ActionBehavior(isAvailable: { MicMute.isOn != nil }) { _ in
            try MicMute.set(!(MicMute.isOn ?? false))
        }
        micMute.isOn = { _ in MicMute.isOn }
        micMute.liveSymbol = { _ in MicMute.isOn.map { $0 ? "mic.slash.fill" : "mic.fill" } }

        return [
            "media.volume": volume,
            "media.mute": mute,
            "media.output": devicePicker(.output),
            "media.input": devicePicker(.input),
            "system.micMute": micMute,
        ]
    }()

    /// Lists the sound devices one way and makes the chosen one the default.
    private static func devicePicker(_ direction: AudioDevice.Direction) -> ActionBehavior {
        var picker = ActionBehavior()
        picker.choices = { _ in
            let current = AudioDevice.defaultDevice(direction)
            return AudioWatcher.shared.devices(direction).map {
                LiveChoice(id: $0.key, title: $0.name, symbol: $0.symbol, isCurrent: $0.device == current)
            }
        }
        picker.choose = { choice, _ in
            guard let listed = AudioWatcher.shared.devices(direction).first(where: { $0.key == choice.id }) else {
                throw ActionError.failed("\(choice.title) is no longer connected")
            }
            try AudioDevice.setDefault(listed.device, direction)
        }
        picker.liveDetail = { _ in
            guard let current = AudioDevice.defaultDevice(direction) else { return nil }
            return AudioWatcher.shared.devices(direction).first { $0.device == current }?.name ?? current.name
        }
        return picker
    }

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("audio.volumeReads") { ctx in
                guard let device = AudioDevice.defaultDevice(.output) else { try ctx.skip("no sound output") }
                let behavior = try behavior("media.volume")
                ctx.note(device.name)
                guard behavior.isAvailable() else {
                    try ctx.expect(behavior.level?.read() == nil, "a device with no volume control reports a level")
                    try ctx.skip("\(device.name) has no volume control")
                }
                let level = behavior.level?.read()
                try ctx.expect(level.map { (0...1).contains($0) } == true, "level \(String(describing: level))")
                let symbol = behavior.level?.symbol?(level ?? 0) ?? ""
                ctx.note(String(format: "%.3f", level ?? -1))
                ctx.note(symbol)
                try ctx.expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "no symbol \(symbol)")
                try ctx.expect(behavior.level?.detent == 1.0 / 32, "detent")
            },
            SelfTest.Case("audio.volumeWritesBack") { ctx in
                // The volume is set to the value it has, so nothing can be heard.
                let behavior = try behavior("media.volume")
                guard behavior.isAvailable(), let level = behavior.level, let before = level.read() else {
                    try ctx.skip("the sound output has no volume control")
                }
                // Writing the volume turns mute off, which would be heard.
                if OutputMute.isOn == true { try ctx.skip("the sound output is muted") }
                try level.write(before)
                let after = level.read() ?? -1
                ctx.note(String(format: "%.3f → %.3f", before, after))
                try ctx.expect(abs(after - before) < 0.005, "volume moved from \(before) to \(after)")
            },
            SelfTest.Case("audio.muteWritesBack") { ctx in
                guard let muted = OutputMute.isOn else { try ctx.skip("the sound output has no mute or volume control") }
                let behavior = try behavior("media.mute")
                try ctx.expect(behavior.isOn?(.current) == muted && behavior.isAvailable(), "isOn and isAvailable")
                try ctx.expect(behavior.liveSymbol?(.current) == (muted ? "speaker.slash.fill" : "speaker.wave.2.fill"), "symbol")
                ctx.note(muted ? "muted" : "not muted")
                try OutputMute.set(muted)
                try ctx.expect(OutputMute.isOn == muted, "mute changed")
            },
            SelfTest.Case("audio.outputChoices") { ctx in
                try checkPicker("media.output", .output, ctx)
            },
            SelfTest.Case("audio.inputChoices") { ctx in
                try checkPicker("media.input", .input, ctx)
            },
            SelfTest.Case("audio.deviceSymbolsExist") { ctx in
                let names = ["airpodsmax", "airpodspro", "airpods", "beats.headphones", "headphones", "display", "rectangle.stack",
                             "airplayaudio", "iphone", "waveform", "hifispeaker.fill", "mic.fill", "speaker.wave.1.fill",
                             "speaker.wave.3.fill", "mic.slash.fill"]
                let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
                try ctx.expect(missing.isEmpty, "missing: \(missing.joined(separator: ", "))")
            },
            SelfTest.Case("system.micMuteWritesBack") { ctx in
                guard let input = AudioDevice.defaultDevice(.input), let muted = MicMute.isOn else {
                    try ctx.skip("the default input has no mute or volume control")
                }
                let behavior = try behavior("system.micMute")
                try ctx.expect(behavior.isOn?(.current) == muted, "isOn")
                try ctx.expect(behavior.liveSymbol?(.current) == (muted ? "mic.slash.fill" : "mic.fill"), "symbol")
                ctx.note("\(input.name) \(muted ? "muted" : "not muted") by \(input.canMute(.input) ? "its mute" : "its volume")")
                // Only the default input is written, and only to the state it is in: the other
                // inputs may differ.
                let wanted = MicMute.wanted
                defer { MicMute.wanted = wanted }
                try MicMute.set(muted, devices: [input])
                try ctx.expect(MicMute.isOn == muted, "mute changed")
            },
            SelfTest.Case("audio.listenersRegistered") { ctx in
                AudioWatcher.shared.start()
                try ctx.expect(AudioWatcher.shared.failures.isEmpty, "listener errors \(AudioWatcher.shared.failures)")
                try ctx.expect(AudioWatcher.shared.listenerCount >= 3, "\(AudioWatcher.shared.listenerCount) listeners")
                ctx.note("\(AudioWatcher.shared.listenerCount) listeners")
            },
            SelfTest.Case("audio.readsAreFast") { ctx in
                // The wheel reads these on the main thread whenever it draws an item.
                let rounds = 50
                for id in ["media.volume", "media.mute", "media.output", "media.input", "system.micMute"] {
                    let behavior = try behavior(id)
                    let start = Date()
                    for _ in 0..<rounds {
                        _ = behavior.isAvailable()
                        _ = behavior.level?.read()
                        _ = behavior.isOn?(.current)
                        _ = behavior.liveSymbol?(.current)
                        _ = behavior.liveDetail?(.current)
                        _ = behavior.choices?(.current)
                    }
                    let each = Date().timeIntervalSince(start) * 1000 / Double(rounds)
                    ctx.note(String(format: "%@ %.2f ms", id, each))
                    try ctx.expect(each < 2, "\(id) takes \(each) ms")
                }
            },
        ]
    }

    private static func behavior(_ id: String) throws -> ActionBehavior {
        guard let behavior = ActionBehaviors.behavior(for: id) else { throw SelfTest.Failure(message: "no behavior for \(id)") }
        return behavior
    }

    /// Lists a picker's devices and chooses the one already in use, which changes nothing.
    private static func checkPicker(_ id: String, _ direction: AudioDevice.Direction, _ ctx: SelfTest.Context) throws {
        let behavior = try behavior(id)
        let choices = behavior.choices?(.current) ?? []
        guard let current = AudioDevice.defaultDevice(direction) else { try ctx.skip("no default device") }
        ctx.note(choices.map { "\($0.title) (\($0.symbol))\($0.isCurrent ? " *" : "")" }.joined(separator: ", "))
        try ctx.expect(choices.filter(\.isCurrent).count == 1, "one current choice")
        let chosen = choices.first(where: \.isCurrent)
        try ctx.expect(chosen?.title == current.name, "current is \(chosen?.title ?? "none"), default is \(current.name)")
        try ctx.expect(behavior.liveDetail?(.current) == current.name, "detail")
        let missing = choices.map(\.symbol).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        try ctx.expect(missing.isEmpty, "missing symbols \(missing)")
        let systemOutput = AudioDevice.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let alertsBefore: AudioObjectID? = AudioDevice.read(AudioDevice.system, systemOutput)
        if let chosen { try behavior.choose?(chosen, .current) }
        try ctx.expect(AudioDevice.defaultDevice(direction) == current, "default device changed")
        try ctx.expect(AudioDevice.read(AudioDevice.system, systemOutput) == alertsBefore, "alert device changed")
    }
}

/// Muting the default sound output: its own mute when it has one, else its volume set to 0
/// and put back later.
enum OutputMute {
    private static let savedVolumesKey = "OutputMuteVolumes"

    /// Whether the default output is muted, or nil when it can be neither muted nor turned
    /// down, as over HDMI.
    static var isOn: Bool? {
        guard let device = AudioDevice.defaultDevice(.output) else { return nil }
        if device.canMute(.output) { return device.isMuted(.output) }
        guard device.canSetVolume(.output) else { return nil }
        return device.volume(.output).map { $0 <= 0.001 }
    }

    static func set(_ muted: Bool) throws {
        guard let device = AudioDevice.defaultDevice(.output) else { throw ActionError.unavailable("No sound output") }
        if device.canMute(.output) { return try device.setMuted(muted, .output) }
        guard device.canSetVolume(.output), let uid = device.uid else {
            throw ActionError.unavailable("\(device.name) can't be muted")
        }
        var saved = UserDefaults.standard.dictionary(forKey: savedVolumesKey) as? [String: Double] ?? [:]
        let volume = device.volume(.output) ?? 0
        if muted, volume > 0.001 {
            // Kept before the volume goes, so a quit in between can't lose it.
            saved[uid] = volume
            UserDefaults.standard.set(saved, forKey: savedVolumesKey)
            try device.setVolume(0, .output)
        } else if !muted, volume <= 0.001 {
            try device.setVolume(saved.removeValue(forKey: uid) ?? 0.5, .output)
            UserDefaults.standard.set(saved, forKey: savedVolumesKey)
        }
    }
}

/// Muting the microphone: every input device, so switching microphones doesn't unmute,
/// through its own mute when it has one, else its volume set to 0 and put back later. No
/// sound is ever recorded, so it needs no microphone permission.
enum MicMute {
    private static let savedVolumesKey = "MicMuteVolumes"
    /// Inputs this app muted through their own mute. Unmuting puts back only these, so a
    /// microphone that was muted before stays muted.
    private static let mutedKey = "MicMuteDevices"
    private static let wantedKey = "MicMuteWanted"

    /// Whether the microphone was muted from here and should stay muted when another input
    /// device is connected or chosen. Only the Mute Microphone action sets it.
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: wantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
    }

    /// Whether the default input is muted, or nil when it can be neither muted nor turned down.
    static var isOn: Bool? {
        AudioDevice.defaultDevice(.input).flatMap(isMuted)
    }

    private static func isMuted(_ device: AudioDevice) -> Bool? {
        if device.canMute(.input) { return device.isMuted(.input) }
        guard device.canSetVolume(.input) else { return nil }
        return device.volume(.input).map { $0 <= 0.001 }
    }

    static func set(_ muted: Bool, devices: [AudioDevice] = AudioDevice.all(.input)) throws {
        wanted = muted
        var saved = UserDefaults.standard.dictionary(forKey: savedVolumesKey) as? [String: Double] ?? [:]
        var ours = Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? [])
        // Turning the mute off always unmutes the microphone in use, whoever muted it.
        let current = AudioDevice.defaultDevice(.input)?.uid
        var failure: Error?
        var changed = 0
        for device in devices {
            let uid = device.uid ?? String(device.id)
            do {
                if device.canMute(.input) {
                    if muted, device.isMuted(.input) != true {
                        ours.insert(uid)
                        UserDefaults.standard.set(Array(ours), forKey: mutedKey)
                        try device.setMuted(true, .input)
                    } else if !muted, ours.contains(uid) || uid == current {
                        try device.setMuted(false, .input)
                        ours.remove(uid)
                    }
                    changed += 1
                } else if device.canSetVolume(.input) {
                    let volume = device.volume(.input) ?? 0
                    if muted, volume > 0.001 {
                        saved[uid] = volume
                        UserDefaults.standard.set(saved, forKey: savedVolumesKey)
                        try device.setVolume(0, .input)
                    } else if !muted, let restored = saved.removeValue(forKey: uid) {
                        try device.setVolume(restored, .input)
                    }
                    changed += 1
                }
            } catch {
                failure = error
            }
        }
        UserDefaults.standard.set(saved, forKey: savedVolumesKey)
        UserDefaults.standard.set(Array(ours), forKey: mutedKey)
        if changed == 0 {
            throw failure ?? ActionError.unavailable("No microphone can be muted")
        }
    }
}

/// Tells the wheel when the sound devices, the volume or a mute changes, and keeps the
/// microphone muted when another input device is connected or chosen.
final class AudioWatcher {
    static let shared = AudioWatcher()

    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var noticePending = false
    private var listed: [AudioDevice.Direction: [ListedDevice]] = [:]
    /// Errors from registering listeners, for the self-test.
    private(set) var failures: [OSStatus] = []

    var listenerCount: Int { systemListeners.count + deviceListeners.count }

    func start() {
        guard systemListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            if let listener = listen(AudioDevice.system, AudioDevice.address(selector), { [weak self] in self?.devicesChanged() }) {
                systemListeners.append(listener)
            }
        }
        watchDefaultDevices()
    }

    /// A device as a picker shows it.
    struct ListedDevice {
        let device: AudioDevice
        /// The device's UID, which stays the same while the picker is open.
        let key: String
        let name: String
        let symbol: String
    }

    /// The devices each way as the pickers show them. Reading them takes a couple of
    /// milliseconds, so they are kept until a device comes or goes.
    func devices(_ direction: AudioDevice.Direction) -> [ListedDevice] {
        if let cached = listed[direction] { return cached }
        let devices = AudioDevice.all(direction).map {
            ListedDevice(device: $0, key: $0.uid ?? String($0.id), name: $0.name, symbol: $0.symbol(direction))
        }
        if !systemListeners.isEmpty { listed[direction] = devices }
        return devices
    }

    private func devicesChanged() {
        listed.removeAll()
        if MicMute.wanted { try? MicMute.set(true) }
        watchDefaultDevices()
        notice()
    }

    /// Listens to the volume and mute of the default output and input, which change devices.
    private func watchDefaultDevices() {
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
        deviceListeners.removeAll()
        let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        let watched: [(AudioDevice?, AudioObjectPropertyScope, () -> Void)] = [
            (AudioDevice.defaultDevice(.output), kAudioObjectPropertyScopeOutput, { [weak self] in self?.notice() }),
            (AudioDevice.defaultDevice(.input), kAudioObjectPropertyScopeInput, { [weak self] in self?.inputChanged() }),
        ]
        for (device, scope, body) in watched {
            guard let device else { continue }
            for selector in selectors {
                if let listener = listen(device.id, AudioDevice.address(selector, scope), body) { deviceListeners.append(listener) }
            }
        }
    }

    private func inputChanged() {
        // Turning the microphone back on elsewhere, such as in Sound settings, ends the mute.
        if MicMute.wanted, MicMute.isOn == false { MicMute.wanted = false }
        notice()
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ body: @escaping () -> Void) -> Listener? {
        guard AudioDevice.has(object, address) else { return nil }
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in body() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        guard status == noErr else {
            failures.append(status)
            return nil
        }
        return (object, address, block)
    }

    /// Posts one notice for a burst of changes, such as a drag along the volume slider.
    private func notice() {
        guard !noticePending else { return }
        noticePending = true
        DispatchQueue.main.async {
            self.noticePending = false
            NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
        }
    }
}
