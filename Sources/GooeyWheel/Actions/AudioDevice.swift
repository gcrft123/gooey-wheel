import AudioToolbox
import CoreAudio
import Foundation

/// A sound device as CoreAudio knows it, such as speakers, headphones or a microphone. Reads
/// and writes go straight to CoreAudio and take well under a millisecond, so the wheel can
/// make them on the main thread. None of them shows the system's volume overlay.
struct AudioDevice: Equatable {
    let id: AudioObjectID

    enum Direction {
        case output, input

        var scope: AudioObjectPropertyScope {
            self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        }

        fileprivate var defaultDevice: AudioObjectPropertySelector {
            self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        }
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Finding devices

    /// The devices that can play (or record) sound and could be chosen in Sound settings.
    static func all(_ direction: Direction) -> [AudioDevice] {
        let ids: [AudioObjectID] = readArray(system, address(kAudioHardwarePropertyDevices))
        return ids.map(AudioDevice.init).filter { device in
            let streams: [AudioObjectID] = readArray(device.id, address(kAudioDevicePropertyStreams, direction.scope))
            let hidden: UInt32 = read(device.id, address(kAudioDevicePropertyIsHidden)) ?? 0
            let choosable: UInt32 = read(device.id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, direction.scope)) ?? 1
            return !streams.isEmpty && hidden == 0 && choosable != 0
        }
    }

    /// The device sound plays through (or is recorded from) unless an app picks another.
    static func defaultDevice(_ direction: Direction) -> AudioDevice? {
        let id: AudioObjectID? = read(system, address(direction.defaultDevice))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : AudioDevice(id: $0) }
    }

    static func setDefault(_ device: AudioDevice, _ direction: Direction) throws {
        // Alerts and sound effects move with the output when they were playing through it, as
        // with "Selected sound output device" in Sound settings. A device picked for them
        // on purpose stays.
        let systemOutput = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let alertsFollow = direction == .output && read(system, systemOutput) == defaultDevice(.output)?.id
        try write(system, address(direction.defaultDevice), device.id)
        if alertsFollow { try? write(system, systemOutput, device.id) }
    }

    // MARK: Description

    var name: String { Self.readString(id, Self.address(kAudioObjectPropertyName)) ?? "Unknown Device" }

    /// Stays the same across restarts and reconnections, unlike `id`.
    var uid: String? { Self.readString(id, Self.address(kAudioDevicePropertyDeviceUID)) }

    var transport: UInt32 { Self.read(id, Self.address(kAudioDevicePropertyTransportType)) ?? 0 }

    /// A glyph for what kind of device it is.
    func symbol(_ direction: Direction) -> String {
        let name = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "rectangle.stack"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeVirtual:
            return "waveform"
        case kAudioDeviceTransportTypeBuiltIn where direction == .output:
            let headphones: UInt32 = 0x6864_706E // 'hdpn'
            let source: UInt32? = Self.read(id, Self.address(kAudioDevicePropertyDataSource, direction.scope))
            return source == headphones ? "headphones" : "hifispeaker.fill"
        default:
            return direction == .output ? "hifispeaker.fill" : "mic.fill"
        }
    }

    // MARK: Volume

    /// The volume from 0 to 1, or nil when the device has no volume control, as over HDMI.
    /// Tried in turn: the volume Sound settings shows, the device's main volume, then the
    /// average of its left and right channels.
    func volume(_ direction: Direction) -> Double? {
        let scope = direction.scope
        if let value: Float32 = Self.read(id, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)) {
            return Double(value)
        }
        if let value: Float32 = Self.read(id, Self.address(kAudioDevicePropertyVolumeScalar, scope)) {
            return Double(value)
        }
        let values: [Float32] = stereoChannels(direction).compactMap {
            Self.read(id, Self.address(kAudioDevicePropertyVolumeScalar, scope, $0))
        }
        return values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }

    func canSetVolume(_ direction: Direction) -> Bool {
        let scope = direction.scope
        return Self.isSettable(id, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope))
            || Self.isSettable(id, Self.address(kAudioDevicePropertyVolumeScalar, scope))
            || stereoChannels(direction).contains { Self.isSettable(id, Self.address(kAudioDevicePropertyVolumeScalar, scope, $0)) }
    }

    func setVolume(_ value: Double, _ direction: Direction) throws {
        let scope = direction.scope
        let level = Float32(min(max(value, 0), 1))
        let virtualMain = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        if Self.isSettable(id, virtualMain) { return try Self.write(id, virtualMain, level) }
        let main = Self.address(kAudioDevicePropertyVolumeScalar, scope)
        if Self.isSettable(id, main) { return try Self.write(id, main, level) }
        let channels = stereoChannels(direction).filter { Self.isSettable(id, Self.address(kAudioDevicePropertyVolumeScalar, scope, $0)) }
        guard !channels.isEmpty else { throw ActionError.unavailable("\(name) has no volume control") }
        for channel in channels {
            try Self.write(id, Self.address(kAudioDevicePropertyVolumeScalar, scope, channel), level)
        }
    }

    private func stereoChannels(_ direction: Direction) -> [AudioObjectPropertyElement] {
        let channels: [UInt32] = Self.readArray(id, Self.address(kAudioDevicePropertyPreferredChannelsForStereo, direction.scope))
        return channels.isEmpty ? [1, 2] : channels
    }

    // MARK: Mute

    /// Whether the device's own mute is on, or nil when it has none.
    func isMuted(_ direction: Direction) -> Bool? {
        let value: UInt32? = Self.read(id, Self.address(kAudioDevicePropertyMute, direction.scope))
        return value.map { $0 != 0 }
    }

    func canMute(_ direction: Direction) -> Bool {
        Self.isSettable(id, Self.address(kAudioDevicePropertyMute, direction.scope))
    }

    func setMuted(_ muted: Bool, _ direction: Direction) throws {
        try Self.write(id, Self.address(kAudioDevicePropertyMute, direction.scope), UInt32(muted ? 1 : 0))
    }

    // MARK: Properties

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
    }

    static func readArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, values) == noErr else { return [] }
        let read = Int(size) / MemoryLayout<T>.stride
        return (0..<read).map { (values + $0).move() }
    }

    private static func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        let status = withUnsafePointer(to: value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw ActionError.failed("CoreAudio refused the change (\(status))") }
    }
}
