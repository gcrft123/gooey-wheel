import Foundation

/// Short taps from the mouse's haptic motor, for the wheel to give feedback through the hand.
///
/// Any Logitech mouse with HID++ feature 0x19B0 has a motor that plays waveforms on request. In
/// November 2026 that is the MX Master 4 and its Special and Developer Editions. The G Pro X2
/// Superstrike's haptic clicks are a different feature (0x1B0C) that only tunes the clicks.
/// Each mouse lists the waveforms it has, and each tap plays the first one on its list that the
/// mouse has.
///
/// The mouse also describes a standard HID haptics output report (0x3D), but over Bluetooth it
/// never acknowledges a write to it: on 2026-11-13 one such write held up every request to the
/// mouse for the 30-second ATT timeout, after which macOS dropped the connection. Don't use it.
///
/// Each tap is a HID++ request, and the mouse sends its notifications to whichever channel made
/// the last request (see `MouseWheelEvents`). While Logi Options+ runs, a tap sent as a HID
/// report would take the scroll wheel from Options+ for a few seconds, so taps go over the
/// Bluetooth characteristic Options+ itself uses instead. Through a receiver there is one
/// channel, which every program reads, so taps go as HID reports.
enum MouseHaptics {
    enum Route {
        /// A HID report, as the app's other requests.
        case hid
        /// Logitech's Bluetooth characteristic, where Options+ talks to the mouse.
        case bluetooth
    }

    /// 0x19B0's waveforms, by number.
    enum Waveform: UInt8 {
        case sharpStateChange = 0x00
        case dampStateChange = 0x01
        case sharpCollision = 0x02
        case dampCollision = 0x03
        case subtleCollision = 0x04
        case whisperCollision = 0x1B
    }

    enum Kind: CaseIterable {
        /// The pointer moved onto a bubble.
        case hover
        /// A slider moved by one notch, or a stepper stepped.
        case step
        /// A slider reached its end.
        case limit
        /// A folder, picker, slider, or edit ring opened.
        case open
        /// A ring closed back to its parent.
        case back
        /// An item was chosen, or the wheel's contents changed.
        case select
        /// Something chosen can't be done.
        case refuse

        /// The waveforms for it, best first.
        var waveforms: [Waveform] {
            switch self {
            case .hover: return [.whisperCollision, .subtleCollision]
            case .step: return [.subtleCollision, .whisperCollision]
            case .limit: return [.sharpCollision, .dampCollision]
            case .open: return [.dampStateChange, .sharpStateChange]
            case .back: return [.dampCollision, .subtleCollision]
            case .select: return [.sharpStateChange, .dampStateChange]
            case .refuse: return [.sharpCollision, .dampCollision]
            }
        }

        /// The waveform to play on a mouse that has those in `available`, a bit per waveform
        /// number, or nil when it has none of them. With `available` unknown, the first.
        func waveform(available: UInt32?) -> Waveform? {
            guard let available else { return waveforms.first }
            return waveforms.first { available & (1 << UInt32($0.rawValue)) != 0 }
        }
    }

    /// The app's own switch for these taps, on unless the user turned it off. The mouse's switch
    /// (`MouseState.haptics`) has to be on too.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    private static let enabledKey = "mouseHaptics"

    /// Whether the connected mouse has a haptic motor.
    static var supported: Bool { MouseLink.shared.has(HIDPPFeature.haptic) }

    /// Taps closer together than this blur into a buzz, so the later one is dropped.
    static let minimumGap: TimeInterval = 0.04
    private static var lastPlayed: TimeInterval = -.infinity

    /// Plays a tap, if the mouse has haptics and they're turned on both here and on the mouse.
    /// A tap that would wait behind other requests to the mouse is dropped, since it would
    /// arrive late. Returns whether one was sent.
    @discardableResult
    static func play(_ kind: Kind, over route: Route = .hid) -> Bool {
        guard enabled, let mouse = MouseLink.shared.mouse, MouseState.shared.haptics?.enabled == true else { return false }
        let route = mouse.index == LogiLink.direct ? route : .hid
        guard route == .bluetooth || !mouse.isBusy,
              let waveform = kind.waveform(available: MouseState.shared.hapticWaveforms) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayed >= minimumGap else { return false }
        // Function 4 plays a waveform. Its reply isn't needed, so nothing waits for it.
        switch route {
        case .hid:
            MouseLink.shared.post(HIDPPFeature.haptic, 4, [waveform.rawValue])
        case .bluetooth:
            guard MouseLink.shared.postOverBluetooth(HIDPPFeature.haptic, 4, [waveform.rawValue]) else { return false }
        }
        lastPlayed = now
        return true
    }
}
